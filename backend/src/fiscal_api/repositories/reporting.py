from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from uuid import UUID

from sqlalchemy import case, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased, selectinload

from fiscal_api.db.models import (
    Account,
    Category,
    CreditCycle,
    InstallmentLedgerLink,
    InstallmentPeriod,
    InstallmentPlan,
    LedgerTransaction,
    Posting,
    ReimbursementAllocation,
    ReimbursementClaim,
    ReimbursementParty,
    ReimbursementReceipt,
    ReimbursementReceiptAllocation,
)


@dataclass(frozen=True)
class RefundFact:
    source_transaction_id: UUID
    refund_transaction_id: UUID
    amount_minor: int


@dataclass(frozen=True)
class ReimbursementFact:
    allocation_id: UUID
    source_transaction_id: UUID
    claim_id: UUID
    party_id: UUID
    party_name: str
    expected_date: date | None
    submitted_at: datetime | None
    cancelled_at: datetime | None
    claim_voided_at: datetime | None
    allocated_minor: int
    received_minor: int


class ReportingRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def transactions(
        self,
        *,
        occurred_from: datetime | None = None,
        occurred_to_exclusive: datetime | None = None,
        kinds: set[str] | None = None,
        excluded_category_ids: set[UUID] | None = None,
    ) -> list[LedgerTransaction]:
        statement = (
            select(LedgerTransaction)
            .where(LedgerTransaction.voided_at.is_(None))
            .options(selectinload(LedgerTransaction.postings))
        )
        if occurred_from is not None:
            statement = statement.where(LedgerTransaction.occurred_at >= occurred_from)
        if occurred_to_exclusive is not None:
            statement = statement.where(LedgerTransaction.occurred_at < occurred_to_exclusive)
        if kinds is not None:
            statement = statement.where(LedgerTransaction.kind.in_(kinds))
        if excluded_category_ids:
            statement = statement.where(
                or_(
                    LedgerTransaction.category_id.is_(None),
                    LedgerTransaction.category_id.not_in(excluded_category_ids),
                )
            )
        statement = statement.order_by(
            LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc()
        )
        return list((await self.session.scalars(statement)).all())

    async def transaction_page(
        self,
        *,
        occurred_from: datetime,
        occurred_to_exclusive: datetime,
        kinds: set[str],
        category_ids: set[UUID] | None,
        excluded_category_ids: set[UUID] | None,
        account_id: UUID | None,
        cursor_time: datetime | None,
        cursor_id: UUID | None,
        limit: int,
    ) -> list[LedgerTransaction]:
        statement = (
            select(LedgerTransaction)
            .where(
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.kind.in_(kinds),
                LedgerTransaction.occurred_at >= occurred_from,
                LedgerTransaction.occurred_at < occurred_to_exclusive,
            )
            .options(selectinload(LedgerTransaction.postings))
        )
        if category_ids is not None:
            statement = statement.where(LedgerTransaction.category_id.in_(category_ids))
        if excluded_category_ids:
            statement = statement.where(
                or_(
                    LedgerTransaction.category_id.is_(None),
                    LedgerTransaction.category_id.not_in(excluded_category_ids),
                )
            )
        if account_id is not None:
            statement = statement.join(Posting).where(Posting.account_id == account_id)
        if cursor_time is not None and cursor_id is not None:
            statement = statement.where(
                (LedgerTransaction.occurred_at < cursor_time)
                | (
                    (LedgerTransaction.occurred_at == cursor_time)
                    & (LedgerTransaction.id < cursor_id)
                )
            )
        statement = statement.order_by(
            LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc()
        ).limit(limit + 1)
        return list((await self.session.scalars(statement)).unique().all())

    async def cash_posting_page(
        self,
        *,
        occurred_from: datetime,
        occurred_to_exclusive: datetime,
        account_id: UUID | None,
        category_ids: set[UUID] | None,
        excluded_category_ids: set[UUID] | None,
        cursor_time: datetime | None,
        cursor_id: UUID | None,
        limit: int,
    ) -> list[tuple[Posting, LedgerTransaction, Account]]:
        statement = (
            select(Posting, LedgerTransaction, Account)
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .join(Account, Account.id == Posting.account_id)
            .where(
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at >= occurred_from,
                LedgerTransaction.occurred_at < occurred_to_exclusive,
                Account.kind.in_(["cash", "debit"]),
            )
        )
        if account_id is not None:
            statement = statement.where(Posting.account_id == account_id)
        if category_ids is not None:
            statement = statement.where(LedgerTransaction.category_id.in_(category_ids))
        if excluded_category_ids:
            statement = statement.where(
                or_(
                    LedgerTransaction.category_id.is_(None),
                    LedgerTransaction.category_id.not_in(excluded_category_ids),
                )
            )
        if cursor_time is not None and cursor_id is not None:
            statement = statement.where(
                (LedgerTransaction.occurred_at < cursor_time)
                | ((LedgerTransaction.occurred_at == cursor_time) & (Posting.id < cursor_id))
            )
        statement = statement.order_by(
            LedgerTransaction.occurred_at.desc(), Posting.id.desc()
        ).limit(limit + 1)
        return list((await self.session.execute(statement)).tuples())

    async def categories(self) -> dict[UUID, Category]:
        values = (await self.session.scalars(select(Category))).all()
        return {item.id: item for item in values}

    async def accounts(self) -> dict[UUID, Account]:
        values = (await self.session.scalars(select(Account))).all()
        return {item.id: item for item in values}

    async def refunds_for_sources(self, source_ids: set[UUID]) -> list[RefundFact]:
        if not source_ids:
            return []
        source_id = case(
            (
                InstallmentLedgerLink.role == "principal_refund",
                InstallmentPlan.purchase_transaction_id,
            ),
            else_=InstallmentPlan.fee_transaction_id,
        )
        rows = await self.session.execute(
            select(source_id, LedgerTransaction.id, func.sum(Posting.amount_minor))
            .select_from(InstallmentLedgerLink)
            .join(InstallmentPlan, InstallmentPlan.id == InstallmentLedgerLink.plan_id)
            .join(
                LedgerTransaction,
                LedgerTransaction.id == InstallmentLedgerLink.transaction_id,
            )
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .where(
                InstallmentLedgerLink.role.in_(["principal_refund", "fee_refund"]),
                source_id.in_(source_ids),
                LedgerTransaction.voided_at.is_(None),
            )
            .group_by(source_id, LedgerTransaction.id)
        )
        return [
            RefundFact(source, refund, int(amount))
            for source, refund, amount in rows
            if source is not None
        ]

    async def reimbursement_facts(
        self, source_ids: set[UUID] | None = None
    ) -> list[ReimbursementFact]:
        receipt_tx = aliased(LedgerTransaction)
        received = func.coalesce(
            func.sum(
                case(
                    (receipt_tx.voided_at.is_(None), ReimbursementReceiptAllocation.amount_minor),
                    else_=0,
                )
            ),
            0,
        )
        statement = (
            select(
                ReimbursementAllocation.id,
                ReimbursementAllocation.transaction_id,
                ReimbursementClaim.id,
                ReimbursementParty.id,
                ReimbursementParty.name,
                ReimbursementParty.expected_date,
                ReimbursementClaim.submitted_at,
                ReimbursementClaim.cancelled_at,
                ReimbursementClaim.voided_at,
                ReimbursementAllocation.amount_minor,
                received,
            )
            .join(ReimbursementClaim, ReimbursementClaim.id == ReimbursementAllocation.claim_id)
            .join(ReimbursementParty, ReimbursementParty.id == ReimbursementAllocation.party_id)
            .outerjoin(
                ReimbursementReceiptAllocation,
                ReimbursementReceiptAllocation.allocation_id == ReimbursementAllocation.id,
            )
            .outerjoin(
                ReimbursementReceipt,
                ReimbursementReceipt.id == ReimbursementReceiptAllocation.receipt_id,
            )
            .outerjoin(receipt_tx, receipt_tx.id == ReimbursementReceipt.transaction_id)
            .group_by(
                ReimbursementAllocation.id,
                ReimbursementClaim.id,
                ReimbursementParty.id,
            )
        )
        if source_ids is not None:
            if not source_ids:
                return []
            statement = statement.where(ReimbursementAllocation.transaction_id.in_(source_ids))
        rows = await self.session.execute(statement)
        return [
            ReimbursementFact(
                allocation_id=allocation_id,
                source_transaction_id=transaction_id,
                claim_id=claim_id,
                party_id=party_id,
                party_name=party_name,
                expected_date=expected_date,
                submitted_at=submitted_at,
                cancelled_at=cancelled_at,
                claim_voided_at=claim_voided_at,
                allocated_minor=int(allocated),
                received_minor=int(received_minor),
            )
            for (
                allocation_id,
                transaction_id,
                claim_id,
                party_id,
                party_name,
                expected_date,
                submitted_at,
                cancelled_at,
                claim_voided_at,
                allocated,
                received_minor,
            ) in rows
        ]

    async def credit_cycles(self) -> list[CreditCycle]:
        return list(
            (
                await self.session.scalars(
                    select(CreditCycle).order_by(CreditCycle.due_date, CreditCycle.id)
                )
            ).all()
        )

    async def credit_cycle_amounts(self, cycle_ids: list[UUID]) -> dict[UUID, tuple[int, int]]:
        from fiscal_api.repositories.credit import CreditRepository

        return await CreditRepository(self.session).amounts(cycle_ids)

    async def account_impacts(self, account_ids: list[UUID]) -> dict[UUID, int]:
        from fiscal_api.repositories.credit import CreditRepository

        return await CreditRepository(self.session).account_impacts(account_ids)

    async def installment_periods(
        self,
    ) -> list[tuple[InstallmentPeriod, InstallmentPlan, CreditCycle, LedgerTransaction]]:
        rows = await self.session.execute(
            select(InstallmentPeriod, InstallmentPlan, CreditCycle, LedgerTransaction)
            .join(InstallmentPlan, InstallmentPlan.id == InstallmentPeriod.plan_id)
            .join(CreditCycle, CreditCycle.id == InstallmentPeriod.effective_cycle_id)
            .join(
                LedgerTransaction,
                LedgerTransaction.id == InstallmentPlan.purchase_transaction_id,
            )
            .where(
                InstallmentPeriod.cancelled_at.is_(None),
                InstallmentPeriod.settled_early_at.is_(None),
                LedgerTransaction.voided_at.is_(None),
            )
            .options(selectinload(InstallmentPlan.periods))
            .order_by(CreditCycle.statement_date, InstallmentPeriod.id)
        )
        return list(rows.unique().tuples())
