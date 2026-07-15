from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import and_, case, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from fiscal_api.db.models import (
    LedgerTransaction,
    Posting,
    ReimbursementAllocation,
    ReimbursementClaim,
    ReimbursementOperation,
    ReimbursementReceipt,
    ReimbursementReceiptAllocation,
)


class ReimbursementRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    @staticmethod
    def _options():
        return (
            selectinload(ReimbursementClaim.parties),
            selectinload(ReimbursementClaim.allocations),
            selectinload(ReimbursementClaim.receipts).selectinload(
                ReimbursementReceipt.allocations
            ),
        )

    async def claim(self, claim_id: UUID, *, for_update: bool = False) -> ReimbursementClaim | None:
        statement = (
            select(ReimbursementClaim)
            .where(ReimbursementClaim.id == claim_id)
            .options(*self._options())
        )
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def claim_for_key(self, key: UUID) -> ReimbursementClaim | None:
        return await self.session.scalar(
            select(ReimbursementClaim)
            .where(ReimbursementClaim.create_idempotency_key == key)
            .options(*self._options())
        )

    async def claims(
        self,
        *,
        limit: int,
        status: str | None,
        query: str | None,
        expense_transaction_id: UUID | None,
        include_archived: bool,
        include_voided: bool,
        cursor_time: datetime | None,
        cursor_id: UUID | None,
    ) -> list[ReimbursementClaim]:
        statement = select(ReimbursementClaim).options(*self._options())
        if not include_archived:
            statement = statement.where(ReimbursementClaim.archived_at.is_(None))
        if not include_voided:
            statement = statement.where(ReimbursementClaim.voided_at.is_(None))
        if query:
            escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            pattern = f"%{escaped}%"
            statement = statement.where(
                or_(
                    ReimbursementClaim.title.ilike(pattern, escape="\\"),
                    ReimbursementClaim.note.ilike(pattern, escape="\\"),
                )
            )
        if expense_transaction_id is not None:
            statement = statement.where(
                select(ReimbursementAllocation.id)
                .where(
                    ReimbursementAllocation.claim_id == ReimbursementClaim.id,
                    ReimbursementAllocation.transaction_id == expense_transaction_id,
                )
                .exists()
            )
        if status is not None:
            total = (
                select(func.coalesce(func.sum(ReimbursementAllocation.amount_minor), 0))
                .where(ReimbursementAllocation.claim_id == ReimbursementClaim.id)
                .correlate(ReimbursementClaim)
                .scalar_subquery()
            )
            received = (
                select(func.coalesce(func.sum(ReimbursementReceiptAllocation.amount_minor), 0))
                .join(
                    ReimbursementReceipt,
                    ReimbursementReceipt.id == ReimbursementReceiptAllocation.receipt_id,
                )
                .join(
                    LedgerTransaction,
                    LedgerTransaction.id == ReimbursementReceipt.transaction_id,
                )
                .where(
                    ReimbursementReceipt.claim_id == ReimbursementClaim.id,
                    LedgerTransaction.voided_at.is_(None),
                )
                .correlate(ReimbursementClaim)
                .scalar_subquery()
            )
            if status == "draft":
                predicate = and_(
                    ReimbursementClaim.cancelled_at.is_(None),
                    ReimbursementClaim.submitted_at.is_(None),
                    received == 0,
                )
            elif status == "pending":
                predicate = and_(
                    ReimbursementClaim.cancelled_at.is_(None),
                    ReimbursementClaim.submitted_at.is_not(None),
                    received == 0,
                )
            elif status == "partial_received":
                predicate = and_(
                    ReimbursementClaim.cancelled_at.is_(None), received > 0, received < total
                )
            elif status == "received":
                predicate = and_(
                    ReimbursementClaim.cancelled_at.is_(None), total > 0, received == total
                )
            elif status == "cancelled":
                predicate = and_(ReimbursementClaim.cancelled_at.is_not(None), received == 0)
            else:
                predicate = and_(
                    ReimbursementClaim.cancelled_at.is_not(None),
                    received > 0,
                    received < total,
                )
            statement = statement.where(predicate)
        if cursor_time is not None and cursor_id is not None:
            statement = statement.where(
                or_(
                    ReimbursementClaim.created_at < cursor_time,
                    and_(
                        ReimbursementClaim.created_at == cursor_time,
                        ReimbursementClaim.id < cursor_id,
                    ),
                )
            )
        statement = statement.order_by(
            ReimbursementClaim.created_at.desc(), ReimbursementClaim.id.desc()
        ).limit(limit + 1)
        return list((await self.session.scalars(statement)).all())

    async def transaction(self, transaction_id: UUID) -> LedgerTransaction | None:
        return await self.session.scalar(
            select(LedgerTransaction)
            .where(LedgerTransaction.id == transaction_id)
            .options(selectinload(LedgerTransaction.postings))
        )

    async def transactions(self, ids: set[UUID]) -> dict[UUID, LedgerTransaction]:
        if not ids:
            return {}
        rows = await self.session.scalars(
            select(LedgerTransaction)
            .where(LedgerTransaction.id.in_(ids))
            .options(selectinload(LedgerTransaction.postings))
        )
        return {row.id: row for row in rows.all()}

    async def allocated_for_expense(
        self, transaction_id: UUID, *, exclude_claim: UUID | None = None
    ) -> int:
        active_received = (
            select(func.coalesce(func.sum(ReimbursementReceiptAllocation.amount_minor), 0))
            .join(
                ReimbursementReceipt,
                ReimbursementReceipt.id == ReimbursementReceiptAllocation.receipt_id,
            )
            .join(
                LedgerTransaction,
                LedgerTransaction.id == ReimbursementReceipt.transaction_id,
            )
            .where(
                ReimbursementReceiptAllocation.allocation_id == ReimbursementAllocation.id,
                LedgerTransaction.voided_at.is_(None),
            )
            .correlate(ReimbursementAllocation)
            .scalar_subquery()
        )
        effective = case(
            (ReimbursementClaim.voided_at.is_not(None), 0),
            (ReimbursementClaim.cancelled_at.is_(None), ReimbursementAllocation.amount_minor),
            else_=active_received,
        )
        statement = (
            select(func.coalesce(func.sum(effective), 0))
            .join(ReimbursementClaim, ReimbursementClaim.id == ReimbursementAllocation.claim_id)
            .where(ReimbursementAllocation.transaction_id == transaction_id)
        )
        if exclude_claim is not None:
            statement = statement.where(ReimbursementClaim.id != exclude_claim)
        return int(await self.session.scalar(statement) or 0)

    async def active_received(self, claim_id: UUID) -> dict[UUID, int]:
        rows = await self.session.execute(
            select(
                ReimbursementReceiptAllocation.allocation_id,
                func.sum(ReimbursementReceiptAllocation.amount_minor),
            )
            .join(
                ReimbursementReceipt,
                ReimbursementReceipt.id == ReimbursementReceiptAllocation.receipt_id,
            )
            .join(LedgerTransaction, LedgerTransaction.id == ReimbursementReceipt.transaction_id)
            .where(ReimbursementReceipt.claim_id == claim_id, LedgerTransaction.voided_at.is_(None))
            .group_by(ReimbursementReceiptAllocation.allocation_id)
        )
        return {allocation_id: int(amount) for allocation_id, amount in rows.all()}

    async def receipt(
        self, receipt_id: UUID, *, for_update: bool = False
    ) -> ReimbursementReceipt | None:
        statement = (
            select(ReimbursementReceipt)
            .where(ReimbursementReceipt.id == receipt_id)
            .options(selectinload(ReimbursementReceipt.allocations))
        )
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def receipts_page(
        self, claim_id: UUID, *, limit: int, cursor_time: datetime | None, cursor_id: UUID | None
    ) -> list[ReimbursementReceipt]:
        statement = (
            select(ReimbursementReceipt)
            .join(LedgerTransaction, LedgerTransaction.id == ReimbursementReceipt.transaction_id)
            .where(ReimbursementReceipt.claim_id == claim_id)
            .options(selectinload(ReimbursementReceipt.allocations))
        )
        if cursor_time is not None and cursor_id is not None:
            statement = statement.where(
                or_(
                    LedgerTransaction.occurred_at < cursor_time,
                    and_(
                        LedgerTransaction.occurred_at == cursor_time,
                        ReimbursementReceipt.id < cursor_id,
                    ),
                )
            )
        return list(
            (
                await self.session.scalars(
                    statement.order_by(
                        LedgerTransaction.occurred_at.desc(), ReimbursementReceipt.id.desc()
                    ).limit(limit + 1)
                )
            ).all()
        )

    async def operation(self, key: UUID) -> ReimbursementOperation | None:
        return await self.session.scalar(
            select(ReimbursementOperation).where(ReimbursementOperation.idempotency_key == key)
        )

    async def reimbursement_for_transaction(
        self, transaction_id: UUID
    ) -> tuple[list[ReimbursementAllocation], ReimbursementReceipt | None]:
        allocations = list(
            (
                await self.session.scalars(
                    select(ReimbursementAllocation).where(
                        ReimbursementAllocation.transaction_id == transaction_id
                    )
                )
            ).all()
        )
        receipt = await self.session.scalar(
            select(ReimbursementReceipt).where(
                ReimbursementReceipt.transaction_id == transaction_id
            )
        )
        return allocations, receipt

    async def expense_options(self) -> list[LedgerTransaction]:
        return list(
            (
                await self.session.scalars(
                    select(LedgerTransaction)
                    .where(
                        LedgerTransaction.kind.in_(["expense", "credit_purchase"]),
                        LedgerTransaction.voided_at.is_(None),
                    )
                    .options(selectinload(LedgerTransaction.postings))
                    .order_by(LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc())
                )
            ).all()
        )

    async def account_impact(self, account_id: UUID) -> int:
        value = await self.session.scalar(
            select(func.coalesce(func.sum(Posting.amount_minor), 0))
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(Posting.account_id == account_id, LedgerTransaction.voided_at.is_(None))
        )
        return int(value or 0)
