from __future__ import annotations

import base64
import hashlib
import json
from calendar import monthrange
from datetime import date, datetime
from uuid import UUID, uuid4

from pydantic import BaseModel
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import PostingResponse, TransactionResponse
from fiscal_api.api.p5_schemas import (
    InstallmentActionRequest,
    InstallmentAffectedCycle,
    InstallmentCancellationPreview,
    InstallmentCancellationResult,
    InstallmentCreate,
    InstallmentCycleOption,
    InstallmentEligibility,
    InstallmentLiabilities,
    InstallmentLiabilityGroup,
    InstallmentPeriodPreview,
    InstallmentPeriodResponse,
    InstallmentPeriodStatus,
    InstallmentPlanChangePreview,
    InstallmentPlanPage,
    InstallmentPlanPreview,
    InstallmentPlanResponse,
    InstallmentPlanStatus,
    InstallmentPurchaseCreate,
    InstallmentPurchaseCreateResponse,
    InstallmentPurchasePreview,
    InstallmentReplacement,
    InstallmentReverseSettlementPreview,
    InstallmentReverseSettlementResult,
    InstallmentSettlementPreview,
    InstallmentSettlementRequest,
    InstallmentSettlementResult,
    InstallmentTeaser,
)
from fiscal_api.core.time import BUSINESS_TIMEZONE, ensure_utc, utc_now
from fiscal_api.db.models import (
    Account,
    AccountKind,
    Category,
    CreditCycle,
    CreditCycleMode,
    CreditCycleStatus,
    InstallmentLedgerLink,
    InstallmentOperation,
    InstallmentPeriod,
    InstallmentPlan,
    InstallmentPlanRevision,
    LedgerTransaction,
    Posting,
    PostingRole,
    RevisionEvent,
    TransactionKind,
    TransactionRevision,
    TransactionSource,
)
from fiscal_api.repositories.credit import CreditRepository
from fiscal_api.repositories.installments import InstallmentRepository
from fiscal_api.repositories.transactions import TransactionRepository
from fiscal_api.services.common import (
    acquire_mutation_lock,
    checked_int64,
    conflict,
    invalid,
    not_found,
)
from fiscal_api.services.credit import (
    credit_schedule,
    ensure_cycle_for_statement,
    ensure_regular_cycle,
    validate_credit_invariants,
)
from fiscal_api.services.transactions import TransactionService


def _shift_statement_month(value: date, delta: int, day: int) -> date:
    month_index = value.year * 12 + value.month - 1 + delta
    year, month_zero = divmod(month_index, 12)
    month = month_zero + 1
    return date(year, month, min(day, monthrange(year, month)[1]))


class InstallmentService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = InstallmentRepository(session)
        self.credit_repository = CreditRepository(session)
        self.transaction_repository = TransactionRepository(session)
        self.transaction_service = TransactionService(session)

    @staticmethod
    def _today() -> date:
        return utc_now().astimezone(BUSINESS_TIMEZONE).date()

    async def create(
        self, request: InstallmentCreate, key: UUID, *, commit: bool = True
    ) -> InstallmentPlanResponse:
        await acquire_mutation_lock(self.session)
        request_hash = self._hash(request)
        replay = await self.repository.plan_for_idempotency(key)
        if replay is not None:
            if replay.create_request_hash != request_hash:
                conflict("idempotency_key_reused", "The idempotency key has different input")
            return await self.response(replay)
        purchase = await self.repository.transaction(request.purchase_transaction_id)
        if purchase is None:
            not_found("transaction_not_found", "The purchase transaction does not exist")
        if await self.repository.plan_for_purchase(purchase.id) is not None:
            conflict("installment_plan_in_use", "The purchase already has an installment plan")
        account, principal, natural = await self._eligible_purchase(purchase)
        if request.start_statement_date < natural.statement_date:
            invalid(
                "purchase_not_eligible", "The installment start cannot predate the purchase cycle"
            )
        cycles = await self._materialize_cycles(
            account, request.start_statement_date, request.installment_count
        )
        fee: LedgerTransaction | None = None
        if request.total_fee_minor:
            assert request.fee_category_id is not None and request.fee_occurred_at is not None
            category = await self.session.get(Category, request.fee_category_id)
            if (
                category is None
                or category.direction != "expense"
                or category.archived_at is not None
            ):
                invalid("invalid_installment_schedule", "The fee category must be active expense")
            occurred = ensure_utc(request.fee_occurred_at)
            if occurred < ensure_utc(purchase.occurred_at) or occurred > utc_now():
                invalid("invalid_installment_schedule", "The fee occurrence time is invalid")
            fee = LedgerTransaction(
                kind=TransactionKind.INSTALLMENT_FEE.value,
                occurred_at=occurred,
                title=f"{purchase.title} · 分期手续费",
                note=None,
                category_id=category.id,
                credit_cycle_id=None,
                source="system",
                idempotency_key=uuid4(),
                request_hash=request_hash,
            )
            fee.postings.append(
                Posting(
                    account_id=account.id,
                    role=PostingRole.ACCOUNT.value,
                    amount_minor=-request.total_fee_minor,
                    position=0,
                )
            )
            self.session.add(fee)
            await self.session.execute(
                update(Account)
                .where(Account.id == account.id)
                .values(usage_count=Account.usage_count + 1)
            )
            await self.session.execute(
                update(Category)
                .where(Category.id == category.id)
                .values(usage_count=Category.usage_count + 1)
            )
            await self.session.flush()
        plan = InstallmentPlan(
            purchase_transaction_id=purchase.id,
            credit_account_id=account.id,
            fee_transaction_id=fee.id if fee else None,
            fee_category_id=fee.category_id if fee else None,
            installment_count=request.installment_count,
            start_cycle_id=cycles[0].id,
            lifecycle="active",
            create_idempotency_key=key,
            create_request_hash=request_hash,
        )
        self.session.add(plan)
        await self.session.flush()
        principal_split = self.allocate(principal, request.installment_count)
        fee_split = self.allocate(request.total_fee_minor, request.installment_count)
        periods: list[InstallmentPeriod] = []
        for index, cycle in enumerate(cycles):
            if principal_split[index] + fee_split[index] == 0:
                invalid("invalid_installment_schedule", "Every installment must be non-zero")
            periods.append(
                InstallmentPeriod(
                    plan_id=plan.id,
                    sequence=index + 1,
                    scheduled_cycle_id=cycle.id,
                    effective_cycle_id=cycle.id,
                    principal_minor=principal_split[index],
                    fee_minor=fee_split[index],
                )
            )
        self.session.add_all(periods)
        self.session.add(
            InstallmentLedgerLink(
                transaction_id=purchase.id,
                plan_id=plan.id,
                operation_id=None,
                role="purchase",
            )
        )
        if fee is not None:
            self.session.add(
                InstallmentLedgerLink(
                    transaction_id=fee.id, plan_id=plan.id, operation_id=None, role="fee"
                )
            )
        await self.session.flush()
        await self.session.refresh(plan, ["periods"])
        await validate_credit_invariants(
            self.credit_repository, {account.id}, repayment_error=False
        )
        response = await self.response(plan)
        self.repository.add_revision(
            InstallmentPlanRevision(
                plan_id=plan.id,
                version=1,
                event="created",
                snapshot=response.model_dump(mode="json"),
            )
        )
        if fee is not None:
            fee_response = await self.transaction_service.response_with_relation(
                fee, list(fee.postings)
            )
            self.transaction_repository.add_revision(
                TransactionRevision(
                    transaction_id=fee.id,
                    version=1,
                    event=RevisionEvent.CREATED.value,
                    snapshot=fee_response.model_dump(mode="json"),
                )
            )
        if commit:
            await self.session.commit()
        else:
            await self.session.flush()
        return response

    async def preview_purchase(
        self, request: InstallmentPurchaseCreate
    ) -> InstallmentPurchasePreview:
        key = uuid4()
        nested = await self.session.begin_nested()
        try:
            created = await self._create_purchase(request, key, commit=False)
            periods = [self._period_preview_from_response(item) for item in created.plan.periods]
            return InstallmentPurchasePreview(
                purchase_amount_minor=created.purchase.amount_minor,
                total_fee_minor=created.plan.fee_minor,
                total_financed_minor=created.plan.total_financed_minor,
                start_statement_date=created.plan.start_statement_date,
                periods=periods,
            )
        finally:
            if nested.is_active:
                await nested.rollback()

    async def create_purchase(
        self, request: InstallmentPurchaseCreate, key: UUID
    ) -> InstallmentPurchaseCreateResponse:
        try:
            return await self._create_purchase(request, key, commit=True)
        except Exception:
            await self.session.rollback()
            raise

    async def _create_purchase(
        self, request: InstallmentPurchaseCreate, key: UUID, *, commit: bool
    ) -> InstallmentPurchaseCreateResponse:
        purchase = await self.transaction_service.create_credit_purchase(
            request.purchase, key, commit=False
        )
        account = await self.session.get(Account, request.purchase.account_id)
        if account is None or account.statement_day is None or account.due_day is None:
            invalid("invalid_installment_schedule", "Credit account schedule is missing")
        purchase_date = (
            ensure_utc(request.purchase.occurred_at).astimezone(BUSINESS_TIMEZONE).date()
        )
        natural = credit_schedule(
            purchase_date,
            account.statement_day,
            account.due_day,
            CreditCycleMode(account.cycle_mode or CreditCycleMode.STATEMENT_DAY_CUTOFF.value),
        ).statement_date
        start = request.start_statement_date or natural
        if start < natural or start.day != account.statement_day:
            invalid(
                "invalid_installment_schedule",
                "Installment start must be an eligible statement date",
            )
        plan = await self.create(
            InstallmentCreate(
                purchase_transaction_id=purchase.id,
                installment_count=request.installment_count,
                total_fee_minor=request.total_fee_minor,
                fee_category_id=request.fee_category_id,
                fee_occurred_at=request.fee_occurred_at,
                start_statement_date=start,
            ),
            key,
            commit=False,
        )
        response = InstallmentPurchaseCreateResponse(purchase=purchase, plan=plan)
        if commit:
            await self.session.commit()
        else:
            await self.session.flush()
        return response

    async def get(self, plan_id: UUID) -> InstallmentPlanResponse:
        plan = await self.repository.plan(plan_id)
        if plan is None:
            not_found("installment_plan_not_found", "The installment plan does not exist")
        return await self.response(plan)

    async def list(
        self,
        *,
        account_id: UUID | None,
        status: InstallmentPlanStatus | None,
        cursor: str | None,
        limit: int,
    ) -> InstallmentPlanPage:
        cursor_created_at, cursor_id = self._decode_cursor(cursor)
        plans = await self.repository.plans(
            account_id=account_id,
            status=status.value if status else None,
            limit=limit,
            cursor_created_at=cursor_created_at,
            cursor_id=cursor_id,
        )
        responses = [await self.response(plan) for plan in plans]
        has_more = len(responses) > limit
        page = responses[:limit]
        return InstallmentPlanPage(
            items=page,
            next_cursor=(self._encode_cursor(plans[len(page) - 1]) if has_more and page else None),
        )

    async def eligibility(self, purchase_id: UUID) -> InstallmentEligibility:
        transaction = await self.repository.transaction(purchase_id)
        if transaction is None:
            not_found("transaction_not_found", "The transaction does not exist")
        if (
            transaction.kind != TransactionKind.CREDIT_PURCHASE.value
            or len(transaction.postings) != 1
            or transaction.credit_cycle_id is None
        ):
            invalid("purchase_not_eligible", "The transaction is not a credit purchase")
        posting = transaction.postings[0]
        cycle = await self.credit_repository.cycle(transaction.credit_cycle_id)
        if cycle is None:
            invalid("purchase_not_eligible", "The purchase cycle does not exist")
        try:
            account, principal, cycle = await self._eligible_purchase(transaction)
            options = await self.options(purchase_id, 60)
            return InstallmentEligibility(
                purchase_transaction_id=purchase_id,
                eligible=True,
                reason_code=None,
                credit_account_id=account.id,
                principal_minor=principal,
                natural_statement_date=cycle.statement_date,
                start_options=options,
            )
        except Exception as error:
            from fiscal_api.core.errors import APIError

            if not isinstance(error, APIError):
                raise
            return InstallmentEligibility(
                purchase_transaction_id=purchase_id,
                eligible=False,
                reason_code=error.code,
                credit_account_id=posting.account_id,
                principal_minor=abs(posting.amount_minor),
                natural_statement_date=cycle.statement_date,
                start_options=[],
            )

    async def options(self, purchase_id: UUID, months: int) -> list[InstallmentCycleOption]:
        transaction = await self.repository.transaction(purchase_id)
        if transaction is None:
            not_found("transaction_not_found", "The transaction does not exist")
        plan = await self.repository.plan_for_purchase(transaction.id)
        if plan is None:
            account, _principal, natural = await self._eligible_purchase(transaction)
        else:
            account, natural = await self._planned_purchase_context(transaction, plan)
        assert account.statement_day is not None and account.due_day is not None
        anchor = natural.statement_date
        if plan is not None:
            current_statement = credit_schedule(
                self._today(),
                account.statement_day,
                account.due_day,
                CreditCycleMode(account.cycle_mode or CreditCycleMode.STATEMENT_DAY_CUTOFF.value),
            ).statement_date
            anchor = max(anchor, current_statement)
        result: list[InstallmentCycleOption] = []
        for offset in range(months):
            statement = _shift_statement_month(anchor, offset, account.statement_day)
            due = self._due_date(statement, account.statement_day, account.due_day)
            existing = await self.repository.cycle_by_statement(account.id, statement)
            result.append(
                InstallmentCycleOption(
                    cycle_id=existing.id if existing else None,
                    statement_date=statement,
                    due_date=due,
                    existing=existing is not None,
                    eligible=statement >= self._today(),
                )
            )
        return result

    async def liabilities(self, account_id: UUID) -> InstallmentLiabilities:
        plans = await self.repository.plans(
            account_id=account_id,
            status=None,
            limit=1000,
            cursor_created_at=None,
            cursor_id=None,
        )
        groups: dict[str, list[tuple[InstallmentPlanResponse, InstallmentPeriodResponse]]] = {}
        total = 0
        for plan in plans:
            response = await self.response(plan)
            for period in response.periods:
                if (
                    period.cancelled_at is None
                    and period.settled_early_at is None
                    and period.cycle_status is not CreditCycleStatus.SETTLED
                    and period.effective_statement_date >= self._today()
                ):
                    month = period.effective_statement_date.strftime("%Y-%m")
                    groups.setdefault(month, []).append((response, period))
                    total = checked_int64(total + period.amount_due_minor, label="future liability")
        items: list[InstallmentLiabilityGroup] = []
        for month, values in sorted(groups.items()):
            principal = sum(period.principal_minor for _plan, period in values)
            fee = sum(period.fee_minor for _plan, period in values)
            unique = {plan.id: plan for plan, _period in values}
            items.append(
                InstallmentLiabilityGroup(
                    month=month,
                    principal_scheduled_gross_minor=principal,
                    fee_scheduled_gross_minor=fee,
                    total_scheduled_gross_minor=checked_int64(principal + fee),
                    period_count=len(values),
                    plans=[self.teaser(plan) for plan in unique.values()],
                )
            )
        return InstallmentLiabilities(
            account_id=account_id, total_future_scheduled_gross_minor=total, groups=items
        )

    async def preview_update(
        self, plan_id: UUID, request: InstallmentReplacement
    ) -> InstallmentPlanChangePreview:
        plan = await self.repository.plan(plan_id)
        if plan is None:
            not_found("installment_plan_not_found", "The installment plan does not exist")
        if plan.version != request.expected_version:
            conflict("version_conflict", "The installment plan version changed")
        current = await self.response(plan)
        purchase = await self.repository.transaction(plan.purchase_transaction_id)
        if purchase is None:
            raise RuntimeError("installment purchase missing")
        if current.status in {
            InstallmentPlanStatus.CANCELLED,
            InstallmentPlanStatus.SETTLED_EARLY,
            InstallmentPlanStatus.COMPLETED,
            InstallmentPlanStatus.PARTIALLY_CANCELLED,
        }:
            conflict("installment_plan_in_use", "Only an active plan can be replaced")
        locked = [item for item in current.periods if item.locked]
        current_fee = (
            await self.repository.transaction(plan.fee_transaction_id)
            if plan.fee_transaction_id
            else None
        )
        if locked and (
            request.purchase.amount_minor != current.principal_minor
            or request.purchase.occurred_at != ensure_utc(purchase.occurred_at)
            or request.purchase.account_id != plan.credit_account_id
            or request.purchase.category_id != purchase.category_id
            or request.total_fee_minor != current.fee_minor
            or request.fee_category_id != plan.fee_category_id
            or request.fee_occurred_at
            != (ensure_utc(current_fee.occurred_at) if current_fee else None)
            or request.start_statement_date != current.start_statement_date
        ):
            conflict("installment_period_locked", "Locked allocation fields are immutable")
        if locked and request.installment_count < len(locked):
            conflict("installment_locked_allocation_exceeded", "New count is below locked prefix")
        if len(locked) == len(current.periods) and request.installment_count != len(locked):
            conflict("installment_period_locked", "All periods are locked")
        account = await self.session.get(Account, request.purchase.account_id)
        if (
            account is None
            or account.kind != AccountKind.CREDIT.value
            or account.archived_at is not None
        ):
            invalid("invalid_installment_schedule", "Replacement account must be credit")
        category = await self.session.get(Category, request.purchase.category_id)
        if category is None or category.direction != "expense" or category.archived_at:
            invalid("invalid_installment_schedule", "Purchase category must be active expense")
        purchase_date = (
            ensure_utc(request.purchase.occurred_at).astimezone(BUSINESS_TIMEZONE).date()
        )
        assert account.statement_day is not None and account.due_day is not None
        natural_statement = credit_schedule(
            purchase_date,
            account.statement_day,
            account.due_day,
            CreditCycleMode(account.cycle_mode or CreditCycleMode.STATEMENT_DAY_CUTOFF.value),
        ).statement_date
        if natural_statement < self._today() or request.start_statement_date < natural_statement:
            invalid("purchase_not_eligible", "Replacement purchase cycle must remain open")
        if request.total_fee_minor:
            assert request.fee_category_id is not None and request.fee_occurred_at is not None
            fee_category = await self.session.get(Category, request.fee_category_id)
            if (
                fee_category is None
                or fee_category.direction != "expense"
                or fee_category.archived_at
            ):
                invalid("invalid_installment_schedule", "Fee category must be active expense")
            fee_time = ensure_utc(request.fee_occurred_at)
            if fee_time < ensure_utc(request.purchase.occurred_at) or fee_time > utc_now():
                invalid("invalid_installment_schedule", "Fee occurrence time is invalid")
        prefix_principal = sum(item.principal_minor for item in locked)
        prefix_fee = sum(item.fee_minor for item in locked)
        suffix_count = request.installment_count - len(locked)
        remaining_principal = request.purchase.amount_minor - prefix_principal
        remaining_fee = request.total_fee_minor - prefix_fee
        if remaining_principal < 0 or remaining_fee < 0:
            conflict("installment_locked_allocation_exceeded", "Locked amounts exceed replacement")
        if suffix_count == 0 and remaining_principal + remaining_fee:
            conflict("installment_locked_allocation_exceeded", "Replacement needs a future suffix")
        principal_split = self.allocate(remaining_principal, suffix_count) if suffix_count else []
        fee_split = self.allocate(remaining_fee, suffix_count) if suffix_count else []
        previews = [self._period_preview_from_response(item) for item in locked]
        assert account.statement_day is not None and account.due_day is not None
        for index in range(len(locked), request.installment_count):
            statement = _shift_statement_month(
                request.start_statement_date, index, account.statement_day
            )
            existing = await self.repository.cycle_by_statement(account.id, statement)
            principal_minor = principal_split[index - len(locked)]
            fee_minor = fee_split[index - len(locked)]
            if principal_minor + fee_minor == 0:
                invalid("invalid_installment_schedule", "Every installment must be non-zero")
            previews.append(
                InstallmentPeriodPreview(
                    sequence=index + 1,
                    scheduled_cycle_id=existing.id if existing else None,
                    effective_cycle_id=existing.id if existing else None,
                    scheduled_statement_date=statement,
                    effective_statement_date=statement,
                    due_date=self._due_date(statement, account.statement_day, account.due_day),
                    principal_minor=principal_minor,
                    fee_minor=fee_minor,
                    amount_due_minor=checked_int64(principal_minor + fee_minor),
                    locked=False,
                    status=InstallmentPeriodStatus.SCHEDULED,
                )
            )
        proposed = InstallmentPlanPreview(
            id=plan.id,
            purchase_transaction_id=plan.purchase_transaction_id,
            credit_account_id=account.id,
            fee_transaction_id=plan.fee_transaction_id if request.total_fee_minor else None,
            fee_category_id=request.fee_category_id,
            fee_occurred_at=request.fee_occurred_at,
            title=request.purchase.title,
            status=InstallmentPlanStatus.ACTIVE,
            principal_minor=request.purchase.amount_minor,
            fee_minor=request.total_fee_minor,
            total_financed_minor=checked_int64(
                request.purchase.amount_minor + request.total_fee_minor
            ),
            installment_count=request.installment_count,
            start_statement_date=request.start_statement_date,
            locked_count=len(locked),
            future_count=len(previews) - len(locked),
            cancelled_count=0,
            cycle_settled_count=sum(
                item.status is InstallmentPeriodStatus.CYCLE_SETTLED for item in previews
            ),
            scheduled_gross_minor=sum(item.amount_due_minor for item in previews),
            future_scheduled_gross_minor=sum(
                item.amount_due_minor
                for item in previews
                if not item.locked and item.effective_statement_date >= self._today()
            ),
            next_period=next((item for item in previews if not item.locked), None),
            periods=previews,
        )
        affected = self._affected_cycles(current.periods, previews)
        return InstallmentPlanChangePreview(
            current_plan=current,
            proposed_plan=proposed,
            locked_periods=locked,
            future_periods=[item for item in previews if not item.locked],
            affected_cycles=affected,
            warnings=[],
        )

    async def update(
        self, plan_id: UUID, request: InstallmentReplacement
    ) -> InstallmentPlanResponse:
        await acquire_mutation_lock(self.session)
        preview = await self.preview_update(plan_id, request)
        plan = await self._required_plan(plan_id, request.expected_version)
        purchase = await self.repository.transaction(plan.purchase_transaction_id)
        if purchase is None:
            raise RuntimeError("installment purchase missing")
        account = await self.session.get(Account, request.purchase.account_id)
        if account is None:
            raise RuntimeError("replacement account missing")
        cycles = await self._materialize_cycles(
            account, request.start_statement_date, request.installment_count
        )
        purchase_posting = purchase.postings[0]
        old_purchase_account_id = purchase_posting.account_id
        old_purchase_category_id = purchase.category_id
        purchase_posting.account_id = account.id
        purchase_posting.amount_minor = -request.purchase.amount_minor
        purchase.occurred_at = ensure_utc(request.purchase.occurred_at)
        purchase.title = request.purchase.title
        purchase.note = request.purchase.note
        purchase.category_id = request.purchase.category_id
        purchase.credit_cycle_id = (
            await ensure_regular_cycle(
                self.credit_repository,
                account,
                ensure_utc(purchase.occurred_at).astimezone(BUSINESS_TIMEZONE).date(),
            )
        ).id
        purchase.version += 1
        purchase.updated_at = utc_now()
        if old_purchase_account_id != account.id:
            await self.session.execute(
                update(Account)
                .where(Account.id == old_purchase_account_id)
                .values(usage_count=Account.usage_count - 1)
            )
            await self.session.execute(
                update(Account)
                .where(Account.id == account.id)
                .values(usage_count=Account.usage_count + 1)
            )
        if old_purchase_category_id != request.purchase.category_id:
            if old_purchase_category_id is not None:
                await self.session.execute(
                    update(Category)
                    .where(Category.id == old_purchase_category_id)
                    .values(usage_count=Category.usage_count - 1)
                )
            await self.session.execute(
                update(Category)
                .where(Category.id == request.purchase.category_id)
                .values(usage_count=Category.usage_count + 1)
            )
        fee_link = await self.repository.plan_link(plan.id, "fee")
        fee_transaction_id = plan.fee_transaction_id or (
            fee_link.transaction_id if fee_link else None
        )
        fee = await self.repository.transaction(fee_transaction_id) if fee_transaction_id else None
        fee_event: RevisionEvent | None = None
        if request.total_fee_minor:
            if fee is None:
                fee = self._system_transaction(
                    kind=TransactionKind.INSTALLMENT_FEE,
                    amount=request.total_fee_minor,
                    occurred=ensure_utc(request.fee_occurred_at),  # type: ignore[arg-type]
                    title=f"{purchase.title} · 分期手续费",
                    category_id=request.fee_category_id,
                    account_id=account.id,
                    destination_account_id=None,
                    cycle_id=None,
                    request_hash=plan.create_request_hash,
                )
                fee.postings[0].amount_minor = -request.total_fee_minor
                self.session.add(fee)
                await self.session.execute(
                    update(Account)
                    .where(Account.id == account.id)
                    .values(usage_count=Account.usage_count + 1)
                )
                await self.session.execute(
                    update(Category)
                    .where(Category.id == request.fee_category_id)
                    .values(usage_count=Category.usage_count + 1)
                )
                await self.session.flush()
                self.session.add(
                    InstallmentLedgerLink(
                        transaction_id=fee.id,
                        plan_id=plan.id,
                        operation_id=None,
                        role="fee",
                    )
                )
                fee_event = RevisionEvent.CREATED
            else:
                was_voided = fee.voided_at is not None
                old_fee_account_id = fee.postings[0].account_id
                old_fee_category_id = fee.category_id
                fee.voided_at = None
                fee.occurred_at = ensure_utc(request.fee_occurred_at)  # type: ignore[arg-type]
                fee.category_id = request.fee_category_id
                fee.postings[0].account_id = account.id
                fee.postings[0].amount_minor = -request.total_fee_minor
                fee.version += 1
                fee.updated_at = utc_now()
                fee_event = RevisionEvent.RESTORED if was_voided else RevisionEvent.UPDATED
                if old_fee_account_id != account.id:
                    await self.session.execute(
                        update(Account)
                        .where(Account.id == old_fee_account_id)
                        .values(usage_count=Account.usage_count - 1)
                    )
                    await self.session.execute(
                        update(Account)
                        .where(Account.id == account.id)
                        .values(usage_count=Account.usage_count + 1)
                    )
                if old_fee_category_id != request.fee_category_id:
                    if old_fee_category_id is not None:
                        await self.session.execute(
                            update(Category)
                            .where(Category.id == old_fee_category_id)
                            .values(usage_count=Category.usage_count - 1)
                        )
                    await self.session.execute(
                        update(Category)
                        .where(Category.id == request.fee_category_id)
                        .values(usage_count=Category.usage_count + 1)
                    )
            plan.fee_transaction_id = fee.id
            plan.fee_category_id = request.fee_category_id
        elif fee is not None:
            fee.voided_at = utc_now()
            fee.version += 1
            fee.updated_at = utc_now()
            plan.fee_transaction_id = None
            plan.fee_category_id = None
            fee_event = RevisionEvent.VOIDED
        locked_count = preview.proposed_plan.locked_count
        for period in list(plan.periods[locked_count:]):
            await self.session.delete(period)
        await self.session.flush()
        for item in preview.proposed_plan.periods[locked_count:]:
            cycle = cycles[item.sequence - 1]
            self.session.add(
                InstallmentPeriod(
                    plan_id=plan.id,
                    sequence=item.sequence,
                    scheduled_cycle_id=cycle.id,
                    effective_cycle_id=cycle.id,
                    principal_minor=item.principal_minor,
                    fee_minor=item.fee_minor,
                )
            )
        plan.credit_account_id = account.id
        plan.installment_count = request.installment_count
        plan.start_cycle_id = cycles[0].id
        plan.version += 1
        plan.updated_at = utc_now()
        await self.session.flush()
        await self.session.refresh(plan, ["periods"])
        await validate_credit_invariants(
            self.credit_repository, {account.id}, repayment_error=False
        )
        response = await self.response(plan)
        purchase_response = await self.transaction_service.response_with_relation(
            purchase, list(purchase.postings)
        )
        self.transaction_repository.add_revision(
            TransactionRevision(
                transaction_id=purchase.id,
                version=purchase.version,
                event=RevisionEvent.UPDATED.value,
                snapshot=purchase_response.model_dump(mode="json"),
            )
        )
        if fee is not None and fee_event is not None:
            fee_response = await self.transaction_service.response_with_relation(
                fee, list(fee.postings)
            )
            self.transaction_repository.add_revision(
                TransactionRevision(
                    transaction_id=fee.id,
                    version=fee.version,
                    event=fee_event.value,
                    snapshot=fee_response.model_dump(mode="json"),
                )
            )
        self.repository.add_revision(
            InstallmentPlanRevision(
                plan_id=plan.id,
                version=plan.version,
                event="updated",
                snapshot=response.model_dump(mode="json"),
            )
        )
        await self.session.commit()
        return response

    async def settle_early(
        self, plan_id: UUID, request: InstallmentSettlementRequest, key: UUID
    ) -> InstallmentSettlementResult:
        await acquire_mutation_lock(self.session)
        request_hash = self._hash_model(request)
        replay = await self.repository.operation_for_key(key)
        if replay is not None:
            if (
                replay.plan_id != plan_id
                or replay.request_hash != request_hash
                or replay.kind != "settle_early"
            ):
                conflict("installment_operation_conflict", "Operation key has different input")
            if replay.result_snapshot is None:
                raise RuntimeError("completed installment operation has no snapshot")
            result = InstallmentSettlementResult.model_validate(replay.result_snapshot)
            return result.model_copy(update={"replayed": True})
        plan = await self._required_plan(plan_id, request.expected_version)
        current = await self.response(plan)
        if current.status is InstallmentPlanStatus.SETTLED_EARLY:
            conflict("installment_already_settled", "The plan is already settled early")
        if current.status is InstallmentPlanStatus.CANCELLED:
            conflict("installment_already_cancelled", "The plan is cancelled")
        if any(
            item.locked and item.cycle_status is not CreditCycleStatus.SETTLED
            for item in current.periods
        ):
            conflict("installment_settlement_not_ready", "Locked cycles must be fully settled")
        remaining = [
            period
            for period, response in zip(plan.periods, current.periods, strict=True)
            if response.cancelled_at is None
            and response.settled_early_at is None
            and response.cycle_status is not CreditCycleStatus.SETTLED
        ]
        if not remaining:
            conflict("installment_already_settled", "The plan has no remaining installments")
        account, payment = await self._validated_settlement_inputs(plan, request)
        target = (await self._materialize_cycles(account, request.target_statement_date, 1))[0]
        amount = checked_int64(
            sum(item.principal_minor + item.fee_minor for item in remaining),
            label="settlement amount",
        )
        occurred = ensure_utc(request.occurred_at)
        operation = InstallmentOperation(
            plan_id=plan.id,
            kind="settle_early",
            idempotency_key=key,
            request_hash=request_hash,
            target_statement_date=target.statement_date,
            payment_account_id=payment.id,
            occurred_at=occurred,
        )
        self.session.add(operation)
        await self.session.flush()
        repayment = self._system_transaction(
            kind=TransactionKind.REPAYMENT,
            amount=amount,
            occurred=occurred,
            title=f"{current.title} · 提前结清",
            category_id=None,
            account_id=payment.id,
            destination_account_id=account.id,
            cycle_id=target.id,
            request_hash=request_hash,
        )
        self.session.add(repayment)
        await self.session.execute(
            update(Account)
            .where(Account.id.in_([payment.id, account.id]))
            .values(usage_count=Account.usage_count + 1)
        )
        await self.session.flush()
        self.session.add(
            InstallmentLedgerLink(
                transaction_id=repayment.id,
                plan_id=plan.id,
                operation_id=operation.id,
                role="settlement_repayment",
            )
        )
        now = utc_now()
        for period in remaining:
            period.effective_cycle_id = target.id
            period.settled_early_at = now
            period.version += 1
            period.updated_at = now
        plan.lifecycle = "settled_early"
        plan.version += 1
        plan.updated_at = now
        await self.session.flush()
        await validate_credit_invariants(self.credit_repository, {account.id}, repayment_error=True)
        plan_response = await self.response(plan)
        repayment_response = await self.transaction_service.response_with_relation(
            repayment, list(repayment.postings)
        )
        result = InstallmentSettlementResult(
            operation_id=operation.id,
            plan=plan_response,
            repayment_transaction=repayment_response,
            replayed=False,
        )
        operation.completed_at = now
        operation.result_snapshot = result.model_dump(mode="json")
        self._record_operation_revisions(
            plan, "settled_early", plan_response, repayment, repayment_response
        )
        await self.session.commit()
        return result

    async def settlement_preview(
        self, plan_id: UUID, request: InstallmentSettlementRequest
    ) -> InstallmentSettlementPreview:
        plan = await self.repository.plan(plan_id)
        if plan is None or plan.version != request.expected_version:
            if plan is None:
                not_found("installment_plan_not_found", "The installment plan does not exist")
            conflict("version_conflict", "The installment plan version changed")
        current = await self.response(plan)
        remaining = [
            item
            for item in current.periods
            if item.cancelled_at is None
            and item.settled_early_at is None
            and item.cycle_status is not CreditCycleStatus.SETTLED
        ]
        if not remaining or any(
            item.locked and item.cycle_status is not CreditCycleStatus.SETTLED
            for item in current.periods
        ):
            conflict("installment_settlement_not_ready", "The plan is not ready to settle")
        account, payment = await self._validated_settlement_inputs(plan, request)
        assert account.statement_day is not None and account.due_day is not None
        existing = await self.repository.cycle_by_statement(
            account.id, request.target_statement_date
        )
        amount = sum(item.amount_due_minor for item in remaining)
        proposed_periods: list[InstallmentPeriodPreview] = []
        remaining_ids = {item.id for item in remaining}
        for item in current.periods:
            preview = self._period_preview_from_response(item)
            if item.id in remaining_ids:
                preview = preview.model_copy(
                    update={
                        "effective_cycle_id": existing.id if existing else None,
                        "effective_statement_date": request.target_statement_date,
                        "due_date": self._due_date(
                            request.target_statement_date,
                            account.statement_day,
                            account.due_day,
                        ),
                        "status": InstallmentPeriodStatus.SETTLED_EARLY,
                    }
                )
            proposed_periods.append(preview)
        proposed = self._plan_preview_copy(
            current,
            proposed_periods,
            status=InstallmentPlanStatus.SETTLED_EARLY,
            future_gross=0,
            next_period=None,
        )
        payment_before = payment.opening_balance_minor + await self.repository.account_impact(
            payment.id
        )
        debt_before = account.opening_balance_minor - await self.repository.account_impact(
            account.id
        )
        return InstallmentSettlementPreview(
            amount_minor=amount,
            current_plan=current,
            proposed_plan=proposed,
            affected_cycles=self._affected_cycles(current.periods, proposed_periods),
            payment_balance_before_minor=payment_before,
            payment_balance_after_minor=checked_int64(payment_before - amount),
            debt_before_minor=debt_before,
            debt_after_minor=checked_int64(debt_before - amount),
            warnings=[],
        )

    async def reverse_settlement_preview(
        self, plan_id: UUID, request: InstallmentActionRequest
    ) -> InstallmentReverseSettlementPreview:
        plan = await self.repository.plan(plan_id)
        if plan is None:
            not_found("installment_plan_not_found", "The installment plan does not exist")
        if plan.version != request.expected_version:
            conflict("version_conflict", "The installment plan version changed")
        settlement = await self.repository.latest_settlement(plan.id)
        if settlement is None or await self.repository.has_later_operation(
            plan.id, settlement.created_at
        ):
            conflict("installment_settlement_in_use", "Settlement cannot be reversed")
        link = await self.repository.link_for_operation(settlement.id, "settlement_repayment")
        repayment = await self.repository.transaction(link.transaction_id) if link else None
        if repayment is None or repayment.voided_at is not None:
            conflict("installment_settlement_in_use", "Settlement repayment is unavailable")
        if repayment.credit_cycle_id is None or await self.repository.cycle_has_later_repayment(
            repayment.credit_cycle_id,
            occurred_after=ensure_utc(repayment.occurred_at),
            created_after=ensure_utc(repayment.created_at),
            excluding_transaction_id=repayment.id,
        ):
            conflict(
                "installment_settlement_in_use",
                "A later repayment depends on the settlement target cycle",
            )
        restored = [
            self._period_preview_from_response(item).model_copy(
                update={
                    "effective_cycle_id": item.scheduled_cycle_id,
                    "effective_statement_date": item.scheduled_statement_date,
                    "due_date": next(
                        period.due_date
                        for period in (await self.response(plan)).periods
                        if period.id == item.id
                    ),
                    "status": InstallmentPeriodStatus.SCHEDULED,
                }
            )
            for item in (await self.response(plan)).periods
            if item.settled_early_at is not None
        ]
        payment = await self.session.get(Account, settlement.payment_account_id)
        account = await self.session.get(Account, plan.credit_account_id)
        if payment is None or account is None:
            raise RuntimeError("settlement accounts missing")
        amount = abs(repayment.postings[0].amount_minor)
        payment_before = payment.opening_balance_minor + await self.repository.account_impact(
            payment.id
        )
        debt_before = account.opening_balance_minor - await self.repository.account_impact(
            account.id
        )
        return InstallmentReverseSettlementPreview(
            eligible=True,
            repayment_transaction=await self.transaction_service.response_with_relation(
                repayment, list(repayment.postings)
            ),
            restored_periods=restored,
            affected_cycles=[],
            payment_balance_before_minor=payment_before,
            payment_balance_after_minor=checked_int64(payment_before + amount),
            debt_before_minor=debt_before,
            debt_after_minor=checked_int64(debt_before + amount),
            warnings=[],
        )

    async def cancellation_preview(
        self, plan_id: UUID, request: InstallmentActionRequest
    ) -> InstallmentCancellationPreview:
        plan = await self.repository.plan(plan_id)
        if plan is None:
            not_found("installment_plan_not_found", "The installment plan does not exist")
        if plan.version != request.expected_version:
            conflict("version_conflict", "The installment plan version changed")
        current = await self.response(plan)
        candidates = [
            item
            for item in current.periods
            if item.cancelled_at is None and item.settled_early_at is None and not item.locked
        ]
        if not candidates:
            conflict("installment_already_cancelled", "There are no cancellable periods")
        candidate_ids = {item.id for item in candidates}
        proposed_periods = [
            self._period_preview_from_response(item)
            for item in current.periods
            if item.id not in candidate_ids
        ]
        status = (
            InstallmentPlanStatus.CANCELLED
            if not proposed_periods
            else InstallmentPlanStatus.PARTIALLY_CANCELLED
        )
        future = [
            item
            for item in proposed_periods
            if not item.locked and item.effective_statement_date >= self._today()
        ]
        proposed = self._plan_preview_copy(
            current,
            proposed_periods,
            status=status,
            future_gross=sum(item.amount_due_minor for item in future),
            next_period=future[0] if future else None,
        )
        principal = sum(item.principal_minor for item in candidates)
        fee = sum(item.fee_minor for item in candidates)
        account = await self.session.get(Account, plan.credit_account_id)
        if account is None:
            raise RuntimeError("installment account missing")
        debt_before = account.opening_balance_minor - await self.repository.account_impact(
            account.id
        )
        refund = checked_int64(principal + fee)
        return InstallmentCancellationPreview(
            principal_refund_minor=principal,
            fee_refund_minor=fee,
            cancelled_periods=[self._period_preview_from_response(item) for item in candidates],
            current_plan=current,
            proposed_plan=proposed,
            affected_cycles=self._affected_cycles(current.periods, proposed_periods),
            debt_before_minor=debt_before,
            debt_after_minor=checked_int64(debt_before - refund),
            expense_before_minor=current.total_financed_minor,
            expense_after_minor=checked_int64(current.total_financed_minor - refund),
            warnings=[],
        )

    async def cancel_future(
        self, plan_id: UUID, request: InstallmentActionRequest, key: UUID
    ) -> InstallmentCancellationResult:
        await acquire_mutation_lock(self.session)
        request_hash = self._hash_model(request)
        replay = await self.repository.operation_for_key(key)
        if replay is not None:
            if (
                replay.plan_id != plan_id
                or replay.request_hash != request_hash
                or replay.kind != "cancel_future"
            ):
                conflict("installment_operation_conflict", "Operation key has different input")
            if replay.result_snapshot is None:
                raise RuntimeError("completed installment operation has no snapshot")
            result = InstallmentCancellationResult.model_validate(replay.result_snapshot)
            return result.model_copy(update={"replayed": True})
        plan = await self._required_plan(plan_id, request.expected_version)
        current = await self.response(plan)
        candidates = [
            (period, response)
            for period, response in zip(plan.periods, current.periods, strict=True)
            if response.cancelled_at is None
            and response.settled_early_at is None
            and not response.locked
        ]
        if not candidates:
            conflict("installment_already_cancelled", "There are no cancellable future periods")
        occurred = ensure_utc(request.occurred_at)
        operation = InstallmentOperation(
            plan_id=plan.id,
            kind="cancel_future",
            idempotency_key=key,
            request_hash=request_hash,
            occurred_at=occurred,
        )
        self.session.add(operation)
        await self.session.flush()
        purchase = await self.repository.transaction(plan.purchase_transaction_id)
        if purchase is None or purchase.category_id is None:
            raise RuntimeError("installment purchase is incomplete")
        principal = sum(period.principal_minor for period, _response in candidates)
        fee = sum(period.fee_minor for period, _response in candidates)
        from fiscal_api.services.reimbursements import ensure_reimbursement_capacity

        purchase_capacity = abs(next(item.amount_minor for item in purchase.postings))
        already_refunded = purchase_capacity - sum(
            item.principal_minor for item in plan.periods if item.cancelled_at is None
        )
        await ensure_reimbursement_capacity(
            self.session,
            purchase.id,
            purchase_capacity - already_refunded - principal,
        )
        refunds: list[LedgerTransaction] = []
        for amount, category_id, role, label in (
            (principal, purchase.category_id, "principal_refund", "本金退款"),
            (fee, plan.fee_category_id, "fee_refund", "手续费退款"),
        ):
            if not amount:
                continue
            assert category_id is not None
            refund = self._system_transaction(
                kind=TransactionKind.INSTALLMENT_REFUND,
                amount=amount,
                occurred=occurred,
                title=f"{purchase.title} · {label}",
                category_id=category_id,
                account_id=plan.credit_account_id,
                destination_account_id=None,
                cycle_id=None,
                request_hash=request_hash,
            )
            self.session.add(refund)
            await self.session.execute(
                update(Account)
                .where(Account.id == plan.credit_account_id)
                .values(usage_count=Account.usage_count + 1)
            )
            await self.session.execute(
                update(Category)
                .where(Category.id == category_id)
                .values(usage_count=Category.usage_count + 1)
            )
            await self.session.flush()
            self.session.add(
                InstallmentLedgerLink(
                    transaction_id=refund.id,
                    plan_id=plan.id,
                    operation_id=operation.id,
                    role=role,
                )
            )
            refunds.append(refund)
        now = utc_now()
        for period, _response in candidates:
            period.cancelled_at = now
            period.version += 1
            period.updated_at = now
        plan.lifecycle = (
            "cancelled"
            if len(candidates)
            == len([item for item in current.periods if item.cancelled_at is None])
            else "partially_cancelled"
        )
        plan.version += 1
        plan.updated_at = now
        await self.session.flush()
        await validate_credit_invariants(
            self.credit_repository, {plan.credit_account_id}, repayment_error=False
        )
        plan_response = await self.response(plan)
        refund_responses = [
            await self.transaction_service.response_with_relation(item, list(item.postings))
            for item in refunds
        ]
        result = InstallmentCancellationResult(
            operation_id=operation.id,
            plan=plan_response,
            refund_transactions=refund_responses,
            replayed=False,
        )
        operation.completed_at = now
        operation.result_snapshot = result.model_dump(mode="json")
        for transaction, response in zip(refunds, refund_responses, strict=True):
            self.transaction_repository.add_revision(
                TransactionRevision(
                    transaction_id=transaction.id,
                    version=1,
                    event=RevisionEvent.CREATED.value,
                    snapshot=response.model_dump(mode="json"),
                )
            )
        self.repository.add_revision(
            InstallmentPlanRevision(
                plan_id=plan.id,
                version=plan.version,
                event="cancelled_future",
                snapshot=plan_response.model_dump(mode="json"),
            )
        )
        await self.session.commit()
        return result

    async def reverse_settlement(
        self, plan_id: UUID, request: InstallmentActionRequest, key: UUID
    ) -> InstallmentReverseSettlementResult:
        await acquire_mutation_lock(self.session)
        request_hash = self._hash_model(request)
        replay = await self.repository.operation_for_key(key)
        if replay is not None:
            if (
                replay.plan_id != plan_id
                or replay.request_hash != request_hash
                or replay.kind != "reverse_settlement"
            ):
                conflict("installment_operation_conflict", "Operation key has different input")
            if replay.result_snapshot is None:
                raise RuntimeError("completed installment operation has no snapshot")
            result = InstallmentReverseSettlementResult.model_validate(replay.result_snapshot)
            return result.model_copy(update={"replayed": True})
        plan = await self._required_plan(plan_id, request.expected_version)
        settlement = await self.repository.latest_settlement(plan.id)
        if settlement is None:
            conflict("installment_settlement_in_use", "There is no reversible settlement")
        if await self.repository.has_later_operation(plan.id, settlement.created_at):
            conflict(
                "installment_settlement_in_use", "A later plan operation depends on settlement"
            )
        link = await self.repository.link_for_operation(settlement.id, "settlement_repayment")
        if link is None:
            raise RuntimeError("settlement repayment link missing")
        repayment = await self.repository.transaction(link.transaction_id)
        if repayment is None or repayment.voided_at is not None:
            conflict("installment_settlement_in_use", "Settlement repayment is unavailable")
        if repayment.credit_cycle_id is None or await self.repository.cycle_has_later_repayment(
            repayment.credit_cycle_id,
            occurred_after=ensure_utc(repayment.occurred_at),
            created_after=ensure_utc(repayment.created_at),
            excluding_transaction_id=repayment.id,
        ):
            conflict(
                "installment_settlement_in_use",
                "A later repayment depends on the settlement target cycle",
            )
        operation = InstallmentOperation(
            plan_id=plan.id,
            kind="reverse_settlement",
            idempotency_key=key,
            request_hash=request_hash,
            target_statement_date=settlement.target_statement_date,
            payment_account_id=settlement.payment_account_id,
            occurred_at=ensure_utc(request.occurred_at),
        )
        self.session.add(operation)
        await self.session.flush()
        now = utc_now()
        repayment.voided_at = now
        repayment.version += 1
        repayment.updated_at = now
        settlement.reversed_at = now
        for period in plan.periods:
            if period.settled_early_at is not None:
                period.effective_cycle_id = period.scheduled_cycle_id
                period.settled_early_at = None
                period.version += 1
                period.updated_at = now
        plan.lifecycle = (
            "partially_cancelled"
            if any(item.cancelled_at is not None for item in plan.periods)
            else "active"
        )
        plan.version += 1
        plan.updated_at = now
        await self.session.flush()
        await validate_credit_invariants(
            self.credit_repository, {plan.credit_account_id}, repayment_error=False
        )
        account = await self.session.get(Account, plan.credit_account_id)
        if account is None:
            raise RuntimeError("installment account missing")
        debt = account.opening_balance_minor - await self.repository.account_impact(account.id)
        if account.credit_limit_minor is not None and debt > account.credit_limit_minor:
            conflict("installment_settlement_in_use", "Reversal would exceed the credit limit")
        plan_response = await self.response(plan)
        repayment_response = await self.transaction_service.response_with_relation(
            repayment, list(repayment.postings)
        )
        result = InstallmentReverseSettlementResult(
            operation_id=operation.id,
            plan=plan_response,
            voided_repayment_transaction=repayment_response,
            replayed=False,
        )
        operation.completed_at = now
        operation.result_snapshot = result.model_dump(mode="json")
        self.repository.add_revision(
            InstallmentPlanRevision(
                plan_id=plan.id,
                version=plan.version,
                event="reversed_settlement",
                snapshot=plan_response.model_dump(mode="json"),
            )
        )
        self.transaction_repository.add_revision(
            TransactionRevision(
                transaction_id=repayment.id,
                version=repayment.version,
                event=RevisionEvent.VOIDED.value,
                snapshot=repayment_response.model_dump(mode="json"),
            )
        )
        await self.session.commit()
        return result

    async def _eligible_purchase(
        self,
        transaction: LedgerTransaction,
    ) -> tuple[Account, int, CreditCycle]:
        if (
            transaction.kind != TransactionKind.CREDIT_PURCHASE.value
            or transaction.source
            not in {TransactionSource.MANUAL.value, TransactionSource.AI_TEXT.value}
            or transaction.voided_at is not None
            or len(transaction.postings) != 1
        ):
            invalid("purchase_not_eligible", "Only an active user credit purchase is eligible")
        if await self.repository.plan_for_purchase(transaction.id) is not None:
            invalid("purchase_not_eligible", "The purchase already has an installment plan")
        posting = transaction.postings[0]
        account = await self.session.get(Account, posting.account_id)
        cycle = (
            await self.credit_repository.cycle(transaction.credit_cycle_id)
            if transaction.credit_cycle_id
            else None
        )
        if account is None or account.kind != AccountKind.CREDIT.value or account.archived_at:
            invalid("purchase_not_eligible", "The credit account is not active")
        if cycle is None or cycle.is_opening_cycle or cycle.statement_date < self._today():
            invalid("purchase_not_eligible", "The purchase cycle is no longer open")
        if await self.repository.cycle_has_repayment(cycle.id):
            invalid("purchase_not_eligible", "The purchase cycle already has a repayment")
        return account, abs(posting.amount_minor), cycle

    async def _planned_purchase_context(
        self, transaction: LedgerTransaction, plan: InstallmentPlan
    ) -> tuple[Account, CreditCycle]:
        if (
            transaction.kind != TransactionKind.CREDIT_PURCHASE.value
            or transaction.source
            not in {TransactionSource.MANUAL.value, TransactionSource.AI_TEXT.value}
            or transaction.voided_at is not None
            or len(transaction.postings) != 1
            or transaction.credit_cycle_id is None
        ):
            invalid("purchase_not_eligible", "The linked purchase is not canonical")
        posting = transaction.postings[0]
        account = await self.session.get(Account, posting.account_id)
        cycle = await self.credit_repository.cycle(transaction.credit_cycle_id)
        if (
            account is None
            or account.kind != AccountKind.CREDIT.value
            or plan.purchase_transaction_id != transaction.id
            or plan.credit_account_id != account.id
            or cycle is None
            or cycle.is_opening_cycle
            or cycle.account_id != account.id
        ):
            conflict(
                "installment_cycle_account_mismatch",
                "The installment plan does not belong to the purchase account",
            )
        return account, cycle

    async def _materialize_cycles(
        self, account: Account, start: date, count: int
    ) -> list[CreditCycle]:
        assert account.statement_day is not None
        if start.day != account.statement_day:
            invalid("invalid_installment_schedule", "Start date must be a statement date")
        result: list[CreditCycle] = []
        for offset in range(count):
            statement = _shift_statement_month(start, offset, account.statement_day)
            result.append(
                await ensure_cycle_for_statement(self.credit_repository, account, statement)
            )
        return result

    async def _validated_settlement_inputs(
        self, plan: InstallmentPlan, request: InstallmentSettlementRequest
    ) -> tuple[Account, Account]:
        account = await self.session.get(Account, plan.credit_account_id)
        payment = await self.session.get(Account, request.payment_account_id)
        if account is None or payment is None:
            not_found("account_not_found", "The selected account does not exist")
        if (
            payment.kind not in {AccountKind.CASH.value, AccountKind.DEBIT.value}
            or payment.archived_at is not None
        ):
            invalid("invalid_installment_schedule", "Payment account must be active cash or debit")
        if account.statement_day is None or account.due_day is None:
            raise RuntimeError("installment credit schedule missing")
        if request.target_statement_date < self._today():
            invalid("invalid_installment_schedule", "Settlement cycle must be open")
        if request.target_statement_date.day != account.statement_day:
            invalid("invalid_installment_schedule", "Target date must be a statement date")
        existing = await self.repository.cycle_by_statement(
            account.id, request.target_statement_date
        )
        if existing is not None and (
            existing.account_id != account.id or existing.is_opening_cycle
        ):
            conflict(
                "installment_cycle_account_mismatch",
                "Settlement cycle belongs to another account",
            )
        return account, payment

    async def response(self, plan: InstallmentPlan) -> InstallmentPlanResponse:
        purchase = await self.repository.transaction(plan.purchase_transaction_id)
        if purchase is None:
            raise RuntimeError("installment purchase missing")
        fee = (
            await self.repository.transaction(plan.fee_transaction_id)
            if plan.fee_transaction_id
            else None
        )
        cycles = {
            period.effective_cycle_id: await self.credit_repository.cycle(period.effective_cycle_id)
            for period in plan.periods
        }
        amounts = await self.credit_repository.amounts(list(cycles))
        periods: list[InstallmentPeriodResponse] = []
        locked_count = cycle_settled = 0
        for period in plan.periods:
            cycle = cycles[period.effective_cycle_id]
            scheduled = await self.credit_repository.cycle(period.scheduled_cycle_id)
            if cycle is None or scheduled is None:
                raise RuntimeError("installment cycle missing")
            purchase_minor, repaid = amounts.get(cycle.id, (0, 0))
            opening = 0
            remaining = purchase_minor + opening - repaid
            status = self._cycle_status(cycle, remaining, repaid)
            locked = (
                cycle.statement_date < self._today()
                or await self.repository.cycle_has_repayment(cycle.id)
            )
            locked_count += int(locked)
            cycle_settled += int(status is CreditCycleStatus.SETTLED)
            period_status = self._period_status(period, cycle, status)
            periods.append(
                InstallmentPeriodResponse(
                    id=period.id,
                    plan_id=plan.id,
                    sequence=period.sequence,
                    scheduled_cycle_id=period.scheduled_cycle_id,
                    effective_cycle_id=period.effective_cycle_id,
                    scheduled_statement_date=scheduled.statement_date,
                    effective_statement_date=cycle.statement_date,
                    due_date=cycle.due_date,
                    principal_minor=period.principal_minor,
                    fee_minor=period.fee_minor,
                    amount_due_minor=checked_int64(period.principal_minor + period.fee_minor),
                    locked=locked,
                    status=period_status,
                    cycle_status=status,
                    cancelled_at=period.cancelled_at,
                    settled_early_at=period.settled_early_at,
                    version=period.version,
                    created_at=period.created_at,
                    updated_at=period.updated_at,
                )
            )
        active = [item for item in periods if item.cancelled_at is None]
        future = [
            item
            for item in active
            if item.settled_early_at is None
            and item.cycle_status is not CreditCycleStatus.SETTLED
            and item.effective_statement_date >= self._today()
        ]
        lifecycle_status = InstallmentPlanStatus(plan.lifecycle)
        status = (
            lifecycle_status
            if lifecycle_status
            in {InstallmentPlanStatus.CANCELLED, InstallmentPlanStatus.SETTLED_EARLY}
            else InstallmentPlanStatus.COMPLETED
            if active and all(item.cycle_status is CreditCycleStatus.SETTLED for item in active)
            else lifecycle_status
        )
        principal = sum(item.principal_minor for item in active)
        fee_minor = sum(item.fee_minor for item in active)
        return InstallmentPlanResponse(
            id=plan.id,
            purchase_transaction_id=plan.purchase_transaction_id,
            credit_account_id=plan.credit_account_id,
            fee_transaction_id=plan.fee_transaction_id,
            fee_category_id=plan.fee_category_id,
            fee_occurred_at=ensure_utc(fee.occurred_at) if fee else None,
            title=purchase.title,
            status=status,
            principal_minor=principal,
            fee_minor=fee_minor,
            total_financed_minor=checked_int64(principal + fee_minor),
            installment_count=plan.installment_count,
            start_statement_date=(
                await self.credit_repository.cycle(plan.start_cycle_id)
            ).statement_date,  # type: ignore[union-attr]
            locked_count=locked_count,
            future_count=len(future),
            cancelled_count=sum(item.cancelled_at is not None for item in periods),
            cycle_settled_count=cycle_settled,
            scheduled_gross_minor=sum(item.amount_due_minor for item in active),
            future_scheduled_gross_minor=sum(item.amount_due_minor for item in future),
            next_period=min(future, key=lambda item: (item.effective_statement_date, item.sequence))
            if future
            else None,
            periods=periods,
            version=plan.version,
            created_at=plan.created_at,
            updated_at=plan.updated_at,
        )

    def teaser(self, plan: InstallmentPlanResponse) -> InstallmentTeaser:
        return InstallmentTeaser(
            plan_id=plan.id,
            title=plan.title,
            status=plan.status,
            installment_count=plan.installment_count,
            future_count=plan.future_count,
            future_scheduled_gross_minor=plan.future_scheduled_gross_minor,
            next_period=plan.next_period,
        )

    @staticmethod
    def _period_preview_from_response(
        period: InstallmentPeriodResponse,
    ) -> InstallmentPeriodPreview:
        return InstallmentPeriodPreview(
            sequence=period.sequence,
            scheduled_cycle_id=period.scheduled_cycle_id,
            effective_cycle_id=period.effective_cycle_id,
            scheduled_statement_date=period.scheduled_statement_date,
            effective_statement_date=period.effective_statement_date,
            due_date=period.due_date,
            principal_minor=period.principal_minor,
            fee_minor=period.fee_minor,
            amount_due_minor=period.amount_due_minor,
            locked=period.locked,
            status=period.status,
        )

    @staticmethod
    def _affected_cycles(
        before: list[InstallmentPeriodResponse],
        after: list[InstallmentPeriodPreview],
    ) -> list[InstallmentAffectedCycle]:
        totals: dict[date, list[int | UUID | None]] = {}
        for period in before:
            if period.cancelled_at is None:
                row = totals.setdefault(
                    period.effective_statement_date,
                    [period.effective_cycle_id, 0, 0],
                )
                row[1] = int(row[1] or 0) + period.amount_due_minor
        for period in after:
            row = totals.setdefault(
                period.effective_statement_date,
                [period.effective_cycle_id, 0, 0],
            )
            if row[0] is None:
                row[0] = period.effective_cycle_id
            row[2] = int(row[2] or 0) + period.amount_due_minor
        return [
            InstallmentAffectedCycle(
                statement_date=statement,
                cycle_id=row[0] if isinstance(row[0], UUID) else None,
                before_due_minor=int(row[1] or 0),
                after_due_minor=int(row[2] or 0),
                delta_minor=int(row[2] or 0) - int(row[1] or 0),
            )
            for statement, row in sorted(totals.items())
            if row[1] != row[2]
        ]

    @staticmethod
    def _plan_preview_copy(
        current: InstallmentPlanResponse,
        periods: list[InstallmentPeriodPreview],
        *,
        status: InstallmentPlanStatus,
        future_gross: int,
        next_period: InstallmentPeriodPreview | None,
    ) -> InstallmentPlanPreview:
        active = periods
        return InstallmentPlanPreview(
            id=current.id,
            purchase_transaction_id=current.purchase_transaction_id,
            credit_account_id=current.credit_account_id,
            fee_transaction_id=current.fee_transaction_id,
            fee_category_id=current.fee_category_id,
            fee_occurred_at=current.fee_occurred_at,
            title=current.title,
            status=status,
            principal_minor=sum(item.principal_minor for item in active),
            fee_minor=sum(item.fee_minor for item in active),
            total_financed_minor=sum(item.amount_due_minor for item in active),
            installment_count=current.installment_count,
            start_statement_date=current.start_statement_date,
            locked_count=sum(item.locked for item in active),
            future_count=sum(
                not item.locked and item.status is not InstallmentPeriodStatus.SETTLED_EARLY
                for item in active
            ),
            cancelled_count=current.installment_count - len(active),
            cycle_settled_count=sum(
                item.status is InstallmentPeriodStatus.CYCLE_SETTLED for item in active
            ),
            scheduled_gross_minor=sum(item.amount_due_minor for item in active),
            future_scheduled_gross_minor=future_gross,
            next_period=next_period,
            periods=periods,
        )

    def _cycle_status(self, cycle: CreditCycle, remaining: int, repaid: int) -> CreditCycleStatus:
        if remaining == 0:
            return CreditCycleStatus.SETTLED
        if cycle.due_date < self._today():
            return CreditCycleStatus.OVERDUE
        if cycle.statement_date >= self._today():
            return CreditCycleStatus.OPEN
        return CreditCycleStatus.PARTIAL if repaid else CreditCycleStatus.UNPAID

    def _period_status(
        self, period: InstallmentPeriod, cycle: CreditCycle, status: CreditCycleStatus
    ) -> InstallmentPeriodStatus:
        if period.cancelled_at:
            return InstallmentPeriodStatus.CANCELLED
        if period.settled_early_at:
            return InstallmentPeriodStatus.SETTLED_EARLY
        mapping = {
            CreditCycleStatus.OPEN: InstallmentPeriodStatus.SCHEDULED,
            CreditCycleStatus.SETTLED: InstallmentPeriodStatus.CYCLE_SETTLED,
            CreditCycleStatus.PARTIAL: InstallmentPeriodStatus.PARTIAL,
            CreditCycleStatus.OVERDUE: InstallmentPeriodStatus.OVERDUE,
            CreditCycleStatus.UNPAID: InstallmentPeriodStatus.BILLED,
        }
        return mapping[status]

    @staticmethod
    def allocate(total: int, count: int) -> list[int]:
        quotient, remainder = divmod(total, count)
        return [quotient + int(index < remainder) for index in range(count)]

    @staticmethod
    def _due_date(statement: date, statement_day: int, due_day: int) -> date:
        if due_day > statement_day:
            return date(statement.year, statement.month, due_day)
        shifted = _shift_statement_month(statement, 1, due_day)
        return date(
            shifted.year, shifted.month, min(due_day, monthrange(shifted.year, shifted.month)[1])
        )

    @staticmethod
    def _hash(request: InstallmentCreate) -> str:
        canonical = json.dumps(
            request.model_dump(mode="json"), sort_keys=True, separators=(",", ":")
        )
        return hashlib.sha256(canonical.encode()).hexdigest()

    @staticmethod
    def _hash_model(request: BaseModel) -> str:
        canonical = json.dumps(
            request.model_dump(mode="json"), sort_keys=True, separators=(",", ":")
        )
        return hashlib.sha256(canonical.encode()).hexdigest()

    @staticmethod
    def _encode_cursor(plan: InstallmentPlan) -> str:
        payload = json.dumps(
            {"created_at": ensure_utc(plan.created_at).isoformat(), "id": str(plan.id)},
            separators=(",", ":"),
        )
        return base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")

    @staticmethod
    def _decode_cursor(cursor: str | None) -> tuple[datetime | None, UUID | None]:
        if cursor is None:
            return None, None
        try:
            padded = cursor + "=" * (-len(cursor) % 4)
            payload = json.loads(base64.urlsafe_b64decode(padded).decode())
            return ensure_utc(datetime.fromisoformat(payload["created_at"])), UUID(payload["id"])
        except (ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
            invalid("invalid_installment_schedule", "The cursor is invalid")
            raise AssertionError from error

    async def _required_plan(self, plan_id: UUID, expected_version: int) -> InstallmentPlan:
        plan = await self.repository.plan(plan_id, for_update=True)
        if plan is None:
            not_found("installment_plan_not_found", "The installment plan does not exist")
        if plan.version != expected_version:
            conflict("version_conflict", "The installment plan version changed")
        return plan

    @staticmethod
    def _system_transaction(
        *,
        kind: TransactionKind,
        amount: int,
        occurred: datetime,
        title: str,
        category_id: UUID | None,
        account_id: UUID,
        destination_account_id: UUID | None,
        cycle_id: UUID | None,
        request_hash: str,
    ) -> LedgerTransaction:
        transaction = LedgerTransaction(
            kind=kind.value,
            occurred_at=occurred,
            title=title,
            note=None,
            category_id=category_id,
            credit_cycle_id=cycle_id,
            source="system",
            idempotency_key=uuid4(),
            request_hash=request_hash,
        )
        if kind is TransactionKind.REPAYMENT:
            assert destination_account_id is not None
            transaction.postings.extend(
                [
                    Posting(
                        account_id=account_id,
                        role=PostingRole.SOURCE.value,
                        amount_minor=-amount,
                        position=0,
                    ),
                    Posting(
                        account_id=destination_account_id,
                        role=PostingRole.DESTINATION.value,
                        amount_minor=amount,
                        position=1,
                    ),
                ]
            )
        else:
            transaction.postings.append(
                Posting(
                    account_id=account_id,
                    role=PostingRole.ACCOUNT.value,
                    amount_minor=amount,
                    position=0,
                )
            )
        return transaction

    def _record_operation_revisions(
        self,
        plan: InstallmentPlan,
        event: str,
        plan_response: InstallmentPlanResponse,
        transaction: LedgerTransaction,
        response: TransactionResponse,
    ) -> None:
        self.repository.add_revision(
            InstallmentPlanRevision(
                plan_id=plan.id,
                version=plan.version,
                event=event,
                snapshot=plan_response.model_dump(mode="json"),
            )
        )
        self.transaction_repository.add_revision(
            TransactionRevision(
                transaction_id=transaction.id,
                version=transaction.version,
                event=RevisionEvent.CREATED.value,
                snapshot=response.model_dump(mode="json"),
            )
        )

    @staticmethod
    def _transaction_response(transaction: LedgerTransaction) -> TransactionResponse:
        postings = sorted(transaction.postings, key=lambda item: item.position)
        posting = postings[0]
        destination = next(
            (item for item in postings if item.role == PostingRole.DESTINATION.value), None
        )
        return TransactionResponse(
            id=transaction.id,
            kind=TransactionKind(transaction.kind),
            amount_minor=abs(posting.amount_minor),
            occurred_at=ensure_utc(transaction.occurred_at),
            business_date=transaction.occurred_at.astimezone(BUSINESS_TIMEZONE).date(),
            title=transaction.title,
            note=transaction.note,
            category_id=transaction.category_id,
            account_id=posting.account_id,
            destination_account_id=destination.account_id if destination else None,
            credit_cycle_id=transaction.credit_cycle_id,
            source=transaction.source,
            postings=[
                PostingResponse(
                    id=item.id,
                    account_id=item.account_id,
                    role=PostingRole(item.role),
                    amount_minor=item.amount_minor,
                    position=item.position,
                )
                for item in postings
            ],
            version=transaction.version,
            voided_at=transaction.voided_at,
            created_at=transaction.created_at,
            updated_at=transaction.updated_at,
        )
