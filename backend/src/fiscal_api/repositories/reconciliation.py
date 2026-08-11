from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models import (
    AttentionDismissal,
    LedgerTransaction,
    Posting,
    ReconciliationCheckpoint,
)


class ReconciliationRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def account_impact(self, account_id: UUID, as_of: datetime) -> int:
        statement = (
            select(func.coalesce(func.sum(Posting.amount_minor), 0))
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(
                Posting.account_id == account_id,
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at <= as_of,
            )
        )
        return int(await self.session.scalar(statement) or 0)

    async def account_entries(
        self, account_id: UUID, start: datetime | None, end: datetime
    ) -> list[tuple[LedgerTransaction, int]]:
        statement = (
            select(LedgerTransaction, Posting.amount_minor)
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .where(
                Posting.account_id == account_id,
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at <= end,
            )
            .order_by(LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc())
        )
        if start is not None:
            statement = statement.where(LedgerTransaction.occurred_at > start)
        rows = (await self.session.execute(statement)).all()
        return [(item, int(amount)) for item, amount in rows]

    async def cycle_impact(self, cycle_id: UUID, as_of: datetime) -> int:
        statement = (
            select(func.coalesce(func.sum(-Posting.amount_minor), 0))
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(
                LedgerTransaction.credit_cycle_id == cycle_id,
                LedgerTransaction.kind.in_(["credit_purchase", "repayment"]),
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at <= as_of,
                Posting.role.in_(["account", "destination"]),
            )
        )
        return int(await self.session.scalar(statement) or 0)

    async def cycle_entries(
        self, cycle_id: UUID, start: datetime | None, end: datetime
    ) -> list[tuple[LedgerTransaction, int]]:
        statement = (
            select(LedgerTransaction, -Posting.amount_minor)
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .where(
                LedgerTransaction.credit_cycle_id == cycle_id,
                LedgerTransaction.kind.in_(["credit_purchase", "repayment"]),
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at <= end,
                Posting.role.in_(["account", "destination"]),
            )
            .order_by(LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc())
        )
        if start is not None:
            statement = statement.where(LedgerTransaction.occurred_at > start)
        rows = (await self.session.execute(statement)).all()
        return [(item, int(amount)) for item, amount in rows]

    async def add(self, checkpoint: ReconciliationCheckpoint) -> None:
        self.session.add(checkpoint)

    async def list(
        self, *, account_id: UUID | None, credit_cycle_id: UUID | None
    ) -> list[ReconciliationCheckpoint]:
        statement = select(ReconciliationCheckpoint).order_by(
            ReconciliationCheckpoint.as_of.desc(), ReconciliationCheckpoint.created_at.desc()
        )
        if account_id is not None:
            statement = statement.where(ReconciliationCheckpoint.account_id == account_id)
        if credit_cycle_id is not None:
            statement = statement.where(ReconciliationCheckpoint.credit_cycle_id == credit_cycle_id)
        return list((await self.session.scalars(statement)).all())

    async def nearest_before(
        self,
        *,
        account_id: UUID | None,
        credit_cycle_id: UUID | None,
        as_of: datetime,
    ) -> ReconciliationCheckpoint | None:
        statement = (
            select(ReconciliationCheckpoint)
            .where(ReconciliationCheckpoint.as_of < as_of)
            .order_by(ReconciliationCheckpoint.as_of.desc())
            .limit(1)
        )
        if account_id is not None:
            statement = statement.where(ReconciliationCheckpoint.account_id == account_id)
        if credit_cycle_id is not None:
            statement = statement.where(ReconciliationCheckpoint.credit_cycle_id == credit_cycle_id)
        return await self.session.scalar(statement)

    async def active_dismissals(self, now: datetime) -> set[tuple[str, UUID]]:
        statement = select(AttentionDismissal.source_type, AttentionDismissal.source_id).where(
            AttentionDismissal.expires_at > now
        )
        rows = await self.session.execute(statement)
        return {(kind, identifier) for kind, identifier in rows.all()}

    async def dismiss(self, source_type: str, source_id: UUID, expires_at: datetime) -> None:
        statement = select(AttentionDismissal).where(
            AttentionDismissal.source_type == source_type,
            AttentionDismissal.source_id == source_id,
        )
        existing = await self.session.scalar(statement)
        if existing is None:
            self.session.add(
                AttentionDismissal(
                    source_type=source_type,
                    source_id=source_id,
                    expires_at=expires_at,
                )
            )
        else:
            existing.expires_at = expires_at
