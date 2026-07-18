from __future__ import annotations

from datetime import date, datetime
from uuid import UUID

from sqlalchemy import Select, case, exists, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models import (
    Account,
    CreditCycle,
    InstallmentLedgerLink,
    InstallmentPeriod,
    InstallmentPlan,
    LedgerTransaction,
    Posting,
)


class CreditRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def account(self, account_id: UUID, *, for_update: bool = False) -> Account | None:
        statement = select(Account).where(Account.id == account_id)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def active_accounts(self) -> list[Account]:
        return list(
            (
                await self.session.scalars(
                    select(Account)
                    .where(Account.kind == "credit", Account.archived_at.is_(None))
                    .order_by(Account.sort_order, Account.created_at, Account.id)
                )
            ).all()
        )

    async def cycle(self, cycle_id: UUID, *, for_update: bool = False) -> CreditCycle | None:
        statement = select(CreditCycle).where(CreditCycle.id == cycle_id)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def cycle_for_period(
        self, account_id: UUID, period_start: date, period_end: date
    ) -> CreditCycle | None:
        return await self.session.scalar(
            select(CreditCycle).where(
                CreditCycle.account_id == account_id,
                CreditCycle.period_start == period_start,
                CreditCycle.period_end == period_end,
            )
        )

    async def opening_cycle(self, account_id: UUID) -> CreditCycle | None:
        return await self.session.scalar(
            select(CreditCycle).where(
                CreditCycle.account_id == account_id, CreditCycle.is_opening_cycle.is_(True)
            )
        )

    def add_cycle(self, cycle: CreditCycle) -> None:
        self.session.add(cycle)

    async def cycles(
        self,
        account_id: UUID,
        *,
        limit: int | None = None,
        cursor_end: date | None = None,
        cursor_id: UUID | None = None,
    ) -> list[CreditCycle]:
        statement: Select[tuple[CreditCycle]] = select(CreditCycle).where(
            CreditCycle.account_id == account_id
        )
        if cursor_end is not None and cursor_id is not None:
            statement = statement.where(
                or_(
                    CreditCycle.period_end < cursor_end,
                    (CreditCycle.period_end == cursor_end) & (CreditCycle.id < cursor_id),
                )
            )
        statement = statement.order_by(CreditCycle.period_end.desc(), CreditCycle.id.desc())
        if limit is not None:
            statement = statement.limit(limit + 1)
        return list((await self.session.scalars(statement)).all())

    async def amounts(self, cycle_ids: list[UUID]) -> dict[UUID, tuple[int, int]]:
        if not cycle_ids:
            return {}
        rows = await self.session.execute(
            select(
                LedgerTransaction.credit_cycle_id,
                func.coalesce(
                    func.sum(
                        case(
                            (LedgerTransaction.kind == "credit_purchase", -Posting.amount_minor),
                            else_=0,
                        )
                    ),
                    0,
                ),
                func.coalesce(
                    func.sum(
                        case(
                            (
                                (LedgerTransaction.kind == "repayment")
                                & (Posting.role == "destination"),
                                Posting.amount_minor,
                            ),
                            else_=0,
                        )
                    ),
                    0,
                ),
            )
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .where(
                LedgerTransaction.credit_cycle_id.in_(cycle_ids),
                LedgerTransaction.voided_at.is_(None),
                or_(
                    LedgerTransaction.kind == "repayment",
                    ~exists().where(InstallmentLedgerLink.transaction_id == LedgerTransaction.id),
                ),
            )
            .group_by(LedgerTransaction.credit_cycle_id)
        )
        result = {cycle_id: (int(purchase), int(repaid)) for cycle_id, purchase, repaid in rows}
        allocations = await self.session.execute(
            select(
                InstallmentPeriod.effective_cycle_id,
                func.sum(InstallmentPeriod.principal_minor + InstallmentPeriod.fee_minor),
            )
            .where(
                InstallmentPeriod.effective_cycle_id.in_(cycle_ids),
                InstallmentPeriod.cancelled_at.is_(None),
            )
            .group_by(InstallmentPeriod.effective_cycle_id)
        )
        for cycle_id, amount in allocations:
            direct, repaid = result.get(cycle_id, (0, 0))
            result[cycle_id] = (direct + int(amount), repaid)
        return result

    async def account_impacts(self, account_ids: list[UUID]) -> dict[UUID, int]:
        if not account_ids:
            return {}
        rows = await self.session.execute(
            select(Posting.account_id, func.coalesce(func.sum(Posting.amount_minor), 0))
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(Posting.account_id.in_(account_ids), LedgerTransaction.voided_at.is_(None))
            .group_by(Posting.account_id)
        )
        return {account_id: int(amount) for account_id, amount in rows}

    async def schedule_is_used(self, account_id: UUID) -> bool:
        cycle_exists = await self.session.scalar(
            select(CreditCycle.id)
            .where(
                CreditCycle.account_id == account_id,
                CreditCycle.is_opening_cycle.is_(False),
            )
            .limit(1)
        )
        if cycle_exists is not None:
            return True
        event_exists = await self.session.scalar(
            select(Posting.id)
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(
                Posting.account_id == account_id,
                LedgerTransaction.kind.in_(["credit_purchase", "repayment"]),
            )
            .limit(1)
        )
        return event_exists is not None

    async def has_any_cycle(self, account_id: UUID) -> bool:
        return (
            await self.session.scalar(
                select(CreditCycle.id).where(CreditCycle.account_id == account_id).limit(1)
            )
            is not None
        )

    async def credit_events(self, account_id: UUID) -> list[tuple[datetime, int]]:
        rows = await self.session.execute(
            select(LedgerTransaction.occurred_at, func.sum(-Posting.amount_minor))
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .where(
                Posting.account_id == account_id,
                LedgerTransaction.voided_at.is_(None),
            )
            .group_by(LedgerTransaction.occurred_at)
            .order_by(LedgerTransaction.occurred_at)
        )
        return [(occurred_at, int(delta)) for occurred_at, delta in rows]

    async def cycle_events(self, cycle_id: UUID) -> list[tuple[datetime, int]]:
        rows = await self.session.execute(
            select(LedgerTransaction.occurred_at, func.sum(-Posting.amount_minor))
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .where(
                LedgerTransaction.credit_cycle_id == cycle_id,
                LedgerTransaction.kind.in_(["credit_purchase", "repayment"]),
                LedgerTransaction.voided_at.is_(None),
                Posting.role.in_(["account", "destination"]),
                or_(
                    LedgerTransaction.kind == "repayment",
                    ~exists().where(InstallmentLedgerLink.transaction_id == LedgerTransaction.id),
                ),
            )
            .group_by(LedgerTransaction.occurred_at)
            .order_by(LedgerTransaction.occurred_at)
        )
        events = [(occurred_at, int(delta)) for occurred_at, delta in rows]
        allocation_rows = await self.session.execute(
            select(
                LedgerTransaction.occurred_at,
                func.sum(InstallmentPeriod.principal_minor),
            )
            .join(InstallmentPlan, InstallmentPlan.purchase_transaction_id == LedgerTransaction.id)
            .join(InstallmentPeriod, InstallmentPeriod.plan_id == InstallmentPlan.id)
            .where(
                InstallmentPeriod.effective_cycle_id == cycle_id,
                InstallmentPeriod.cancelled_at.is_(None),
            )
            .group_by(LedgerTransaction.occurred_at)
        )
        fee_rows = await self.session.execute(
            select(LedgerTransaction.occurred_at, func.sum(InstallmentPeriod.fee_minor))
            .join(InstallmentPlan, InstallmentPlan.fee_transaction_id == LedgerTransaction.id)
            .join(InstallmentPeriod, InstallmentPeriod.plan_id == InstallmentPlan.id)
            .where(
                InstallmentPeriod.effective_cycle_id == cycle_id,
                InstallmentPeriod.cancelled_at.is_(None),
            )
            .group_by(LedgerTransaction.occurred_at)
        )
        events.extend((occurred, int(amount)) for occurred, amount in allocation_rows)
        events.extend((occurred, int(amount)) for occurred, amount in fee_rows)
        return sorted(events, key=lambda item: item[0])

    async def cycle_has_any_transaction(self, cycle_id: UUID) -> bool:
        return (
            await self.session.scalar(
                select(LedgerTransaction.id)
                .where(LedgerTransaction.credit_cycle_id == cycle_id)
                .limit(1)
            )
            is not None
        )

    async def cycle_has_repayment(self, cycle_id: UUID) -> bool:
        return bool(
            await self.session.scalar(
                select(
                    exists().where(
                        LedgerTransaction.credit_cycle_id == cycle_id,
                        LedgerTransaction.kind == "repayment",
                        LedgerTransaction.voided_at.is_(None),
                    )
                )
            )
        )

    async def delete_cycle(self, cycle: CreditCycle) -> None:
        await self.session.delete(cycle)

    async def transactions_for_cycles(self, cycle_ids: list[UUID]) -> list[LedgerTransaction]:
        if not cycle_ids:
            return []
        return list(
            (
                await self.session.scalars(
                    select(LedgerTransaction).where(
                        LedgerTransaction.credit_cycle_id.in_(cycle_ids)
                    )
                )
            ).all()
        )

    async def periods_for_cycles(self, cycle_ids: list[UUID]) -> list[InstallmentPeriod]:
        if not cycle_ids:
            return []
        return list(
            (
                await self.session.scalars(
                    select(InstallmentPeriod).where(
                        or_(
                            InstallmentPeriod.scheduled_cycle_id.in_(cycle_ids),
                            InstallmentPeriod.effective_cycle_id.in_(cycle_ids),
                        )
                    )
                )
            ).all()
        )

    async def plans_for_start_cycles(self, cycle_ids: list[UUID]) -> list[InstallmentPlan]:
        if not cycle_ids:
            return []
        return list(
            (
                await self.session.scalars(
                    select(InstallmentPlan).where(InstallmentPlan.start_cycle_id.in_(cycle_ids))
                )
            ).all()
        )

    async def cycle_is_referenced(self, cycle_id: UUID) -> bool:
        transaction = await self.session.scalar(
            select(LedgerTransaction.id)
            .where(LedgerTransaction.credit_cycle_id == cycle_id)
            .limit(1)
        )
        if transaction is not None:
            return True
        period = await self.session.scalar(
            select(InstallmentPeriod.id)
            .where(
                or_(
                    InstallmentPeriod.scheduled_cycle_id == cycle_id,
                    InstallmentPeriod.effective_cycle_id == cycle_id,
                )
            )
            .limit(1)
        )
        if period is not None:
            return True
        return (
            await self.session.scalar(
                select(InstallmentPlan.id)
                .where(InstallmentPlan.start_cycle_id == cycle_id)
                .limit(1)
            )
            is not None
        )
