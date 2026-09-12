from __future__ import annotations

# Atomic domain command deliberately shares the ledger transaction primitives.
# pyright: reportPrivateUsage=false
import hashlib
import json
from datetime import timedelta
from typing import Any
from uuid import UUID, uuid4, uuid5

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from fiscal_api.api.p40_schemas import (
    CreditPayoffAllocation,
    CreditPayoffCommitRequest,
    CreditPayoffPreview,
    CreditPayoffReceipt,
    CreditPayoffRequest,
    CreditPayoffReversePreview,
    CreditPayoffReverseRequest,
)
from fiscal_api.core.time import BUSINESS_TIMEZONE, ensure_utc, utc_now
from fiscal_api.db.models import (
    Account,
    ActionPreviewSession,
    CreditPayoffLink,
    CreditPayoffOperation,
    DataRevision,
    InstallmentPlan,
    InstallmentPlanRevision,
    LedgerTransaction,
    Posting,
    RevisionEvent,
)
from fiscal_api.repositories.credit import CreditRepository
from fiscal_api.services.common import (
    acquire_mutation_lock,
    checked_int64,
    conflict,
    invalid,
    not_found,
)
from fiscal_api.services.credit import validate_credit_invariants
from fiscal_api.services.transactions import TransactionService


def digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, default=str, separators=(",", ":")).encode()
    ).hexdigest()


class CreditPayoffService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.credit = CreditRepository(session)
        self.transactions = TransactionService(session)

    async def _revision(self) -> int:
        value = await self.session.scalar(select(DataRevision.revision).where(DataRevision.id == 1))
        if value is None:
            raise RuntimeError("data revision is missing")
        return int(value)

    async def _accounts(self, account_id: UUID, payment_id: UUID) -> tuple[Account, Account]:
        credit = await self.session.get(Account, account_id)
        payment = await self.session.get(Account, payment_id)
        if credit is None or credit.kind != "credit":
            not_found("credit_account_not_found", "信用账户不存在")
        if payment is None or payment.kind not in {"cash", "debit"} or payment_id == account_id:
            invalid("invalid_payment_account", "请选择不同的现金或储蓄付款账户")
        if credit.archived_at is not None or payment.archived_at is not None:
            conflict("account_archived", "请先恢复归档账户")
        return credit, payment

    async def _plans(self, account_id: UUID) -> list[InstallmentPlan]:
        return list(
            (
                await self.session.scalars(
                    select(InstallmentPlan)
                    .where(InstallmentPlan.credit_account_id == account_id)
                    .options(selectinload(InstallmentPlan.periods))
                    .order_by(InstallmentPlan.id)
                )
            ).all()
        )

    async def _dependencies(self, account_id: UUID, payment_id: UUID) -> dict[str, Any]:
        accounts = list(
            (
                await self.session.scalars(
                    select(Account)
                    .where(Account.id.in_([account_id, payment_id]))
                    .order_by(Account.id)
                )
            ).all()
        )
        rows = (
            await self.session.execute(
                select(LedgerTransaction.id, LedgerTransaction.version, LedgerTransaction.voided_at)
                .join(Posting)
                .where(Posting.account_id.in_([account_id, payment_id]))
                .distinct()
                .order_by(LedgerTransaction.id)
            )
        ).all()
        plans = await self._plans(account_id)
        cycles = await self.credit.cycles(account_id)
        return {
            "accounts": [
                [
                    str(a.id),
                    a.version,
                    str(a.archived_at),
                    a.opening_balance_minor,
                    str(a.opening_balance_as_of_date),
                ]
                for a in accounts
            ],
            "transactions": [[str(i), v, str(t)] for i, v, t in rows],
            "plans": [
                [
                    str(p.id),
                    p.version,
                    p.lifecycle,
                    [
                        [
                            str(x.id),
                            x.version,
                            str(x.effective_cycle_id),
                            str(x.cancelled_at),
                            str(x.settled_early_at),
                        ]
                        for x in p.periods
                    ],
                ]
                for p in plans
            ],
            "cycles": [
                [str(c.id), c.version, str(c.statement_date), str(c.due_date)] for c in cycles
            ],
        }

    async def _proposal(self, account_id: UUID, request: CreditPayoffRequest) -> dict[str, Any]:
        account, payment = await self._accounts(account_id, request.payment_account_id)
        await validate_credit_invariants(self.credit, {account_id})
        occurred = ensure_utc(request.occurred_at)
        if account.opening_balance_minor > 0 and (
            account.opening_balance_as_of_date is None
            or occurred.astimezone(BUSINESS_TIMEZONE).date() < account.opening_balance_as_of_date
        ):
            invalid("credit_liability_predates_repayment", "请核对期初欠款确认日, 结清不能早于负债")
        if any(ensure_utc(t) > occurred for t, _ in await self.credit.credit_events(account_id)):
            conflict(
                "payoff_future_transactions", "结清日期之后还有信用账目, 请核对结清日期和后续账目"
            )
        impacts = await self.credit.account_impacts([account_id, payment.id])
        debt = checked_int64(account.opening_balance_minor - impacts.get(account_id, 0))
        if debt <= 0:
            conflict("credit_already_settled", "账户当前没有待结清欠款")
        expected = checked_int64(
            debt
            - request.waived_principal_minor
            - request.waived_fee_minor
            + request.additional_fee_minor
        )
        if (
            request.waived_principal_minor + request.waived_fee_minor > debt
            or expected != request.actual_amount_minor
        ):
            invalid(
                "payoff_amount_mismatch",
                "银行实扣与账面欠款、减免及手续费不一致, 请核对差额",
                details={
                    "remaining_minor": expected,
                    "input_minor": request.actual_amount_minor,
                    "difference_minor": request.actual_amount_minor - expected,
                },
            )
        if (
            request.additional_fee_minor
            or request.waived_fee_minor
            or request.waived_principal_minor
        ) and not (request.note or "").strip():
            invalid("payoff_note_required", "存在手续费或减免, 请填写银行核对说明")
        plans = await self._plans(account_id)
        cycles = sorted(await self.credit.cycles(account_id), key=lambda c: (c.due_date, str(c.id)))
        amounts = await self.credit.amounts([c.id for c in cycles])
        allocations: list[CreditPayoffAllocation] = []
        if account.cycle_mode == "on_demand":
            allocations.append(
                CreditPayoffAllocation(
                    cycle_id=None,
                    remaining_minor=debt,
                    principal_minor=debt,
                    fee_minor=0,
                    repaid_minor=0,
                    waived_principal_minor=0,
                    waived_fee_minor=0,
                )
            )
        else:
            for cycle in cycles:
                due, paid = amounts.get(cycle.id, (0, 0))
                remaining = checked_int64(
                    (account.opening_balance_minor if cycle.is_opening_cycle else 0) + due - paid
                )
                if remaining <= 0:
                    continue
                # Only the provably unpaid fee is eligible for a fee waiver. Prior
                # repayments may have paid fees first, so never invent a larger fee balance.
                fee = max(
                    sum(
                        x.fee_minor
                        for p in plans
                        for x in p.periods
                        if x.effective_cycle_id == cycle.id and x.cancelled_at is None
                    )
                    - paid,
                    0,
                )
                fee = min(fee, remaining)
                allocations.append(
                    CreditPayoffAllocation(
                        cycle_id=cycle.id,
                        remaining_minor=remaining,
                        principal_minor=remaining - fee,
                        fee_minor=fee,
                        repaid_minor=0,
                        waived_principal_minor=0,
                        waived_fee_minor=0,
                        installment_plan_ids=[
                            p.id
                            for p in plans
                            if any(
                                x.effective_cycle_id == cycle.id and x.cancelled_at is None
                                for x in p.periods
                            )
                        ],
                    )
                )
            if sum(x.remaining_minor for x in allocations) != debt:
                conflict(
                    "payoff_unallocated_debt", "账期分配与总欠款不一致, 请先核对期初账期或历史分期"
                )
        fee_total = sum(x.fee_minor for x in allocations)
        if request.waived_fee_minor > fee_total:
            invalid(
                "payoff_fee_unverified",
                "手续费减免超过可确认的剩余费用, 请核对原始费用或本金减免",
                details={
                    "remaining_minor": fee_total,
                    "input_minor": request.waived_fee_minor,
                    "difference_minor": request.waived_fee_minor - fee_total,
                },
            )
        if request.waived_principal_minor > debt - fee_total:
            invalid("payoff_principal_exceeded", "本金减免超过剩余本金, 请分别核对费用减免")
        wp, wf = request.waived_principal_minor, request.waived_fee_minor
        for item in allocations:
            item.waived_fee_minor = min(wf, item.fee_minor)
            item.waived_principal_minor = min(wp, item.principal_minor)
            wf -= item.waived_fee_minor
            wp -= item.waived_principal_minor
            item.repaid_minor = (
                item.remaining_minor - item.waived_fee_minor - item.waived_principal_minor
            )
        balance = checked_int64(payment.opening_balance_minor + impacts.get(payment.id, 0))
        return dict(
            account_id=account_id,
            payment_account_id=payment.id,
            payment_balance_before_minor=balance,
            payment_balance_after_minor=checked_int64(balance - request.actual_amount_minor),
            debt_before_minor=debt,
            debt_after_minor=0,
            actual_amount_minor=request.actual_amount_minor,
            principal_minor=debt - fee_total,
            fee_minor=fee_total,
            additional_fee_minor=request.additional_fee_minor,
            waived_principal_minor=request.waived_principal_minor,
            waived_fee_minor=request.waived_fee_minor,
            allocations=allocations,
            closing_installment_plan_ids=[
                p.id
                for p in plans
                if p.lifecycle in {"active", "partially_cancelled"}
                and any(
                    x.cancelled_at is None
                    and x.settled_early_at is None
                    and x.effective_cycle_id in {item.cycle_id for item in allocations}
                    for x in p.periods
                )
            ],
            warnings=[] if request.bank_confirmed_settled else ["请确认银行已全额结清"],
            executable=request.bank_confirmed_settled,
        )

    async def preview(self, account_id: UUID, request: CreditPayoffRequest) -> CreditPayoffPreview:
        await acquire_mutation_lock(self.session)
        proposal = await self._proposal(account_id, request)
        preview = ActionPreviewSession(
            action="credit_payoff",
            request_hash=digest([account_id, request.model_dump(mode="json")]),
            payload={
                "dependencies": digest(
                    await self._dependencies(account_id, request.payment_account_id)
                )
            },
            data_revision=await self._revision(),
            expires_at=utc_now() + timedelta(minutes=30),
        )
        self.session.add(preview)
        await self.session.commit()
        return CreditPayoffPreview(
            **proposal,
            preview_token=preview.id,
            preview_expires_at=preview.expires_at,
            data_revision=preview.data_revision,
        )

    async def _preview(
        self, token: UUID, action: str, request_hash: str, account_id: UUID, payment_id: UUID
    ) -> ActionPreviewSession:
        preview = await self.session.get(ActionPreviewSession, token)
        if (
            preview is None
            or preview.action != action
            or preview.request_hash != request_hash
            or preview.consumed_at is not None
            or ensure_utc(preview.expires_at) <= utc_now()
        ):
            conflict("payoff_preview_expired", "预览已失效, 请重新核对")
        if preview.payload.get("dependencies") != digest(
            await self._dependencies(account_id, payment_id)
        ):
            conflict("payoff_preview_changed", "账户或关联账目已变化, 请重新预览")
        return preview

    async def list(self, account_id: UUID) -> list[CreditPayoffReceipt]:
        operations = (
            await self.session.scalars(
                select(CreditPayoffOperation)
                .where(CreditPayoffOperation.account_id == account_id)
                .order_by(CreditPayoffOperation.created_at.desc(), CreditPayoffOperation.id.desc())
            )
        ).all()
        return [CreditPayoffReceipt.model_validate(op.receipt) for op in operations]

    async def get(self, operation_id: UUID) -> CreditPayoffReceipt:
        operation = await self._operation(operation_id)
        return CreditPayoffReceipt.model_validate(operation.receipt)

    async def _operation(self, operation_id: UUID) -> CreditPayoffOperation:
        operation = await self.session.get(CreditPayoffOperation, operation_id)
        if operation is None:
            not_found("credit_payoff_not_found", "结清回执不存在")
        return operation

    async def _write_transaction(
        self,
        operation: CreditPayoffOperation,
        kind: str,
        amount: int,
        cycle_id: UUID | None,
        request: CreditPayoffRequest,
        index: int,
    ) -> UUID:
        transaction = LedgerTransaction(
            kind=kind,
            occurred_at=ensure_utc(request.occurred_at),
            title="账户全额结清",
            note=request.note,
            credit_cycle_id=cycle_id,
            source="system",
            idempotency_key=uuid5(operation.id, str(index)),
            request_hash=operation.request_hash,
        )
        self.session.add(transaction)
        await self.session.flush()
        if kind == "repayment":
            postings = [
                Posting(
                    transaction_id=transaction.id,
                    account_id=operation.payment_account_id,
                    role="source",
                    amount_minor=-amount,
                    position=0,
                ),
                Posting(
                    transaction_id=transaction.id,
                    account_id=operation.account_id,
                    role="destination",
                    amount_minor=amount,
                    position=1,
                ),
            ]
        else:
            postings = [
                Posting(
                    transaction_id=transaction.id,
                    account_id=operation.payment_account_id
                    if kind == "credit_settlement_fee"
                    else operation.account_id,
                    role="account",
                    amount_minor=-amount if kind == "credit_settlement_fee" else amount,
                    position=0,
                )
            ]
        self.session.add_all(postings)
        await self.transactions._adjust_usage(set(), {p.account_id for p in postings}, None, None)
        await self.session.flush()
        self.transactions._add_revision(
            transaction, RevisionEvent.CREATED, self.transactions._response(transaction, postings)
        )
        self.session.add(
            CreditPayoffLink(
                operation_id=operation.id,
                transaction_id=transaction.id,
                role=kind,
                credit_cycle_id=cycle_id,
            )
        )
        return transaction.id

    async def commit(
        self, account_id: UUID, request: CreditPayoffCommitRequest, key: UUID
    ) -> CreditPayoffReceipt:
        await acquire_mutation_lock(self.session)
        base = CreditPayoffRequest.model_validate(request.model_dump(exclude={"preview_token"}))
        request_hash = digest([account_id, request.model_dump(mode="json")])
        existing = await self.session.scalar(
            select(CreditPayoffOperation).where(CreditPayoffOperation.idempotency_key == key)
        )
        if existing is not None:
            if existing.request_hash != request_hash:
                conflict("idempotency_key_reused", "幂等键已用于不同请求")
            return CreditPayoffReceipt.model_validate(existing.receipt)
        preview = await self._preview(
            request.preview_token,
            "credit_payoff",
            digest([account_id, base.model_dump(mode="json")]),
            account_id,
            request.payment_account_id,
        )
        proposal = await self._proposal(account_id, base)
        if not request.bank_confirmed_settled:
            invalid("payoff_bank_confirmation_required", "请确认银行已全额结清")
        plans = await self._plans(account_id)
        # Repayments belong to a cycle, not an individual installment. Capture
        # the unpaid cycles before writing payoff postings; afterwards every
        # cycle is settled and its prior state can no longer be inferred.
        closing_cycle_ids = {item.cycle_id for item in proposal["allocations"]}
        closing_period_ids = {
            period.id
            for plan in plans
            if plan.id in proposal["closing_installment_plan_ids"]
            for period in plan.periods
            if period.cancelled_at is None
            and period.settled_early_at is None
            and period.effective_cycle_id in closing_cycle_ids
        }
        snapshots = [
            {
                "id": str(p.id),
                "lifecycle": p.lifecycle,
                "periods": [
                    {
                        "id": str(x.id),
                        "settled_early_at": x.settled_early_at.isoformat()
                        if x.settled_early_at
                        else None,
                    }
                    for x in p.periods
                    if x.id in closing_period_ids
                ],
            }
            for p in plans
            if p.id in proposal["closing_installment_plan_ids"]
        ]
        operation = CreditPayoffOperation(
            id=uuid4(),
            account_id=account_id,
            payment_account_id=request.payment_account_id,
            idempotency_key=key,
            request_hash=request_hash,
            occurred_at=ensure_utc(request.occurred_at),
            status="completed",
            payload={},
            receipt={},
        )
        self.session.add(operation)
        await self.session.flush()
        transaction_ids: list[UUID] = []
        for item in proposal["allocations"]:
            for kind, amount in [
                ("repayment", item.repaid_minor),
                ("credit_principal_waiver", item.waived_principal_minor),
                ("credit_fee_refund", item.waived_fee_minor),
            ]:
                if amount:
                    transaction_ids.append(
                        await self._write_transaction(
                            operation, kind, amount, item.cycle_id, base, len(transaction_ids)
                        )
                    )
        if request.additional_fee_minor:
            transaction_ids.append(
                await self._write_transaction(
                    operation,
                    "credit_settlement_fee",
                    request.additional_fee_minor,
                    None,
                    base,
                    len(transaction_ids),
                )
            )
        for plan in plans:
            if plan.id in proposal["closing_installment_plan_ids"]:
                plan.lifecycle = "settled_early"
                plan.version += 1
                plan.updated_at = utc_now()
                for period in plan.periods:
                    if period.id in closing_period_ids:
                        period.settled_early_at = ensure_utc(request.occurred_at)
                        period.version += 1
                        period.updated_at = utc_now()
        await self.session.flush()
        await validate_credit_invariants(self.credit, {account_id})
        impacts = await self.credit.account_impacts([account_id])
        account = await self.session.get(Account, account_id)
        if account is None or account.opening_balance_minor - impacts.get(account_id, 0) != 0:
            raise RuntimeError("payoff did not settle all debt")
        await self._plan_revisions(plans, proposal["closing_installment_plan_ids"], "settled_early")
        receipt = CreditPayoffReceipt(
            operation_id=operation.id,
            account_id=account_id,
            payment_account_id=request.payment_account_id,
            occurred_at=request.occurred_at,
            status="completed",
            data_revision=(await self._revision()) + 1,
            actual_amount_minor=request.actual_amount_minor,
            debt_before_minor=proposal["debt_before_minor"],
            debt_after_minor=0,
            transaction_ids=transaction_ids,
            allocations=proposal["allocations"],
        )
        operation.receipt = receipt.model_dump(mode="json")
        operation.payload = {
            "plans_before": snapshots,
            "dependencies_after": digest(
                await self._dependencies(account_id, request.payment_account_id)
            ),
        }
        preview.consumed_at = utc_now()
        await self.session.commit()
        return receipt

    async def _plan_revisions(
        self, plans: list[InstallmentPlan], ids: list[UUID], event: str
    ) -> None:
        from fiscal_api.services.installments import InstallmentService

        for plan in plans:
            if plan.id in ids:
                response = await InstallmentService(self.session).response(plan)
                self.session.add(
                    InstallmentPlanRevision(
                        plan_id=plan.id,
                        version=plan.version,
                        event=event,
                        snapshot=response.model_dump(mode="json"),
                    )
                )

    async def _can_reverse(self, operation: CreditPayoffOperation) -> None:
        if operation.status != "completed":
            conflict("payoff_already_reversed", "此结清已撤销")
        await self._accounts(operation.account_id, operation.payment_account_id)
        if operation.payload.get("dependencies_after") != digest(
            await self._dependencies(operation.account_id, operation.payment_account_id)
        ):
            conflict(
                "payoff_reverse_dependency", "结清后账户、账目或分期已有后续变更, 不能整组撤销"
            )

    async def reverse_preview(self, operation_id: UUID) -> CreditPayoffReversePreview:
        await acquire_mutation_lock(self.session)
        operation = await self._operation(operation_id)
        await self._can_reverse(operation)
        preview = ActionPreviewSession(
            action="credit_payoff_reverse",
            request_hash=digest([operation_id]),
            payload={
                "dependencies": digest(
                    await self._dependencies(operation.account_id, operation.payment_account_id)
                )
            },
            data_revision=await self._revision(),
            expires_at=utc_now() + timedelta(minutes=30),
        )
        self.session.add(preview)
        await self.session.commit()
        return CreditPayoffReversePreview(
            operation_id=operation_id,
            preview_token=preview.id,
            preview_expires_at=preview.expires_at,
            data_revision=preview.data_revision,
            executable=True,
        )

    async def reverse(
        self, operation_id: UUID, request: CreditPayoffReverseRequest, key: UUID
    ) -> CreditPayoffReceipt:
        await acquire_mutation_lock(self.session)
        operation = await self._operation(operation_id)
        request_hash = digest([operation_id, request.model_dump(mode="json")])
        replay = await self.session.scalar(
            select(CreditPayoffOperation).where(
                CreditPayoffOperation.reverse_idempotency_key == key
            )
        )
        if replay is not None:
            if replay.id != operation_id or replay.reverse_request_hash != request_hash:
                conflict("idempotency_key_reused", "幂等键已用于不同撤销请求")
            return CreditPayoffReceipt.model_validate(replay.receipt)
        await self._can_reverse(operation)
        preview = await self._preview(
            request.preview_token,
            "credit_payoff_reverse",
            digest([operation_id]),
            operation.account_id,
            operation.payment_account_id,
        )
        account = await self.session.get(Account, operation.account_id)
        if account is None:
            raise RuntimeError("payoff account missing")
        impacts_before = await self.credit.account_impacts([operation.account_id])
        debt_before = checked_int64(
            account.opening_balance_minor - impacts_before.get(operation.account_id, 0)
        )
        if debt_before != 0:
            raise RuntimeError("payoff reversal must start from settled debt")
        rows = list(
            (
                await self.session.scalars(
                    select(LedgerTransaction)
                    .join(CreditPayoffLink, CreditPayoffLink.transaction_id == LedgerTransaction.id)
                    .where(CreditPayoffLink.operation_id == operation_id)
                    .options(selectinload(LedgerTransaction.postings))
                )
            ).all()
        )
        for transaction in rows:
            transaction.voided_at = utc_now()
            transaction.version += 1
            transaction.updated_at = utc_now()
            await self.transactions._adjust_usage(
                {p.account_id for p in transaction.postings}, set(), None, None
            )
            self.transactions._add_revision(
                transaction,
                RevisionEvent.VOIDED,
                self.transactions._response(transaction, list(transaction.postings)),
            )
        plans = await self._plans(operation.account_id)
        snapshots: Any = operation.payload["plans_before"]
        restored: list[UUID] = []
        for snapshot in snapshots:
            plan = next(p for p in plans if str(p.id) == snapshot["id"])
            plan.lifecycle = snapshot["lifecycle"]
            plan.version += 1
            plan.updated_at = utc_now()
            restored.append(plan.id)
            periods = {str(x.id): x for x in plan.periods}
            for saved in snapshot["periods"]:
                period = periods[saved["id"]]
                from datetime import datetime

                period.settled_early_at = (
                    datetime.fromisoformat(saved["settled_early_at"])
                    if saved["settled_early_at"]
                    else None
                )
                period.version += 1
                period.updated_at = utc_now()
        await self.session.flush()
        await validate_credit_invariants(self.credit, {operation.account_id})
        impacts_after = await self.credit.account_impacts([operation.account_id])
        debt_after = checked_int64(
            account.opening_balance_minor - impacts_after.get(operation.account_id, 0)
        )
        if debt_after != operation.receipt["debt_before_minor"]:
            raise RuntimeError("payoff reversal did not restore original debt")
        await self._plan_revisions(plans, restored, "reopened")
        operation.status = "reversed"
        operation.reversed_at = utc_now()
        operation.reverse_idempotency_key = key
        operation.reverse_request_hash = request_hash
        receipt = CreditPayoffReceipt.model_validate(operation.receipt).model_copy(
            update={
                "status": "reversed",
                "reversed_at": operation.reversed_at,
                "data_revision": (await self._revision()) + 1,
                "debt_before_minor": debt_before,
                "debt_after_minor": debt_after,
            }
        )
        operation.receipt = receipt.model_dump(mode="json")
        preview.consumed_at = utc_now()
        await self.session.commit()
        return receipt
