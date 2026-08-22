from __future__ import annotations

import base64
import hashlib
import json
from calendar import monthrange
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import Any
from uuid import UUID, uuid5

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p4_schemas import (
    CreditAccountSummary,
    CreditCyclePage,
    CreditCycleResponse,
    CreditScheduleAffectedCycle,
    CreditScheduleChangeCommitRequest,
    CreditScheduleChangeRequest,
    CreditScheduleChangeResult,
)
from fiscal_api.core.time import BUSINESS_TIMEZONE, UTC, ensure_utc, utc_now
from fiscal_api.db.models import (
    Account,
    AccountKind,
    CreditCycle,
    CreditCycleMode,
    CreditCycleStatus,
    CreditScheduleChangeOperation,
    CreditScheduleChangePreview,
    DataRevision,
    LedgerTransaction,
    TransactionKind,
)
from fiscal_api.repositories.credit import CreditRepository
from fiscal_api.repositories.transactions import TransactionRepository
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


@dataclass(frozen=True)
class ScheduleChangePlan:
    account: Account
    request: CreditScheduleChangeRequest
    all_cycles: list[CreditCycle]
    affected_cycles: list[CreditCycle]
    amounts: dict[UUID, tuple[int, int]]
    transactions: list[LedgerTransaction]
    periods: list[Any]
    plans: list[Any]
    checkpoints: list[Any]
    ai_proposals: list[Any]
    statement_rows: list[Any]
    purchase_schedules: dict[UUID, CreditSchedule]
    reference_schedules: dict[UUID, CreditSchedule]
    affected_previews: list[CreditScheduleAffectedCycle]
    warnings: list[str]
    old_cycle_mode: CreditCycleMode
    old_statement_day: int | None
    old_due_day: int | None


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


def regular_cycle_id(account_id: UUID, schedule: CreditSchedule) -> UUID:
    """Stable identity for a regular cycle that has not yet been materialized.

    A projected read-cycle and the first formal write to that period must refer
    to the same resource.  Historical rows retain their existing IDs; this is
    only used when a new regular period has no row yet.
    """

    return uuid5(
        account_id,
        f"fiscal-credit-cycle-v1:{schedule.period_start.isoformat()}:{schedule.period_end.isoformat()}",
    )


def regular_cycle_timestamp(schedule: CreditSchedule) -> datetime:
    """Stable UTC metadata for both projected and first materialized cycles."""

    return datetime.combine(schedule.statement_date, time.min, tzinfo=BUSINESS_TIMEZONE).astimezone(
        UTC
    )


def project_current_cycle(
    account: Account, *, today: date, cycles: list[CreditCycle]
) -> CreditCycle:
    """Return today's regular cycle without adding or flushing a database row."""

    for cycle in cycles:
        if not cycle.is_opening_cycle and cycle.period_start <= today <= cycle.period_end:
            return cycle
    if account.statement_day is None or account.due_day is None:
        raise RuntimeError("credit account schedule is missing")
    mode = CreditCycleMode(account.cycle_mode or CreditCycleMode.STATEMENT_DAY_CUTOFF.value)
    schedule = credit_schedule(today, account.statement_day, account.due_day, mode)
    projected_at = regular_cycle_timestamp(schedule)
    return CreditCycle(
        id=regular_cycle_id(account.id, schedule),
        account_id=account.id,
        period_start=schedule.period_start,
        period_end=schedule.period_end,
        statement_date=schedule.statement_date,
        due_date=schedule.due_date,
        is_opening_cycle=False,
        version=1,
        created_at=projected_at,
        updated_at=projected_at,
    )


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
        # `version` is intentionally immutable for a cycle resource.  A
        # schedule command can nevertheless retain the same economic period
        # (for example only `due_day` changes); in that case its visible dates
        # must be updated in the same transaction rather than returning stale
        # metadata from the existing row.
        if (
            existing.statement_date != schedule.statement_date
            or existing.due_date != schedule.due_date
        ):
            existing.statement_date = schedule.statement_date
            existing.due_date = schedule.due_date
            # Projected future cycles use their statement date as stable
            # creation metadata.  A real schedule command must not make that
            # immutable resource timestamp go backwards when it amends dates.
            existing.updated_at = max(utc_now(), existing.updated_at + timedelta(microseconds=1))
            await repository.session.flush()
        return existing
    existing = CreditCycle(
        id=regular_cycle_id(account.id, schedule),
        account_id=account.id,
        period_start=schedule.period_start,
        period_end=schedule.period_end,
        statement_date=schedule.statement_date,
        due_date=schedule.due_date,
        is_opening_cycle=False,
        created_at=regular_cycle_timestamp(schedule),
        updated_at=regular_cycle_timestamp(schedule),
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
        accounts = await self.repository.active_accounts()
        return [await self._account_response(item) for item in accounts]

    async def get_account(self, account_id: UUID) -> CreditAccountSummary:
        account = await self._required_account(account_id)
        return await self._account_response(account)

    async def preview_schedule_change(
        self, account_id: UUID, request: CreditScheduleChangeRequest
    ) -> CreditScheduleChangeResult:
        """Persist a short-lived dependency snapshot without a formal data write."""
        plan = await self._schedule_change_plan(account_id, request, for_update=False)
        result = self._result_for_plan(plan, current_account_version=plan.account.version)
        preview = CreditScheduleChangePreview(
            account_id=account_id,
            request_hash=self._proposal_hash(account_id, request),
            payload={
                "dependencies": self._dependencies_payload(plan),
                "result": result.model_dump(mode="json"),
            },
        )
        self.repository.add_preview(preview)
        # This route intentionally has no formal_mutation dependency: the token
        # is operational state, not a financial fact or Archive entity.
        await self.session.commit()
        return result.model_copy(
            update={
                "preview_token": preview.id,
                "preview_expires_at": preview.expires_at,
                "available_actions": (
                    ["commit_schedule_change"] if not plan.warnings else ["edit_schedule"]
                ),
            }
        )

    async def apply_schedule_change(
        self, account_id: UUID, request: CreditScheduleChangeRequest
    ) -> CreditScheduleChangeResult:
        """Compatibility helper for pre-P33 direct service callers.

        API traffic must use :meth:`commit_schedule_change`; this helper is not
        routed and cannot bypass the preview-token route contract.
        """
        try:
            await acquire_mutation_lock(self.session)
            plan = await self._schedule_change_plan(account_id, request, for_update=True)
            check_version(
                plan.account.version,
                request.expected_version,
                resource_type="account",
                resource_id=str(account_id),
                reload_path=f"/api/v1/credit-accounts/{account_id}",
            )
            self._raise_if_plan_locked(plan)
            result = await self._apply_schedule_change_plan(plan)
            await self.session.commit()
            return result
        except Exception:
            await self.session.rollback()
            raise

    async def commit_schedule_change(
        self,
        account_id: UUID,
        request: CreditScheduleChangeCommitRequest,
        idempotency_key: UUID,
    ) -> CreditScheduleChangeResult:
        request_hash = self._commit_hash(account_id, request)
        replay = await self._operation_replay(idempotency_key, request_hash)
        if replay is not None:
            return replay
        try:
            await acquire_mutation_lock(self.session)
            replay = await self._operation_replay(idempotency_key, request_hash)
            if replay is not None:
                return replay
            preview = await self._required_preview(request.preview_token, account_id)
            proposal = CreditScheduleChangeRequest.model_validate(
                request.model_dump(exclude={"preview_token"})
            )
            if preview.request_hash != self._proposal_hash(account_id, proposal):
                conflict(
                    "credit_schedule_preview_input_mismatch",
                    "The submitted schedule does not match its preview",
                    details=self._preview_conflict_details(account_id, "preview_input_mismatch"),
                )
            plan = await self._schedule_change_plan(account_id, proposal, for_update=True)
            if preview.payload.get("dependencies") != self._dependencies_payload(plan):
                conflict(
                    "credit_schedule_preview_stale",
                    "Credit schedule dependencies changed; preview again",
                    details=self._preview_conflict_details(account_id, "dependencies_changed"),
                )
            self._raise_if_plan_locked(plan)
            revision = await self._next_data_revision()
            result = await self._apply_schedule_change_plan(plan)
            receipt = result.model_copy(
                update={
                    "preview_token": preview.id,
                    "current_account_version": plan.account.version,
                    "expected_account_version": proposal.expected_version,
                    "data_revision": revision,
                }
            )
            self.repository.add_operation(
                CreditScheduleChangeOperation(
                    preview_id=preview.id,
                    idempotency_key=idempotency_key,
                    request_hash=request_hash,
                    receipt=receipt.model_dump(mode="json"),
                )
            )
            await self.session.commit()
            return receipt
        except Exception:
            await self.session.rollback()
            raise

    async def _schedule_change_plan(
        self,
        account_id: UUID,
        request: CreditScheduleChangeRequest,
        *,
        for_update: bool,
    ) -> ScheduleChangePlan:
        account = await self.repository.account(account_id, for_update=for_update)
        if account is None or account.kind != AccountKind.CREDIT.value:
            not_found("credit_account_not_found", "The credit account does not exist")
        if not for_update:
            check_version(
                account.version,
                request.expected_version,
                resource_type="account",
                resource_id=str(account.id),
                reload_path=f"/api/v1/credit-accounts/{account.id}",
            )
        cycles = await self.repository.cycles(account.id)
        amounts = await self.repository.amounts([item.id for item in cycles])
        affected: list[CreditCycle] = []
        for item in cycles:
            purchase, repaid = amounts.get(item.id, (0, 0))
            if not item.is_opening_cycle and purchase - repaid > 0:
                affected.append(item)
        today = self._today()
        affected_ids = [item.id for item in affected]
        checkpoints = await self.repository.checkpoints_for_cycles(affected_ids)
        ai_proposals = await self.repository.ai_proposals_for_cycles(affected_ids)
        statement_rows = await self.repository.statement_rows_for_cycles(affected_ids)
        checkpoint_counts: dict[UUID, int] = {}
        for checkpoint in checkpoints:
            assert checkpoint.credit_cycle_id is not None
            checkpoint_counts[checkpoint.credit_cycle_id] = (
                checkpoint_counts.get(checkpoint.credit_cycle_id, 0) + 1
            )
        transactions = await self.repository.transactions_for_cycles(affected_ids)
        periods = await self.repository.periods_for_cycles(affected_ids)
        plans = await self.repository.plans_for_start_cycles(affected_ids)
        purchase_amounts = await self.repository.purchase_amounts(
            [item.id for item in transactions if item.kind == TransactionKind.CREDIT_PURCHASE.value]
        )
        warnings: list[str] = []
        purchase_schedules: dict[UUID, CreditSchedule] = {}
        reference_schedules: dict[UUID, CreditSchedule] = {}
        previews: list[CreditScheduleAffectedCycle] = []
        transactions_by_cycle: dict[UUID, list[LedgerTransaction]] = {}
        for transaction in transactions:
            if transaction.credit_cycle_id is not None:
                transactions_by_cycle.setdefault(transaction.credit_cycle_id, []).append(
                    transaction
                )
        affected_by_id = {item.id: item for item in affected}
        periods_by_cycle: set[UUID] = {
            cycle_id
            for period in periods
            for cycle_id in (period.scheduled_cycle_id, period.effective_cycle_id)
            if cycle_id in affected_by_id
        }
        plans_by_cycle = {item.start_cycle_id for item in plans}
        for cycle in affected:
            groups: dict[CreditSchedule, list[LedgerTransaction]] = {}
            for transaction in transactions_by_cycle.get(cycle.id, []):
                if transaction.kind != TransactionKind.CREDIT_PURCHASE.value:
                    continue
                business_date = (
                    ensure_utc(transaction.occurred_at).astimezone(BUSINESS_TIMEZONE).date()
                )
                target = credit_schedule(
                    business_date,
                    request.statement_day,
                    request.due_day,
                    request.cycle_mode,
                )
                purchase_schedules[transaction.id] = target
                groups.setdefault(target, []).append(transaction)
            if not groups:
                # Installment-only cycles retain their statement-period semantics.
                groups[
                    schedule_for_statement(
                        date(
                            cycle.statement_date.year,
                            cycle.statement_date.month,
                            request.statement_day,
                        ),
                        request.statement_day,
                        request.due_day,
                        request.cycle_mode,
                    )
                ] = []
            non_purchase = (
                any(
                    item.kind != TransactionKind.CREDIT_PURCHASE.value
                    for item in transactions_by_cycle.get(cycle.id, [])
                )
                or cycle.id in periods_by_cycle
                or cycle.id in plans_by_cycle
            )
            if len(groups) > 1 and (non_purchase or checkpoint_counts.get(cycle.id, 0) > 0):
                warnings.append("credit_schedule_ambiguous_remap")
            if len(groups) == 1:
                reference_schedules[cycle.id] = next(iter(groups))
            for target, source_transactions in sorted(
                groups.items(), key=lambda item: (item[0].statement_date, item[0].period_start)
            ):
                grouped_remaining = sum(
                    purchase_amounts.get(item.id, 0) for item in source_transactions
                )
                if len(groups) == 1:
                    purchase, repaid = amounts.get(cycle.id, (0, 0))
                    grouped_remaining = purchase - repaid
                previews.append(
                    CreditScheduleAffectedCycle(
                        cycle_id=cycle.id,
                        current_version=cycle.version,
                        expected_version=cycle.version,
                        old_statement_date=cycle.statement_date,
                        old_due_date=cycle.due_date,
                        new_statement_date=target.statement_date,
                        new_due_date=target.due_date,
                        remaining_minor=grouped_remaining,
                        old_is_overdue=cycle.due_date < today,
                        new_is_overdue=target.due_date < today,
                        preserved_checkpoint_count=checkpoint_counts.get(cycle.id, 0),
                    )
                )
        if any(item.old_is_overdue for item in previews):
            warnings.append("overdue_credit_cycle_locked")
        for period in periods:
            cycle = affected_by_id.get(period.effective_cycle_id)
            if cycle is not None and (
                cycle.statement_date < today or await self.repository.cycle_has_repayment(cycle.id)
            ):
                warnings.append("installment_period_locked")
                break
        return ScheduleChangePlan(
            account=account,
            request=request,
            all_cycles=cycles,
            affected_cycles=affected,
            amounts=amounts,
            transactions=transactions,
            periods=periods,
            plans=plans,
            checkpoints=checkpoints,
            ai_proposals=ai_proposals,
            statement_rows=statement_rows,
            purchase_schedules=purchase_schedules,
            reference_schedules=reference_schedules,
            affected_previews=previews,
            warnings=warnings,
            old_cycle_mode=CreditCycleMode(
                account.cycle_mode or CreditCycleMode.STATEMENT_DAY_CUTOFF.value
            ),
            old_statement_day=account.statement_day,
            old_due_day=account.due_day,
        )

    def _result_for_plan(
        self, plan: ScheduleChangePlan, *, current_account_version: int
    ) -> CreditScheduleChangeResult:
        return CreditScheduleChangeResult(
            account_id=plan.account.id,
            cycle_mode=plan.request.cycle_mode,
            statement_day=plan.request.statement_day,
            due_day=plan.request.due_day,
            old_cycle_mode=plan.old_cycle_mode,
            old_statement_day=plan.old_statement_day,
            old_due_day=plan.old_due_day,
            affected_cycle_count=len(plan.affected_cycles),
            purchase_count=sum(
                item.kind == TransactionKind.CREDIT_PURCHASE.value for item in plan.transactions
            ),
            repayment_count=sum(
                item.kind == TransactionKind.REPAYMENT.value for item in plan.transactions
            ),
            installment_period_count=len(plan.periods),
            affected_cycles=plan.affected_previews,
            old_overdue_cycle_count=sum(item.old_is_overdue for item in plan.affected_previews),
            new_overdue_cycle_count=sum(item.new_is_overdue for item in plan.affected_previews),
            conflicts=list(plan.warnings),
            current_account_version=current_account_version,
            expected_account_version=plan.request.expected_version,
            warnings=list(plan.warnings),
        )

    def _raise_if_plan_locked(self, plan: ScheduleChangePlan) -> None:
        if not plan.warnings:
            return
        code = plan.warnings[0]
        if code == "overdue_credit_cycle_locked":
            message = "An overdue credit cycle cannot be moved by a schedule change"
        elif code == "installment_period_locked":
            message = "A locked installment period cannot move to another credit schedule"
        else:
            message = (
                "This change would split one credit cycle across multiple targets while "
                "repayments or installment obligations still require one unambiguous target"
            )
        conflict(
            code,
            message,
            details={
                "reason": code,
                "safe_to_reload": True,
                "available_actions": ["edit_schedule", "reload_credit_account"],
            },
        )

    async def _apply_schedule_change_plan(
        self, plan: ScheduleChangePlan
    ) -> CreditScheduleChangeResult:
        account = plan.account
        request = plan.request
        account.cycle_mode = request.cycle_mode.value
        account.statement_day = request.statement_day
        account.due_day = request.due_day
        account.version += 1
        account.updated_at = utc_now()
        await self.session.flush()

        affected_by_id = {item.id: item for item in plan.affected_cycles}
        target_cycles: dict[CreditSchedule, CreditCycle] = {}

        async def target_cycle(schedule: CreditSchedule) -> CreditCycle:
            known = target_cycles.get(schedule)
            if known is not None:
                return known
            created = await ensure_cycle_for_statement(
                self.repository, account, schedule.statement_date
            )
            target_cycles[schedule] = created
            return created

        locked_transactions = await TransactionRepository(self.session).get_many_for_update(
            [item.id for item in plan.transactions]
        )
        by_transaction_id = {item.id: item for item in locked_transactions}
        if set(by_transaction_id) != {item.id for item in plan.transactions}:
            conflict(
                "credit_schedule_preview_stale",
                "Credit schedule dependencies changed; preview again",
                details=self._preview_conflict_details(account.id, "transactions_changed"),
            )
        from fiscal_api.services.transactions import TransactionService

        transaction_service = TransactionService(self.session)
        for planned in plan.transactions:
            transaction = by_transaction_id[planned.id]
            if transaction.kind == TransactionKind.CREDIT_PURCHASE.value:
                target = await target_cycle(plan.purchase_schedules[transaction.id])
            else:
                assert transaction.credit_cycle_id is not None
                target = await target_cycle(plan.reference_schedules[transaction.credit_cycle_id])
            if transaction.credit_cycle_id != target.id:
                transaction.credit_cycle_id = target.id
                transaction.version += 1
                transaction.updated_at = utc_now()
                response = await transaction_service.response_with_relation(
                    transaction, list(transaction.postings)
                )
                transaction_service.record_external_update_revision(transaction, response)

        for period in plan.periods:
            changed = False
            if period.scheduled_cycle_id in affected_by_id:
                period.scheduled_cycle_id = (
                    await target_cycle(plan.reference_schedules[period.scheduled_cycle_id])
                ).id
                changed = True
            if period.effective_cycle_id in affected_by_id:
                period.effective_cycle_id = (
                    await target_cycle(plan.reference_schedules[period.effective_cycle_id])
                ).id
                changed = True
            if changed:
                period.version += 1
                period.updated_at = utc_now()

        for installment_plan in plan.plans:
            installment_plan.start_cycle_id = (
                await target_cycle(plan.reference_schedules[installment_plan.start_cycle_id])
            ).id
            installment_plan.version += 1
            installment_plan.updated_at = utc_now()

        await self.session.flush()
        await validate_credit_invariants(self.repository, {account.id})
        replacement_ids = {item.id for item in target_cycles.values()}
        for cycle in plan.affected_cycles:
            if cycle.id not in replacement_ids and not await self.repository.cycle_is_referenced(
                cycle.id
            ):
                await self.repository.delete_cycle(cycle)
        await self.session.flush()
        return self._result_for_plan(plan, current_account_version=account.version)

    def _dependencies_payload(self, plan: ScheduleChangePlan) -> dict[str, object]:
        affected_cycle_ids = {item.id for item in plan.affected_cycles}
        return {
            "account": {
                "id": str(plan.account.id),
                "version": plan.account.version,
                "cycle_mode": plan.account.cycle_mode,
                "statement_day": plan.account.statement_day,
                "due_day": plan.account.due_day,
                "archived_at": plan.account.archived_at.isoformat()
                if plan.account.archived_at
                else None,
            },
            "cycles": [
                {
                    "id": str(item.id),
                    "version": item.version,
                    "period_start": item.period_start.isoformat(),
                    "period_end": item.period_end.isoformat(),
                    "statement_date": item.statement_date.isoformat(),
                    "due_date": item.due_date.isoformat(),
                    "is_opening_cycle": item.is_opening_cycle,
                }
                for item in plan.all_cycles
            ],
            "transactions": [self._transaction_dependency(item) for item in plan.transactions],
            "periods": [self._period_dependency(item) for item in plan.periods],
            "plans": [self._plan_dependency(item) for item in plan.plans],
            "checkpoints": [self._checkpoint_dependency(item) for item in plan.checkpoints],
            "ai_proposals": [self._proposal_dependency(item) for item in plan.ai_proposals],
            "statement_import_rows": [
                self._statement_row_dependency(item) for item in plan.statement_rows
            ],
            "affected_cycle_ids": [
                str(item.id) for item in plan.all_cycles if item.id in affected_cycle_ids
            ],
        }

    @staticmethod
    def _transaction_dependency(transaction: LedgerTransaction) -> dict[str, object]:
        return {
            "id": str(transaction.id),
            "version": transaction.version,
            "credit_cycle_id": str(transaction.credit_cycle_id)
            if transaction.credit_cycle_id
            else None,
            "kind": transaction.kind,
            "occurred_at": transaction.occurred_at.isoformat(),
            "voided_at": transaction.voided_at.isoformat() if transaction.voided_at else None,
        }

    @staticmethod
    def _period_dependency(period: Any) -> dict[str, object]:
        return {
            "id": str(period.id),
            "version": period.version,
            "scheduled_cycle_id": str(period.scheduled_cycle_id),
            "effective_cycle_id": str(period.effective_cycle_id),
            "cancelled_at": period.cancelled_at.isoformat() if period.cancelled_at else None,
            "settled_early_at": period.settled_early_at.isoformat()
            if period.settled_early_at
            else None,
        }

    @staticmethod
    def _plan_dependency(plan: Any) -> dict[str, object]:
        return {
            "id": str(plan.id),
            "version": plan.version,
            "start_cycle_id": str(plan.start_cycle_id),
            "lifecycle": plan.lifecycle,
        }

    @staticmethod
    def _checkpoint_dependency(checkpoint: Any) -> dict[str, object]:
        return {
            "id": str(checkpoint.id),
            "credit_cycle_id": str(checkpoint.credit_cycle_id),
            "as_of": checkpoint.as_of.isoformat(),
            "actual_balance_minor": checkpoint.actual_balance_minor,
            "note": checkpoint.note,
            "created_at": checkpoint.created_at.isoformat(),
        }

    @staticmethod
    def _proposal_dependency(proposal: Any) -> dict[str, object]:
        return {
            "id": str(proposal.id),
            "version": proposal.version,
            "credit_cycle_id": str(proposal.credit_cycle_id),
            "status": proposal.status,
            "updated_at": proposal.updated_at.isoformat(),
        }

    @staticmethod
    def _statement_row_dependency(row: Any) -> dict[str, object]:
        return {
            "id": str(row.id),
            "version": row.version,
            "credit_cycle_id_candidate": str(row.credit_cycle_id_candidate),
            "confirmed_at": row.confirmed_at.isoformat() if row.confirmed_at else None,
            "updated_at": row.updated_at.isoformat(),
        }

    async def _required_preview(
        self, preview_id: UUID, account_id: UUID
    ) -> CreditScheduleChangePreview:
        preview = await self.repository.preview(preview_id)
        if preview is None or preview.account_id != account_id:
            conflict(
                "credit_schedule_preview_not_found",
                "The schedule preview token is invalid",
                details=self._preview_conflict_details(account_id, "preview_not_found"),
            )
        if preview.expires_at <= utc_now():
            conflict(
                "credit_schedule_preview_expired",
                "The schedule preview expired; preview again",
                details=self._preview_conflict_details(account_id, "preview_expired"),
            )
        return preview

    async def _operation_replay(
        self, idempotency_key: UUID, request_hash: str
    ) -> CreditScheduleChangeResult | None:
        operation = await self.repository.operation(idempotency_key)
        if operation is None:
            return None
        if operation.request_hash != request_hash:
            conflict(
                "idempotency_key_reused",
                "Idempotency-Key was used for a different request",
                details={"reason": "idempotency_key_reused", "safe_to_reload": True},
            )
        return CreditScheduleChangeResult.model_validate(operation.receipt)

    async def _next_data_revision(self) -> int:
        revision = await self.session.scalar(
            select(DataRevision.revision).where(DataRevision.id == 1)
        )
        if revision is None:
            raise RuntimeError("data_revision singleton is missing")
        return int(revision) + 1

    @staticmethod
    def _preview_conflict_details(account_id: UUID, reason: str) -> dict[str, object]:
        return {
            "reason": reason,
            "safe_to_reload": True,
            "reload_path": f"/api/v1/credit-accounts/{account_id}",
            "available_actions": ["reload_credit_account", "preview_schedule_change"],
        }

    @staticmethod
    def _hash(payload: object) -> str:
        return hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
        ).hexdigest()

    def _proposal_hash(self, account_id: UUID, request: CreditScheduleChangeRequest) -> str:
        return self._hash({"account_id": str(account_id), **request.model_dump(mode="json")})

    def _commit_hash(self, account_id: UUID, request: CreditScheduleChangeCommitRequest) -> str:
        return self._hash({"account_id": str(account_id), **request.model_dump(mode="json")})

    async def list_cycles(
        self, account_id: UUID, *, cursor: str | None, limit: int
    ) -> CreditCyclePage:
        account = await self._required_account(account_id)
        cursor_end, cursor_id = self._decode_cursor(cursor)
        cycles = await self._cycles_with_projection(account)
        if cursor_end is not None and cursor_id is not None:
            cycles = [
                item
                for item in cycles
                if item.period_end < cursor_end
                or (item.period_end == cursor_end and str(item.id) < str(cursor_id))
            ]
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
        return response

    async def get_cycle(self, cycle_id: UUID) -> CreditCycleResponse:
        cycle = await self.repository.cycle(cycle_id)
        if cycle is not None:
            account = await self._required_account(cycle.account_id)
        else:
            account = None
            for candidate in await self.repository.active_accounts():
                cycles = await self.repository.cycles(candidate.id)
                projected = project_current_cycle(candidate, today=self._today(), cycles=cycles)
                if projected.id == cycle_id:
                    account = candidate
                    cycle = projected
                    break
            if account is None or cycle is None:
                not_found("credit_cycle_not_found", "The credit cycle does not exist")
        amounts = await self.repository.amounts([cycle.id])
        return await self._cycle_response(cycle, account, amounts.get(cycle.id, (0, 0)))

    async def _account_response(self, account: Account) -> CreditAccountSummary:
        cycles = await self._cycles_with_projection(account)
        current = project_current_cycle(account, today=self._today(), cycles=cycles)
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

    async def _cycles_with_projection(self, account: Account) -> list[CreditCycle]:
        cycles = await self.repository.cycles(account.id)
        projected = project_current_cycle(account, today=self._today(), cycles=cycles)
        if not any(item.id == projected.id for item in cycles):
            cycles.append(projected)
        return sorted(cycles, key=lambda item: (item.period_end, str(item.id)), reverse=True)

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
