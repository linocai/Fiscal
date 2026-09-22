"""Operator-only recovery of a confirmed existing interest-free loan.

No inferred principal or synthetic purchase/cash receipt. Caller owns commit/rollback.
"""

import hashlib
from datetime import date, datetime
from uuid import UUID, uuid5

from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p5_schemas import InstallmentCreate
from fiscal_api.core.time import BUSINESS_TIMEZONE, utc_now
from fiscal_api.db.models import (
    Account,
    LedgerTransaction,
    Posting,
    TransactionKind,
    TransactionRevision,
)
from fiscal_api.db.models.cash_flow import CashFlowItem
from fiscal_api.repositories.transactions import TransactionRepository
from fiscal_api.services.cash_flow import CashFlowService
from fiscal_api.services.common import acquire_mutation_lock, check_version, conflict, invalid
from fiscal_api.services.credit import CreditService, validate_credit_invariants
from fiscal_api.services.installments import InstallmentService
from fiscal_api.services.transactions import TransactionService


class LoanRecoveryRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    account_id: UUID
    account_expected_version: int = Field(ge=1)
    payment_account_id: UUID
    confirmed_at: datetime
    first_statement_date: date
    installment_count: int = Field(ge=2, le=60)
    monthly_principal_minor: int = Field(gt=0, strict=True)
    confirmed_principal_before_payment_minor: int = Field(gt=0, strict=True)
    title: str = Field(min_length=1, max_length=80)
    superseded_plan_versions: dict[UUID, int]


async def recover_loan(
    session: AsyncSession, request: LoanRecoveryRequest, key: UUID
) -> dict[str, object]:
    await acquire_mutation_lock(session)
    if request.confirmed_at.tzinfo is None or request.confirmed_at > utc_now():
        invalid("invalid_loan_confirmation", "Confirmation must be timezone aware and not future")
    total = request.monthly_principal_minor * request.installment_count
    if total != request.confirmed_principal_before_payment_minor or total > 9_000_000_000_000:
        invalid("invalid_loan_confirmation", "Confirmed principal must exactly match the schedule")
    digest = hashlib.sha256(request.model_dump_json().encode()).hexdigest()
    tx_id = uuid5(key, "principal")
    existing = await session.get(LedgerTransaction, tx_id)
    if existing:
        if existing.request_hash != digest:
            conflict("idempotency_key_reused", "Recovery input changed")
        repayment = await TransactionRepository(session).get_by_idempotency_key(
            uuid5(key, "repayment-key")
        )
        plan = await InstallmentService(session).repository.plan_for_purchase(tx_id)
        if repayment is None or plan is None:
            conflict("loan_recovery_incomplete", "Recovery evidence is incomplete")
        return {
            "principal_transaction_id": str(tx_id),
            "plan_id": str(plan.id),
            "repayment_id": str(repayment.id),
            "replayed": True,
        }
    account = await session.get(Account, request.account_id, with_for_update=True)
    payment = await session.get(Account, request.payment_account_id, with_for_update=True)
    if (
        account is None
        or account.kind != "credit"
        or account.archived_at
        or account.cycle_mode == "on_demand"
    ):
        invalid("invalid_loan_account", "An active scheduled credit account is required")
    check_version(account.version, request.account_expected_version)
    if payment is None or payment.kind not in {"debit", "cash"} or payment.archived_at:
        invalid("invalid_loan_payment_account", "An active cash/debit payment account is required")
    summary = await CreditService(session).get_account(account.id)
    if summary.current_debt_minor != 0 or summary.active_installment_count:
        conflict("loan_recovery_nonzero_debt", "Only a verified zero-debt account can be recovered")
    service = InstallmentService(session)
    cycles = await service._materialize_cycles(  # pyright: ignore[reportPrivateUsage]
        account, request.first_statement_date, request.installment_count
    )
    day = request.confirmed_at.astimezone(BUSINESS_TIMEZONE).date()
    if cycles[0].due_date != day or len(request.superseded_plan_versions) != len(cycles):
        invalid(
            "invalid_loan_schedule",
            "Recovery must replace every confirmed monthly plan starting today",
        )
    items = list(
        (
            await session.scalars(
                select(CashFlowItem)
                .where(CashFlowItem.id.in_(request.superseded_plan_versions))
                .with_for_update()
            )
        ).all()
    )
    by_date = {i.expected_date: i for i in items}
    if len(by_date) != len(cycles):
        conflict("loan_plan_mismatch", "Plan dates must be unique and complete")
    for cycle in cycles:
        item = by_date.get(cycle.due_date)
        if (
            item is None
            or item.title != request.title
            or item.direction != "outflow"
            or item.status not in {"expected", "confirmed"}
            or item.linked_transaction_id is not None
            or item.planned_amount_minor != request.monthly_principal_minor
        ):
            conflict("loan_plan_mismatch", "A pending monthly plan differs from the confirmed loan")
        check_version(item.version, request.superseded_plan_versions[item.id])
        if await CashFlowService(session).repository.settlement_links(item.id):
            conflict("loan_plan_already_paid", "Do not replace a plan with any settlement history")
    transaction = LedgerTransaction(
        id=tx_id,
        kind="loan_principal",
        source="system",
        occurred_at=request.confirmed_at,
        title=request.title + " · 本金确认",
        note="确认既有免息贷款剩余本金, 不计为新增消费或现金流入。",
        credit_cycle_id=cycles[0].id,
        idempotency_key=uuid5(key, "principal-key"),
        request_hash=digest,
    )
    transaction.postings.append(
        Posting(account_id=account.id, role="account", amount_minor=-total, position=0)
    )
    session.add(transaction)
    account.usage_count += 1
    await session.flush()
    plan = await service.create(
        InstallmentCreate(
            purchase_transaction_id=tx_id,
            installment_count=request.installment_count,
            total_fee_minor=0,
            start_statement_date=request.first_statement_date,
        ),
        uuid5(key, "plan"),
        commit=False,
    )
    response = await TransactionService(session).response_with_relation(
        transaction, list(transaction.postings)
    )
    session.add(
        TransactionRevision(
            transaction_id=tx_id,
            version=1,
            event="created",
            snapshot=response.model_dump(mode="json"),
        )
    )
    repayment = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.REPAYMENT,
            amount_minor=request.monthly_principal_minor,
            occurred_at=request.confirmed_at,
            title=request.title,
            account_id=payment.id,
            destination_account_id=account.id,
            credit_cycle_id=cycles[0].id,
        ),
        uuid5(key, "repayment-key"),
        commit=False,
    )
    # Stable receipt references are carried by the principal snapshot, not guessed on replay.
    for item in items:
        item.note = "已转入贷款账期, 替代分期计划: " + str(plan.id)
        CashFlowService(session)._cancel(item)  # pyright: ignore[reportPrivateUsage]
    await session.flush()
    await validate_credit_invariants(service.credit_repository, {account.id})
    after = await CreditService(session).get_account(account.id)
    assert after.current_debt_minor == total - request.monthly_principal_minor
    return {
        "principal_transaction_id": str(tx_id),
        "plan_id": str(plan.id),
        "repayment_id": str(repayment.id),
        "principal_before_minor": total,
        "principal_after_minor": after.current_debt_minor,
        "cancelled_plan_count": len(items),
        "replayed": False,
    }
