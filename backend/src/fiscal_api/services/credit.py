from __future__ import annotations

import base64
import json
from calendar import monthrange
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p4_schemas import (
    CreditAccountSummary,
    CreditCyclePage,
    CreditCycleResponse,
    CreditScheduleChangeRequest,
    CreditScheduleChangeResult,
)
from fiscal_api.core.errors import APIError
from fiscal_api.core.time import BUSINESS_TIMEZONE, ensure_utc, utc_now
from fiscal_api.db.models import (
    Account,
    AccountKind,
    CreditCycle,
    CreditCycleMode,
    CreditCycleStatus,
    TransactionKind,
)
from fiscal_api.repositories.credit import CreditRepository
from fiscal_api.services.common import (
    acquire_mutation_lock,
    check_version,
    checked_int64,
    conflict,
    not_found,
)


def _shift_month(value: date, delta: int, day: int) -> date:
    month_index = value.year * 12 + value.month - 1 + delta
    year, month_zero = divmod(month_index, 12)
    month = month_zero + 1
    return date(year, month, min(day, monthrange(year, month)[1]))


@dataclass(frozen=True)
class CreditSchedule:
    period_start: date
    period_end: date
    statement_date: date
    due_date: date


def schedule_for_statement(
    statement_date: date,
    statement_day: int,
    due_day: int,
    cycle_mode: CreditCycleMode,
) -> CreditSchedule:
    if statement_date.day != statement_day:
        raise ValueError("statement_date does not match statement_day")
    if cycle_mode is CreditCycleMode.PREVIOUS_CALENDAR_MONTH:
        previous = _shift_month(statement_date, -1, 1)
        period_start = date(previous.year, previous.month, 1)
        period_end = date(
            previous.year, previous.month, monthrange(previous.year, previous.month)[1]
        )
    else:
        period_end = statement_date
        period_start = _shift_month(statement_date, -1, statement_day) + timedelta(days=1)
    due_date = (
        date(statement_date.year, statement_date.month, due_day)
        if due_day > statement_day
        else _shift_month(statement_date, 1, due_day)
    )
    return CreditSchedule(period_start, period_end, statement_date, due_date)


def credit_schedule(
    business_date: date,
    statement_day: int,
    due_day: int,
    cycle_mode: CreditCycleMode = CreditCycleMode.STATEMENT_DAY_CUTOFF,
) -> CreditSchedule:
    if cycle_mode is CreditCycleMode.PREVIOUS_CALENDAR_MONTH:
        statement_date = _shift_month(business_date.replace(day=1), 1, statement_day)
    elif business_date.day <= statement_day:
        statement_date = date(business_date.year, business_date.month, statement_day)
    else:
        statement_date = _shift_month(business_date, 1, statement_day)
    return schedule_for_statement(statement_date, statement_day, due_day, cycle_mode)


def cycle_calendar(
    business_date: date, statement_day: int, due_day: int
) -> tuple[date, date, date]:
    """Backward-compatible cutoff calendar used by released callers and tests."""
    value = credit_schedule(business_date, statement_day, due_day)
    return value.period_start, value.period_end, value.due_date


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
    mode = CreditCycleMode(account.cycle_mode or CreditCycleMode.STATEMENT_DAY_CUTOFF.value)
    schedule = credit_schedule(business_date, account.statement_day, account.due_day, mode)
    return await ensure_cycle_for_statement(repository, account, schedule.statement_date)


async def ensure_cycle_for_statement(
    repository: CreditRepository, account: Account, statement_date: date
) -> CreditCycle:
    if account.statement_day is None or account.due_day is None:
        raise RuntimeError("credit account schedule is missing")
    mode = CreditCycleMode(account.cycle_mode or CreditCycleMode.STATEMENT_DAY_CUTOFF.value)
    schedule = schedule_for_statement(statement_date, account.statement_day, account.due_day, mode)
    existing = await repository.cycle_for_period(
        account.id, schedule.period_start, schedule.period_end
    )
    if existing is not None:
        return existing
    existing = CreditCycle(
        account_id=account.id,
        period_start=schedule.period_start,
        period_end=schedule.period_end,
        statement_date=schedule.statement_date,
        due_date=schedule.due_date,
        is_opening_cycle=False,
    )
    repository.add_cycle(existing)
    await repository.session.flush()
    return existing


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

    async def preview_schedule_change(
        self, account_id: UUID, request: CreditScheduleChangeRequest
    ) -> CreditScheduleChangeResult:
        nested = await self.session.begin_nested()
        try:
            return await self._change_schedule(account_id, request, commit=False)
        except APIError as error:
            return CreditScheduleChangeResult(
                account_id=account_id,
                cycle_mode=request.cycle_mode,
                statement_day=request.statement_day,
                due_day=request.due_day,
                affected_cycle_count=0,
                purchase_count=0,
                repayment_count=0,
                installment_period_count=0,
                conflicts=[f"{error.code}: {error.message}"],
            )
        finally:
            if nested.is_active:
                await nested.rollback()

    async def apply_schedule_change(
        self, account_id: UUID, request: CreditScheduleChangeRequest
    ) -> CreditScheduleChangeResult:
        try:
            return await self._change_schedule(account_id, request, commit=True)
        except Exception:
            await self.session.rollback()
            raise

    async def _change_schedule(
        self,
        account_id: UUID,
        request: CreditScheduleChangeRequest,
        *,
        commit: bool,
    ) -> CreditScheduleChangeResult:
        await acquire_mutation_lock(self.session)
        account = await self.repository.account(account_id, for_update=True)
        if account is None or account.kind != AccountKind.CREDIT.value:
            not_found("credit_account_not_found", "The credit account does not exist")
        check_version(account.version, request.expected_version)
        cycles = await self.repository.cycles(account.id)
        amounts = await self.repository.amounts([item.id for item in cycles])
        affected: list[CreditCycle] = []
        for item in cycles:
            purchase, repaid = amounts.get(item.id, (0, 0))
            if not item.is_opening_cycle and purchase - repaid > 0:
                affected.append(item)
        affected_ids = [item.id for item in affected]
        transactions = await self.repository.transactions_for_cycles(affected_ids)
        periods = await self.repository.periods_for_cycles(affected_ids)
        plans = await self.repository.plans_for_start_cycles(affected_ids)
        affected_by_id = {item.id: item for item in affected}
        for period in periods:
            cycle = affected_by_id.get(period.effective_cycle_id)
            if cycle is not None and (
                cycle.statement_date < self._today()
                or await self.repository.cycle_has_repayment(cycle.id)
            ):
                conflict(
                    "installment_period_locked",
                    "A locked installment period cannot move to another credit schedule",
                )
        purchase_count = sum(
            item.kind == TransactionKind.CREDIT_PURCHASE.value for item in transactions
        )
        repayment_count = sum(item.kind == TransactionKind.REPAYMENT.value for item in transactions)

        account.cycle_mode = request.cycle_mode.value
        account.statement_day = request.statement_day
        account.due_day = request.due_day
        account.version += 1
        account.updated_at = utc_now()
        await self.session.flush()

        by_id = affected_by_id
        replacements: dict[UUID, CreditCycle] = {}

        async def replacement(cycle_id: UUID) -> CreditCycle:
            known = replacements.get(cycle_id)
            if known is not None:
                return known
            old = by_id[cycle_id]
            statement = date(
                old.statement_date.year, old.statement_date.month, request.statement_day
            )
            created = await ensure_cycle_for_statement(self.repository, account, statement)
            replacements[cycle_id] = created
            return created

        for transaction in transactions:
            if transaction.kind == TransactionKind.CREDIT_PURCHASE.value:
                business_date = (
                    ensure_utc(transaction.occurred_at).astimezone(BUSINESS_TIMEZONE).date()
                )
                schedule = credit_schedule(
                    business_date,
                    request.statement_day,
                    request.due_day,
                    request.cycle_mode,
                )
                target = await ensure_cycle_for_statement(
                    self.repository, account, schedule.statement_date
                )
            else:
                assert transaction.credit_cycle_id is not None
                target = await replacement(transaction.credit_cycle_id)
            if transaction.credit_cycle_id != target.id:
                transaction.credit_cycle_id = target.id
                transaction.version += 1
                transaction.updated_at = utc_now()

        for period in periods:
            if period.scheduled_cycle_id in by_id:
                period.scheduled_cycle_id = (await replacement(period.scheduled_cycle_id)).id
            if period.effective_cycle_id in by_id:
                period.effective_cycle_id = (await replacement(period.effective_cycle_id)).id
            period.version += 1
            period.updated_at = utc_now()

        for plan in plans:
            plan.start_cycle_id = (await replacement(plan.start_cycle_id)).id
            plan.version += 1
            plan.updated_at = utc_now()

        await self.session.flush()
        await validate_credit_invariants(self.repository, {account.id})
        for cycle in affected:
            is_replacement = cycle.id in {item.id for item in replacements.values()}
            if not is_replacement and not await self.repository.cycle_is_referenced(cycle.id):
                await self.repository.delete_cycle(cycle)
        await self.session.flush()
        result = CreditScheduleChangeResult(
            account_id=account.id,
            cycle_mode=request.cycle_mode,
            statement_day=request.statement_day,
            due_day=request.due_day,
            affected_cycle_count=len(affected),
            purchase_count=purchase_count,
            repayment_count=repayment_count,
            installment_period_count=len(periods),
            conflicts=[],
        )
        if commit:
            await self.session.commit()
        return result

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
            cycle_mode=CreditCycleMode(
                account.cycle_mode or CreditCycleMode.STATEMENT_DAY_CUTOFF.value
            ),
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
