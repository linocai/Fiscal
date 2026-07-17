from datetime import date
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from fiscal_api.db.models import CashFlowItem, CashFlowItemRevision, CashFlowSeries


class CashFlowRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    def add_item(self, item: CashFlowItem) -> None:
        self.session.add(item)

    def add_series(self, series: CashFlowSeries) -> None:
        self.session.add(series)

    def add_revision(self, revision: CashFlowItemRevision) -> None:
        self.session.add(revision)

    async def get(self, item_id: UUID, *, for_update: bool = False) -> CashFlowItem | None:
        statement = (
            select(CashFlowItem)
            .where(CashFlowItem.id == item_id)
            .options(selectinload(CashFlowItem.revisions))
        )
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def by_idempotency_key(self, key: UUID) -> CashFlowItem | None:
        return await self.session.scalar(
            select(CashFlowItem).where(CashFlowItem.idempotency_key == key)
        )

    async def series_by_idempotency_key(self, key: UUID) -> CashFlowSeries | None:
        return await self.session.scalar(
            select(CashFlowSeries)
            .where(CashFlowSeries.idempotency_key == key)
            .options(selectinload(CashFlowSeries.items))
        )

    async def active(self, account_id: UUID | None = None) -> list[CashFlowItem]:
        statement = select(CashFlowItem).where(CashFlowItem.status.in_(["expected", "confirmed"]))
        if account_id is not None:
            statement = statement.where(
                (CashFlowItem.account_id == account_id)
                | (CashFlowItem.destination_account_id == account_id)
            )
        statement = statement.order_by(CashFlowItem.expected_date, CashFlowItem.id)
        return list((await self.session.scalars(statement)).all())

    async def history(self, start: date, end_exclusive: date) -> list[CashFlowItem]:
        return list(
            (
                await self.session.scalars(
                    select(CashFlowItem)
                    .where(
                        CashFlowItem.status.in_(["settled", "cancelled"]),
                        CashFlowItem.expected_date >= start,
                        CashFlowItem.expected_date < end_exclusive,
                    )
                    .order_by(CashFlowItem.expected_date.desc(), CashFlowItem.id.desc())
                )
            ).all()
        )

    async def series_items_from(
        self, series_id: UUID, expected_date: date, *, for_update: bool = False
    ) -> list[CashFlowItem]:
        statement = (
            select(CashFlowItem)
            .where(
                CashFlowItem.series_id == series_id,
                CashFlowItem.expected_date >= expected_date,
            )
            .order_by(CashFlowItem.expected_date, CashFlowItem.id)
        )
        if for_update:
            statement = statement.with_for_update()
        return list((await self.session.scalars(statement)).all())

    async def by_linked_transaction(
        self, transaction_id: UUID, *, for_update: bool = False
    ) -> CashFlowItem | None:
        statement = select(CashFlowItem).where(CashFlowItem.linked_transaction_id == transaction_id)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)
