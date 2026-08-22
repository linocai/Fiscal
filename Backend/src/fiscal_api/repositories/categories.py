from __future__ import annotations

from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models import Category, CategoryDirection, LedgerTransaction, Posting


class CategoryRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list(
        self,
        *,
        direction: CategoryDirection | None,
        include_archived: bool,
    ) -> list[Category]:
        statement = select(Category)
        if direction is not None:
            statement = statement.where(Category.direction == direction.value)
        if not include_archived:
            statement = statement.where(Category.archived_at.is_(None))
        statement = statement.order_by(Category.sort_order, Category.created_at, Category.id)
        return list((await self.session.scalars(statement)).all())

    async def get(self, category_id: UUID, *, for_update: bool = False) -> Category | None:
        statement = select(Category).where(Category.id == category_id)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def children(self, parent_id: UUID, *, active_only: bool = False) -> list[Category]:
        statement = select(Category).where(Category.parent_id == parent_id)
        if active_only:
            statement = statement.where(Category.archived_at.is_(None))
        statement = statement.order_by(Category.sort_order, Category.created_at, Category.id)
        return list((await self.session.scalars(statement)).all())

    async def active_sibling_name_exists(
        self,
        name: str,
        *,
        parent_id: UUID | None,
        excluding: UUID | None = None,
    ) -> bool:
        statement = select(Category.id).where(
            Category.archived_at.is_(None),
            Category.parent_id == parent_id,
            func.lower(Category.name) == name.lower(),
        )
        if excluding is not None:
            statement = statement.where(Category.id != excluding)
        return await self.session.scalar(statement.limit(1)) is not None

    async def active_siblings(
        self,
        *,
        parent_id: UUID | None,
        direction: CategoryDirection,
    ) -> list[Category]:
        statement = (
            select(Category)
            .where(
                Category.archived_at.is_(None),
                Category.parent_id == parent_id,
                Category.direction == direction.value,
            )
            .order_by(Category.sort_order, Category.created_at, Category.id)
            .with_for_update()
        )
        return list((await self.session.scalars(statement)).all())

    async def next_sort_order(
        self,
        parent_id: UUID | None,
        direction: CategoryDirection,
    ) -> int:
        maximum = await self.session.scalar(
            select(func.coalesce(func.max(Category.sort_order), -1)).where(
                Category.parent_id == parent_id,
                Category.direction == direction.value,
                Category.archived_at.is_(None),
            )
        )
        return int(maximum or 0) + 1

    async def category_transaction_ids(self, category_id: UUID) -> list[UUID]:
        return list(
            (
                await self.session.scalars(
                    select(LedgerTransaction.id)
                    .where(LedgerTransaction.category_id == category_id)
                    .order_by(LedgerTransaction.id)
                )
            ).all()
        )

    async def dependency(self, category_id: UUID) -> tuple[int, int]:
        row = (
            await self.session.execute(
                select(
                    func.count(LedgerTransaction.id),
                    func.coalesce(func.sum(func.abs(Posting.amount_minor)), 0),
                )
                .outerjoin(
                    Posting,
                    (Posting.transaction_id == LedgerTransaction.id) & (Posting.position == 0),
                )
                .where(LedgerTransaction.category_id == category_id)
            )
        ).one()
        return int(row[0] or 0), int(row[1] or 0)

    def add(self, category: Category) -> None:
        self.session.add(category)

    async def delete(self, category: Category) -> None:
        await self.session.delete(category)
