from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import exists, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models import (
    AttentionDismissal,
    InstallmentLedgerLink,
    InstallmentPeriod,
    InstallmentPlan,
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
        return sum(amount for _, amount in await self.cycle_entries(cycle_id, None, as_of))

    async def cycle_entries(
        self, cycle_id: UUID, start: datetime | None, end: datetime
    ) -> list[tuple[LedgerTransaction, int]]:
        """Return the same direct and installment liabilities as credit-cycle balances.

        A checkpoint is an as-of view, so it cannot use the current-cycle aggregate alone:
        a later purchase or repayment must not affect the historical balance.
        """
        direct = (
            select(LedgerTransaction, -Posting.amount_minor)
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .where(
                LedgerTransaction.credit_cycle_id == cycle_id,
                LedgerTransaction.kind.in_(["credit_purchase", "repayment"]),
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.occurred_at <= end,
                Posting.role.in_(["account", "destination"]),
                or_(
                    LedgerTransaction.kind == "repayment",
                    ~exists().where(InstallmentLedgerLink.transaction_id == LedgerTransaction.id),
                ),
            )
        )
        if start is not None:
            direct = direct.where(LedgerTransaction.occurred_at > start)
        rows = [(item, int(amount)) for item, amount in (await self.session.execute(direct)).all()]

        for transaction_id, amount_column in (
            (InstallmentPlan.purchase_transaction_id, InstallmentPeriod.principal_minor),
            (InstallmentPlan.fee_transaction_id, InstallmentPeriod.fee_minor),
        ):
            installment = (
                select(LedgerTransaction, amount_column)
                .join(InstallmentPlan, transaction_id == LedgerTransaction.id)
                .join(InstallmentPeriod, InstallmentPeriod.plan_id == InstallmentPlan.id)
                .where(
                    InstallmentPeriod.effective_cycle_id == cycle_id,
                    InstallmentPeriod.cancelled_at.is_(None),
                    LedgerTransaction.voided_at.is_(None),
                    LedgerTransaction.occurred_at <= end,
                )
            )
            if start is not None:
                installment = installment.where(LedgerTransaction.occurred_at > start)
            rows.extend(
                (item, int(amount))
                for item, amount in (await self.session.execute(installment)).all()
            )
        return sorted(rows, key=lambda row: (row[0].occurred_at, row[0].id), reverse=True)

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

    async def get(self, checkpoint_id: UUID) -> ReconciliationCheckpoint | None:
        return await self.session.scalar(
            select(ReconciliationCheckpoint).where(ReconciliationCheckpoint.id == checkpoint_id)
        )

    async def latest_by_target(self) -> list[ReconciliationCheckpoint]:
        """Return exactly one newest checkpoint for each account or credit cycle."""
        statement = (
            select(ReconciliationCheckpoint)
            .distinct(
                ReconciliationCheckpoint.target_kind,
                ReconciliationCheckpoint.account_id,
                ReconciliationCheckpoint.credit_cycle_id,
            )
            .order_by(
                ReconciliationCheckpoint.target_kind,
                ReconciliationCheckpoint.account_id,
                ReconciliationCheckpoint.credit_cycle_id,
                ReconciliationCheckpoint.as_of.desc(),
                ReconciliationCheckpoint.created_at.desc(),
                ReconciliationCheckpoint.id.desc(),
            )
        )
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
