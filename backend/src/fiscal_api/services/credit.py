from __future__ import annotations

import base64
import json
from calendar import monthrange
from collections.abc import Callable
from datetime import date, timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p4_schemas import (
    CreditAccountSummary,
    CreditCyclePage,
    CreditCycleResponse,
)
from fiscal_api.core.time import BUSINESS_TIMEZONE, ensure_utc, utc_now
from fiscal_api.db.models import Account, AccountKind, CreditCycle, CreditCycleStatus
from fiscal_api.repositories.credit import CreditRepository
from fiscal_api.services.common import (
    acquire_mutation_lock,
    checked_int64,
    conflict,
    not_found,
)


def _shift_month(value: date, delta: int, day: int) -> date:
    month_index = value.year * 12 + value.month - 1 + delta
    year, month_zero = divmod(month_index, 12)
    month = month_zero + 1
    return date(year, month, min(day, monthrange(year, month)[1]))


def cycle_calendar(
    business_date: date, statement_day: int, due_day: int
) -> tuple[date, date, date]:
    if business_date.day <= statement_day:
        period_end = date(business_date.year, business_date.month, statement_day)
    else:
        period_end = _shift_month(business_date, 1, statement_day)
    previous_end = _shift_month(period_end, -1, statement_day)
    period_start = previous_end + timedelta(days=1)
    due_date = (
        date(period_end.year, period_end.month, due_day)
        if due_day > statement_day
        else _shift_month(period_end, 1, due_day)
    )
    return period_start, period_end, due_date


async def ensure_regular_cycle(
    repository: CreditRepository,
    account: Account,
    business_date: date,
) -> CreditCycle:
    existing_cycles = await repository.cycles(account.id)
    normal = [item for item in existing_cycles if not item.is_opening_cycle]
    for cycle in normal:
        if cycle.period_start <= business_date <= cycle.period_end:
            return cycle
    if account.statement_day is None or account.due_day is None:
        raise RuntimeError("credit account schedule is missing")
    start, end, due = cycle_calendar(business_date, account.statement_day, account.due_day)

    ends_to_create = {end}
    if normal:
        minimum = min(item.period_end for item in normal)
        maximum = max(item.period_end for item in normal)
        if end > maximum:
            cursor = _shift_month(maximum, 1, account.statement_day)
            while cursor <= end:
                ends_to_create.add(cursor)
                cursor = _shift_month(cursor, 1, account.statement_day)
        elif end < minimum:
            cursor = _shift_month(minimum, -1, account.statement_day)
            while cursor >= end:
                ends_to_create.add(cursor)
                cursor = _shift_month(cursor, -1, account.statement_day)

    result: CreditCycle | None = None
    for cycle_end in sorted(ends_to_create):
        cycle_start = _shift_month(cycle_end, -1, account.statement_day) + timedelta(days=1)
        existing = await repository.cycle_for_period(account.id, cycle_start, cycle_end)
        if existing is None:
            cycle_due = (
                date(cycle_end.year, cycle_end.month, account.due_day)
                if account.due_day > account.statement_day
                else _shift_month(cycle_end, 1, account.due_day)
            )
            existing = CreditCycle(
                account_id=account.id,
                period_start=cycle_start,
                period_end=cycle_end,
                statement_date=cycle_end,
                due_date=cycle_due,
                is_opening_cycle=False,
            )
            repository.add_cycle(existing)
            await repository.session.flush()
        if cycle_end == end:
            result = existing
    if result is None:
        raise RuntimeError(f"failed to create credit cycle {start}...{end} due {due}")
    return result


async def sync_opening_cycle(repository: CreditRepository, account: Account) -> CreditCycle | None:
    cycle = await repository.opening_cycle(account.id)
    if account.opening_balance_minor == 0:
        if cycle is not None and not await repository.cycle_has_any_transaction(cycle.id):
            await repository.delete_cycle(cycle)
            await repository.session.flush()
            return None
        return cycle
    if account.opening_balance_as_of_date is None or account.opening_due_date is None:
        return cycle
    if cycle is None:
        cycle = CreditCycle(
            account_id=account.id,
            period_start=account.opening_balance_as_of_date,
            period_end=account.opening_balance_as_of_date,
            statement_date=account.opening_balance_as_of_date,
            due_date=account.opening_due_date,
            is_opening_cycle=True,
        )
        repository.add_cycle(cycle)
    else:
        cycle.period_start = account.opening_balance_as_of_date
        cycle.period_end = account.opening_balance_as_of_date
        cycle.statement_date = account.opening_balance_as_of_date
        cycle.due_date = account.opening_due_date
        cycle.updated_at = utc_now()
    await repository.session.flush()
    return cycle


async def validate_credit_invariants(
    repository: CreditRepository,
    account_ids: set[UUID],
    *,
    repayment_error: bool = False,
) -> None:
    for account_id in account_ids:
        account = await repository.account(account_id)
        if account is None or account.kind != AccountKind.CREDIT.value:
            continue
        cycles = await repository.cycles(account_id)
        amounts = await repository.amounts([item.id for item in cycles])
        for cycle in cycles:
            purchase, repaid = amounts.get(cycle.id, (0, 0))
            opening = account.opening_balance_minor if cycle.is_opening_cycle else 0
            if checked_int64(opening + purchase - repaid, label="credit cycle remaining") < 0:
                conflict(
                    "repayment_exceeds_cycle_remaining"
                    if repayment_error
                    else "credit_cycle_overpaid",
                    "The credit cycle would become overpaid",
                )
            cycle_debt = opening
            for _occurred_at, delta in await repository.cycle_events(cycle.id):
                cycle_debt = checked_int64(delta + cycle_debt, label="credit cycle prefix")
                if cycle_debt < 0:
                    conflict(
                        "repayment_exceeds_cycle_remaining"
                        if repayment_error
                        else "credit_cycle_overpaid",
                        "A repayment cannot predate its target cycle liability",
                    )

        debt = account.opening_balance_minor
        for occurred_at, delta in await repository.credit_events(account_id):
            if (
                account.opening_balance_as_of_date is not None
                and ensure_utc(occurred_at).astimezone(BUSINESS_TIMEZONE).date()
                < account.opening_balance_as_of_date
            ):
                conflict(
                    "credit_opening_configuration_required",
                    "Credit events cannot predate the configured opening balance",
                )
            debt = checked_int64(debt + delta, label="credit chronological debt")
            if debt < 0:
                conflict(
                    "repayment_exceeds_cycle_remaining",
                    "A repayment cannot predate the liability it repays",
                )


class CreditService:
    def __init__(
        self,
        session: AsyncSession,
        *,
        today: Callable[[], date] | None = None,
    ) -> None:
        self.session = session
        self.repository = CreditRepository(session)
        self._today = today or (lambda: utc_now().astimezone(BUSINESS_TIMEZONE).date())

    async def list_accounts(self) -> list[CreditAccountSummary]:
        await acquire_mutation_lock(self.session)
        accounts = await self.repository.active_accounts()
        responses = [await self._account_response(item) for item in accounts]
        await self.session.commit()
        return responses

    async def get_account(self, account_id: UUID) -> CreditAccountSummary:
        await acquire_mutation_lock(self.session)
        account = await self._required_account(account_id)
        response = await self._account_response(account)
        await self.session.commit()
        return response

    async def list_cycles(
        self, account_id: UUID, *, cursor: str | None, limit: int
    ) -> CreditCyclePage:
        await acquire_mutation_lock(self.session)
        account = await self._required_account(account_id)
        await self._ensure_summary_cycles(account)
        cursor_end, cursor_id = self._decode_cursor(cursor)
        cycles = await self.repository.cycles(
            account.id, limit=limit, cursor_end=cursor_end, cursor_id=cursor_id
        )
        has_more = len(cycles) > limit
        page = cycles[:limit]
        amounts = await self.repository.amounts([item.id for item in page])
        response = CreditCyclePage(
            items=[
                await self._cycle_response(item, account, amounts.get(item.id, (0, 0)))
                for item in page
            ],
            next_cursor=self._encode_cursor(page[-1]) if has_more and page else None,
        )
        await self.session.commit()
        return response

    async def get_cycle(self, cycle_id: UUID) -> CreditCycleResponse:
        await acquire_mutation_lock(self.session)
        try:
            cycle = await self.repository.cycle(cycle_id)
            if cycle is None:
                not_found("credit_cycle_not_found", "The credit cycle does not exist")
            account = await self._required_account(cycle.account_id)
            amounts = await self.repository.amounts([cycle.id])
            response = await self._cycle_response(cycle, account, amounts.get(cycle.id, (0, 0)))
            await self.session.commit()
            return response
        except Exception:
            await self.session.rollback()
            raise

    async def _account_response(self, account: Account) -> CreditAccountSummary:
        current = await self._ensure_summary_cycles(account)
        cycles = await self.repository.cycles(account.id)
        amounts = await self.repository.amounts([item.id for item in cycles])
        responses = [
            await self._cycle_response(item, account, amounts.get(item.id, (0, 0)))
            for item in cycles
        ]
        impacts = await self.repository.account_impacts([account.id])
        debt = checked_int64(
            account.opening_balance_minor - impacts.get(account.id, 0),
            label="credit account debt",
        )
        if (
            account.credit_limit_minor is None
            or account.statement_day is None
            or account.due_day is None
        ):
            raise RuntimeError("credit account configuration is incomplete")
        remaining = [item for item in responses if item.remaining_minor > 0]
        next_due = min(remaining, key=lambda item: (item.due_date, item.id)) if remaining else None
        current_response = next(item for item in responses if item.id == current.id)
        unresolved = account.opening_balance_minor > 0 and (
            account.opening_balance_as_of_date is None or account.opening_due_date is None
        )
        from fiscal_api.services.installments import InstallmentService

        plan_page = await InstallmentService(self.session).list(
            account_id=account.id, status=None, cursor=None, limit=100
        )
        active_plans = [
            item
            for item in plan_page.items
            if item.status.value in {"active", "partially_cancelled"}
        ]
        future_total = checked_int64(
            sum(item.future_scheduled_gross_minor for item in active_plans),
            label="future installment gross",
        )
        next_plan = min(
            (item for item in active_plans if item.next_period is not None),
            key=lambda item: item.next_period.effective_statement_date,  # type: ignore[union-attr]
            default=None,
        )
        return CreditAccountSummary(
            account_id=account.id,
            name=account.name,
            institution=account.institution,
            last_four=account.last_four,
            credit_limit_minor=account.credit_limit_minor,
            current_debt_minor=debt,
            available_credit_minor=max(account.credit_limit_minor - debt, 0),
            over_limit_minor=max(debt - account.credit_limit_minor, 0),
            opening_configuration_required=unresolved,
            statement_day=account.statement_day,
            due_day=account.due_day,
            current_cycle=current_response,
            next_due_cycle=next_due,
            has_overdue_cycle=any(item.is_overdue for item in responses),
            active_installment_count=len(active_plans),
            future_scheduled_gross_minor=future_total,
            next_installment=(
                InstallmentService(self.session).teaser(next_plan) if next_plan else None
            ),
        )

    async def _ensure_summary_cycles(self, account: Account) -> CreditCycle:
        await sync_opening_cycle(self.repository, account)
        return await ensure_regular_cycle(self.repository, account, self._today())

    async def _required_account(self, account_id: UUID) -> Account:
        account = await self.repository.account(account_id)
        if account is None or account.kind != AccountKind.CREDIT.value:
            not_found("credit_account_not_found", "The credit account does not exist")
        return account

    async def _cycle_response(
        self, cycle: CreditCycle, account: Account, amounts: tuple[int, int]
    ) -> CreditCycleResponse:
        purchase, repaid = amounts
        opening = account.opening_balance_minor if cycle.is_opening_cycle else 0
        amount_due = checked_int64(opening + purchase, label="credit cycle amount due")
        remaining = checked_int64(amount_due - repaid, label="credit cycle remaining")
        if remaining < 0:
            conflict("credit_cycle_overpaid", "The credit cycle is overpaid")
        today = self._today()
        if remaining == 0:
            status = CreditCycleStatus.SETTLED
        elif cycle.due_date < today:
            status = CreditCycleStatus.OVERDUE
        elif cycle.statement_date >= today:
            status = CreditCycleStatus.OPEN
        elif repaid > 0:
            status = CreditCycleStatus.PARTIAL
        else:
            status = CreditCycleStatus.UNPAID
        from fiscal_api.repositories.installments import InstallmentRepository
        from fiscal_api.services.installments import InstallmentService

        installment_repository = InstallmentRepository(self.session)
        allocation = (await installment_repository.active_period_totals([cycle.id])).get(
            cycle.id, (0, 0)
        )
        plan_models = await installment_repository.period_plans_for_cycle(cycle.id)
        plan_responses = [
            await InstallmentService(self.session).response(item) for item in plan_models
        ]
        installment_periods = [
            period
            for plan in plan_responses
            for period in plan.periods
            if period.effective_cycle_id == cycle.id
        ]
        return CreditCycleResponse(
            id=cycle.id,
            account_id=cycle.account_id,
            period_start=cycle.period_start,
            period_end=cycle.period_end,
            statement_date=cycle.statement_date,
            due_date=cycle.due_date,
            is_opening_cycle=cycle.is_opening_cycle,
            purchase_minor=purchase,
            opening_minor=opening,
            amount_due_minor=amount_due,
            repaid_minor=repaid,
            remaining_minor=remaining,
            status=status,
            is_overdue=status is CreditCycleStatus.OVERDUE,
            version=cycle.version,
            created_at=cycle.created_at,
            updated_at=cycle.updated_at,
            installment_principal_minor=allocation[0],
            installment_fee_minor=allocation[1],
            installment_periods=installment_periods,
        )

    @staticmethod
    def _encode_cursor(cycle: CreditCycle) -> str:
        payload = json.dumps({"end": cycle.period_end.isoformat(), "id": str(cycle.id)})
        return base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")

    @staticmethod
    def _decode_cursor(cursor: str | None) -> tuple[date | None, UUID | None]:
        if cursor is None:
            return None, None
        try:
            padded = cursor + "=" * (-len(cursor) % 4)
            payload = json.loads(base64.urlsafe_b64decode(padded).decode())
            return date.fromisoformat(payload["end"]), UUID(payload["id"])
        except (ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
            from fiscal_api.services.common import invalid

            invalid("invalid_transaction_configuration", "The cursor is invalid")
            raise AssertionError from error
