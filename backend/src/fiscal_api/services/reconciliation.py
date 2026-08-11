from __future__ import annotations

from datetime import datetime, timedelta
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p21_schemas import (
    AttentionIgnore,
    AttentionItem,
    AttentionPage,
    AttentionSeverity,
    BalanceDiagnosis,
    BalanceDiagnosisItem,
    CheckpointCreate,
    CheckpointResponse,
    ReconciliationState,
    ReconciliationTargetKind,
)
from fiscal_api.core.time import BUSINESS_TIMEZONE, ensure_utc, utc_now
from fiscal_api.db.models import (
    Account,
    AccountKind,
    AIProposal,
    CashFlowItem,
    CreditCycle,
    LedgerTransaction,
    MigrationRun,
    MigrationRunStatus,
    ReconciliationCheckpoint,
    ReimbursementAllocation,
    ReimbursementClaim,
    ReimbursementParty,
    ReimbursementReceipt,
    ReimbursementReceiptAllocation,
)
from fiscal_api.repositories.credit import CreditRepository
from fiscal_api.repositories.reconciliation import ReconciliationRepository
from fiscal_api.services.common import invalid, not_found


class ReconciliationService:
    """Derived reconciliation read-model. It cannot write ledger or postings."""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = ReconciliationRepository(session)

    async def create(self, request: CheckpointCreate) -> CheckpointResponse:
        as_of = ensure_utc(request.as_of)
        if as_of > utc_now() + timedelta(minutes=1):
            invalid("invalid_reconciliation_as_of", "A checkpoint cannot be in the future")
        account_id, cycle_id = await self._validate_target(
            request.target_kind, request.account_id, request.credit_cycle_id
        )
        checkpoint = ReconciliationCheckpoint(
            target_kind=request.target_kind.value,
            account_id=account_id,
            credit_cycle_id=cycle_id,
            as_of=as_of,
            actual_balance_minor=request.actual_balance_minor,
            note=request.note.strip() if request.note else None,
        )
        await self.repository.add(checkpoint)
        await self.session.commit()
        return await self._response(checkpoint)

    async def list(
        self, *, account_id: UUID | None, credit_cycle_id: UUID | None
    ) -> list[CheckpointResponse]:
        if (account_id is None) == (credit_cycle_id is None):
            invalid(
                "invalid_reconciliation_target", "Specify exactly one account_id or credit_cycle_id"
            )
        records = await self.repository.list(account_id=account_id, credit_cycle_id=credit_cycle_id)
        return [await self._response(row) for row in records]

    async def diagnosis(
        self,
        *,
        target_kind: ReconciliationTargetKind,
        account_id: UUID | None,
        credit_cycle_id: UUID | None,
        as_of: datetime,
    ) -> BalanceDiagnosis:
        as_of = ensure_utc(as_of)
        account_id, credit_cycle_id = await self._validate_target(
            target_kind, account_id, credit_cycle_id
        )
        previous = await self.repository.nearest_before(
            account_id=account_id, credit_cycle_id=credit_cycle_id, as_of=as_of
        )
        book = await self._book_balance(target_kind, account_id, credit_cycle_id, as_of)
        start = previous.as_of if previous else None
        if target_kind is ReconciliationTargetKind.ACCOUNT:
            assert account_id is not None
            entries = await self.repository.account_entries(account_id, start, as_of)
        else:
            assert credit_cycle_id is not None
            entries = await self.repository.cycle_entries(credit_cycle_id, start, as_of)
        actual = previous.actual_balance_minor if previous else None
        diagnosis_entries = [
            BalanceDiagnosisItem(
                transaction_id=tx.id,
                occurred_at=tx.occurred_at,
                title=tx.title,
                amount_minor=abs(impact),
                account_impact_minor=impact,
            )
            for tx, impact in entries
        ]
        return BalanceDiagnosis(
            target_kind=target_kind,
            account_id=account_id,
            credit_cycle_id=credit_cycle_id,
            as_of=as_of,
            from_as_of=start,
            opening_balance_minor=actual or 0,
            book_balance_minor=book,
            actual_balance_minor=actual,
            difference_minor=(actual - book) if actual is not None else None,
            entries=diagnosis_entries,
        )

    async def attention(self) -> AttentionPage:
        now = utc_now()
        dismissed = await self.repository.active_dismissals(now)
        items: list[AttentionItem] = []
        checkpoints = await self.repository.list(account_id=None, credit_cycle_id=None)
        latest_targets: set[tuple[str, UUID]] = set()
        for checkpoint in checkpoints:
            target_id = checkpoint.account_id or checkpoint.credit_cycle_id
            if target_id is None or (checkpoint.target_kind, target_id) in latest_targets:
                continue
            latest_targets.add((checkpoint.target_kind, target_id))
            response = await self._response(checkpoint)
            if response.state is ReconciliationState.OPEN:
                items.append(
                    AttentionItem(
                        source_type="reconciliation_checkpoint",
                        source_id=checkpoint.id,
                        severity=AttentionSeverity.WARNING,
                        amount_minor=response.difference_minor,
                        occurred_at=checkpoint.as_of,
                        explanation="实际余额与按该时点重算的账面余额不一致。",
                        suggested_action="查看差额区间并在必要时通过正式余额调整流水修正。",
                        deep_link=f"fiscal://reconciliation/checkpoints/{checkpoint.id}",
                    )
                )
        checked_accounts = {row.account_id for row in checkpoints if row.account_id is not None}
        account_statement = select(Account).where(Account.archived_at.is_(None))
        accounts = list((await self.session.scalars(account_statement)).all())
        for account in accounts:
            if account.id not in checked_accounts:
                items.append(
                    AttentionItem(
                        source_type="reconciliation_missing",
                        source_id=account.id,
                        severity=AttentionSeverity.INFO,
                        explanation=f"{account.name} 尚无余额核对锚点。",
                        suggested_action="输入实际余额进行首次核对。",
                        deep_link=f"fiscal://reconciliation/accounts/{account.id}",
                    )
                )
        transaction_statement = (
            select(LedgerTransaction)
            .where(
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.category_id.is_(None),
                LedgerTransaction.kind.in_(["income", "expense", "credit_purchase"]),
            )
            .order_by(LedgerTransaction.occurred_at.desc())
        )
        uncategorized = list((await self.session.scalars(transaction_statement)).all())
        for tx in uncategorized:
            items.append(
                AttentionItem(
                    source_type="uncategorized_transaction",
                    source_id=tx.id,
                    severity=AttentionSeverity.INFO,
                    occurred_at=tx.occurred_at,
                    explanation="该正式流水尚未归类。",
                    suggested_action="补充分类。",
                    deep_link=f"fiscal://transactions/{tx.id}",
                )
            )
        proposal_statement = (
            select(AIProposal)
            .where(AIProposal.status.in_(["pending", "failed"]))
            .order_by(AIProposal.updated_at.desc())
        )
        proposals = list((await self.session.scalars(proposal_statement)).all())
        for proposal in proposals:
            items.append(
                AttentionItem(
                    source_type="ai_proposal",
                    source_id=proposal.id,
                    severity=(
                        AttentionSeverity.WARNING
                        if proposal.status == "failed"
                        else AttentionSeverity.INFO
                    ),
                    occurred_at=proposal.updated_at,
                    explanation="AI 提案需要确认。"
                    if proposal.status == "pending"
                    else "AI 提案处理失败。",
                    suggested_action="查看并确认、修改或重试。",
                    deep_link=f"fiscal://ai/proposals/{proposal.id}",
                )
            )
        failed_runs = list(
            (
                await self.session.scalars(
                    select(MigrationRun)
                    .where(MigrationRun.status == MigrationRunStatus.FAILED.value)
                    .order_by(MigrationRun.completed_at.desc(), MigrationRun.id.desc())
                )
            ).all()
        )
        for run in failed_runs:
            items.append(
                AttentionItem(
                    source_type="operation_exception",
                    source_id=run.id,
                    severity=AttentionSeverity.CRITICAL,
                    occurred_at=run.completed_at,
                    explanation=f"{run.mode} 数据迁移运行失败。",
                    suggested_action="检查运行记录后在隔离环境重新验证。",
                    deep_link=f"fiscal://settings/migrations/{run.id}",
                )
            )
        business_date = now.astimezone(BUSINESS_TIMEZONE).date()
        cash_flow_statement = select(CashFlowItem).where(
            CashFlowItem.status.in_(["expected", "confirmed"]),
            CashFlowItem.expected_date < business_date,
        )
        for item in (await self.session.scalars(cash_flow_statement)).all():
            items.append(
                AttentionItem(
                    source_type="cash_flow_overdue",
                    source_id=item.id,
                    severity=AttentionSeverity.WARNING,
                    amount_minor=item.planned_amount_minor,
                    explanation=f"现金流项目“{item.title}”已逾期。",
                    suggested_action="确认、结算或取消该现金流项目。",
                    deep_link=f"fiscal://cash-flow/{item.id}",
                )
            )
        party_allocated = (
            select(func.coalesce(func.sum(ReimbursementAllocation.amount_minor), 0))
            .where(ReimbursementAllocation.party_id == ReimbursementParty.id)
            .correlate(ReimbursementParty)
            .scalar_subquery()
        )
        party_received = (
            select(func.coalesce(func.sum(ReimbursementReceiptAllocation.amount_minor), 0))
            .join(
                ReimbursementReceipt,
                ReimbursementReceipt.id == ReimbursementReceiptAllocation.receipt_id,
            )
            .join(LedgerTransaction, LedgerTransaction.id == ReimbursementReceipt.transaction_id)
            .join(
                ReimbursementAllocation,
                ReimbursementAllocation.id == ReimbursementReceiptAllocation.allocation_id,
            )
            .where(
                ReimbursementAllocation.party_id == ReimbursementParty.id,
                LedgerTransaction.voided_at.is_(None),
            )
            .correlate(ReimbursementParty)
            .scalar_subquery()
        )
        party_statement = (
            select(ReimbursementParty, ReimbursementClaim)
            .join(ReimbursementClaim, ReimbursementClaim.id == ReimbursementParty.claim_id)
            .where(
                ReimbursementParty.expected_date.is_not(None),
                ReimbursementParty.expected_date < business_date,
                ReimbursementClaim.submitted_at.is_not(None),
                ReimbursementClaim.cancelled_at.is_(None),
                ReimbursementClaim.voided_at.is_(None),
                party_received < party_allocated,
            )
        )
        for party, claim in (await self.session.execute(party_statement)).all():
            items.append(
                AttentionItem(
                    source_type="reimbursement_overdue",
                    source_id=party.id,
                    severity=AttentionSeverity.WARNING,
                    explanation=f"报销“{claim.title}”的{party.name}已超过预计回款日。",
                    suggested_action="记录回款或更新报销进度。",
                    deep_link=f"fiscal://reimbursements/{claim.id}",
                )
            )
        cycles = list(
            (
                await self.session.scalars(
                    select(CreditCycle).where(CreditCycle.due_date < business_date)
                )
            ).all()
        )
        amounts = await CreditRepository(self.session).amounts([item.id for item in cycles])
        for cycle in cycles:
            purchase, repaid = amounts.get(cycle.id, (0, 0))
            remaining = purchase - repaid
            if remaining > 0:
                items.append(
                    AttentionItem(
                        source_type="credit_cycle_overdue",
                        source_id=cycle.id,
                        severity=AttentionSeverity.CRITICAL,
                        amount_minor=remaining,
                        explanation="信用账期仍有未还余额且已逾期。",
                        suggested_action="查看账期并安排还款。",
                        deep_link=f"fiscal://credit-cycles/{cycle.id}",
                    )
                )
        visible = [item for item in items if (item.source_type, item.source_id) not in dismissed]
        severity = {"critical": 0, "warning": 1, "info": 2}
        visible.sort(
            key=lambda item: (
                severity[item.severity.value],
                item.occurred_at or now,
                str(item.source_id),
            )
        )
        return AttentionPage(items=visible)

    async def ignore_attention(
        self, source_type: str, source_id: UUID, request: AttentionIgnore
    ) -> None:
        expires_at = ensure_utc(request.expires_at)
        if expires_at <= utc_now():
            invalid("invalid_attention_expiry", "Ignore expiry must be in the future")
        await self.repository.dismiss(source_type, source_id, expires_at)
        await self.session.commit()

    async def _response(self, checkpoint: ReconciliationCheckpoint) -> CheckpointResponse:
        kind = ReconciliationTargetKind(checkpoint.target_kind)
        book = await self._book_balance(
            kind, checkpoint.account_id, checkpoint.credit_cycle_id, checkpoint.as_of
        )
        difference = checkpoint.actual_balance_minor - book
        return CheckpointResponse(
            id=checkpoint.id,
            target_kind=kind,
            account_id=checkpoint.account_id,
            credit_cycle_id=checkpoint.credit_cycle_id,
            as_of=checkpoint.as_of,
            actual_balance_minor=checkpoint.actual_balance_minor,
            book_balance_minor=book,
            difference_minor=difference,
            state=(ReconciliationState.RECONCILED if difference == 0 else ReconciliationState.OPEN),
            note=checkpoint.note,
            created_at=checkpoint.created_at,
        )

    async def _validate_target(
        self,
        kind: ReconciliationTargetKind,
        account_id: UUID | None,
        cycle_id: UUID | None,
    ) -> tuple[UUID | None, UUID | None]:
        if kind is ReconciliationTargetKind.ACCOUNT:
            if account_id is None or cycle_id is not None:
                invalid(
                    "invalid_reconciliation_target",
                    "An account checkpoint requires only account_id",
                )
            if await self.session.get(Account, account_id) is None:
                not_found("account_not_found", "The account does not exist")
            return account_id, None
        if cycle_id is None or account_id is not None:
            invalid(
                "invalid_reconciliation_target",
                "A credit-cycle checkpoint requires only credit_cycle_id",
            )
        if await self.session.get(CreditCycle, cycle_id) is None:
            not_found("credit_cycle_not_found", "The credit cycle does not exist")
        return None, cycle_id

    async def _book_balance(
        self,
        kind: ReconciliationTargetKind,
        account_id: UUID | None,
        cycle_id: UUID | None,
        as_of: datetime,
    ) -> int:
        if kind is ReconciliationTargetKind.ACCOUNT:
            assert account_id is not None
            account = await self.session.get(Account, account_id)
            assert account is not None
            impact = await self.repository.account_impact(account_id, as_of)
            if account.kind == AccountKind.CREDIT.value:
                return account.opening_balance_minor - impact
            return account.opening_balance_minor + impact
        assert cycle_id is not None
        cycle = await self.session.get(CreditCycle, cycle_id)
        assert cycle is not None
        if cycle.is_opening_cycle:
            account = await self.session.get(Account, cycle.account_id)
            return account.opening_balance_minor if account else 0
        return await self.repository.cycle_impact(cycle_id, as_of)
