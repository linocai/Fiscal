from __future__ import annotations

from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models import Account, LedgerTransaction, Posting


class AccountRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list(self, *, include_archived: bool, for_update: bool = False) -> list[Account]:
        statement = select(Account)
        if not include_archived:
            statement = statement.where(Account.archived_at.is_(None))
        statement = statement.order_by(Account.sort_order, Account.created_at, Account.id)
        if for_update:
            statement = statement.with_for_update()
        return list((await self.session.scalars(statement)).all())

    async def get(self, account_id: UUID, *, for_update: bool = False) -> Account | None:
        statement = select(Account).where(Account.id == account_id)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def active_name_exists(self, name: str, *, excluding: UUID | None = None) -> bool:
        statement = select(Account.id).where(
            Account.archived_at.is_(None), func.lower(Account.name) == name.lower()
        )
        if excluding is not None:
            statement = statement.where(Account.id != excluding)
        return await self.session.scalar(statement.limit(1)) is not None

    async def next_sort_order(self) -> int:
        maximum = await self.session.scalar(
            select(func.coalesce(func.max(Account.sort_order), -1)).where(
                Account.archived_at.is_(None)
            )
        )
        return int(maximum or 0) + 1

    async def balance_impacts(self, account_ids: list[UUID]) -> dict[UUID, int]:
        if not account_ids:
            return {}
        rows = await self.session.execute(
            select(Posting.account_id, func.coalesce(func.sum(Posting.amount_minor), 0))
            .join(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
            .where(
                Posting.account_id.in_(account_ids),
                LedgerTransaction.voided_at.is_(None),
            )
            .group_by(Posting.account_id)
        )
        return {account_id: int(amount) for account_id, amount in rows.all()}

    def add(self, account: Account) -> None:
        self.session.add(account)

    async def delete(self, account: Account) -> None:
        await self.session.delete(account)
