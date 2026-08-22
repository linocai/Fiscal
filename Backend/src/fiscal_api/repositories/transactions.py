from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import Select, and_, delete, exists, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from fiscal_api.api.p10_schemas import TransactionClassification
from fiscal_api.db.models import (
    Account,
    Category,
    LedgerTransaction,
    Posting,
    TransactionKind,
    TransactionRevision,
    TransactionSource,
)


class TransactionRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get(
        self,
        transaction_id: UUID,
        *,
        for_update: bool = False,
    ) -> LedgerTransaction | None:
        statement = (
            select(LedgerTransaction)
            .where(LedgerTransaction.id == transaction_id)
            .options(selectinload(LedgerTransaction.postings))
        )
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def get_by_idempotency_key(self, key: UUID) -> LedgerTransaction | None:
        return await self.session.scalar(
            select(LedgerTransaction)
            .where(LedgerTransaction.idempotency_key == key)
            .options(selectinload(LedgerTransaction.postings))
        )

    async def created_snapshot(self, transaction_id: UUID) -> dict[str, object] | None:
        return await self.session.scalar(
            select(TransactionRevision.snapshot).where(
                TransactionRevision.transaction_id == transaction_id,
                TransactionRevision.version == 1,
            )
        )

    async def list_page(
        self,
        *,
        limit: int,
        kind: TransactionKind | None,
        account_id: UUID | None,
        category_id: UUID | None,
        occurred_from: datetime | None,
        occurred_to_exclusive: datetime | None,
        query: str | None,
        classification: TransactionClassification,
        source: TransactionSource | None,
        amount_min_minor: int | None,
        amount_max_minor: int | None,
        include_voided: bool,
        cursor_occurred_at: datetime | None,
        cursor_id: UUID | None,
    ) -> list[LedgerTransaction]:
        statement = self._filtered_statement(
            kind=kind,
            account_id=account_id,
            category_id=category_id,
            occurred_from=occurred_from,
            occurred_to_exclusive=occurred_to_exclusive,
            query=query,
            classification=classification,
            source=source,
            amount_min_minor=amount_min_minor,
            amount_max_minor=amount_max_minor,
            include_voided=include_voided,
        ).options(selectinload(LedgerTransaction.postings))
        if cursor_occurred_at is not None and cursor_id is not None:
            statement = statement.where(
                or_(
                    LedgerTransaction.occurred_at < cursor_occurred_at,
                    and_(
                        LedgerTransaction.occurred_at == cursor_occurred_at,
                        LedgerTransaction.id < cursor_id,
                    ),
                )
            )
        statement = statement.order_by(
            LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc()
        ).limit(limit + 1)
        return list((await self.session.scalars(statement)).all())

    async def list_export(
        self,
        *,
        limit: int,
        kind: TransactionKind | None,
        account_id: UUID | None,
        category_id: UUID | None,
        occurred_from: datetime | None,
        occurred_to_exclusive: datetime | None,
        query: str | None,
        classification: TransactionClassification,
        source: TransactionSource | None,
        amount_min_minor: int | None,
        amount_max_minor: int | None,
        include_voided: bool,
    ) -> list[LedgerTransaction]:
        statement = self._filtered_statement(
            kind=kind,
            account_id=account_id,
            category_id=category_id,
            occurred_from=occurred_from,
            occurred_to_exclusive=occurred_to_exclusive,
            query=query,
            classification=classification,
            source=source,
            amount_min_minor=amount_min_minor,
            amount_max_minor=amount_max_minor,
            include_voided=include_voided,
        ).options(selectinload(LedgerTransaction.postings))
        statement = statement.order_by(
            LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc()
        ).limit(limit)
        return list((await self.session.scalars(statement)).all())

    @staticmethod
    def _filtered_statement(
        *,
        kind: TransactionKind | None,
        account_id: UUID | None,
        category_id: UUID | None,
        occurred_from: datetime | None,
        occurred_to_exclusive: datetime | None,
        query: str | None,
        classification: TransactionClassification,
        source: TransactionSource | None,
        amount_min_minor: int | None,
        amount_max_minor: int | None,
        include_voided: bool,
    ) -> Select[tuple[LedgerTransaction]]:
        statement: Select[tuple[LedgerTransaction]] = select(LedgerTransaction)
        if not include_voided:
            statement = statement.where(LedgerTransaction.voided_at.is_(None))
        if kind is not None:
            statement = statement.where(LedgerTransaction.kind == kind.value)
        if category_id is not None:
            statement = statement.where(LedgerTransaction.category_id == category_id)
        if classification is TransactionClassification.CATEGORIZED:
            statement = statement.where(LedgerTransaction.category_id.is_not(None))
        elif classification is TransactionClassification.UNCATEGORIZED:
            statement = statement.where(
                LedgerTransaction.category_id.is_(None),
                LedgerTransaction.kind.in_(["income", "expense", "credit_purchase"]),
                LedgerTransaction.voided_at.is_(None),
            )
        if source is not None:
            statement = statement.where(LedgerTransaction.source == source.value)
        if account_id is not None:
            statement = statement.where(
                exists(
                    select(Posting.id).where(
                        Posting.transaction_id == LedgerTransaction.id,
                        Posting.account_id == account_id,
                    )
                )
            )
        if occurred_from is not None:
            statement = statement.where(LedgerTransaction.occurred_at >= occurred_from)
        if occurred_to_exclusive is not None:
            statement = statement.where(LedgerTransaction.occurred_at < occurred_to_exclusive)
        if query:
            escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            pattern = f"%{escaped}%"
            statement = statement.where(
                or_(
                    LedgerTransaction.title.ilike(pattern, escape="\\"),
                    LedgerTransaction.note.ilike(pattern, escape="\\"),
                    exists(
                        select(Category.id).where(
                            Category.id == LedgerTransaction.category_id,
                            Category.name.ilike(pattern, escape="\\"),
                        )
                    ),
                    exists(
                        select(Posting.id)
                        .join(Account, Account.id == Posting.account_id)
                        .where(
                            Posting.transaction_id == LedgerTransaction.id,
                            Account.name.ilike(pattern, escape="\\"),
                        )
                    ),
                )
            )
        if amount_min_minor is not None or amount_max_minor is not None:
            amount_conditions = [
                Posting.transaction_id == LedgerTransaction.id,
                Posting.position == 0,
            ]
            if amount_min_minor is not None:
                amount_conditions.append(func.abs(Posting.amount_minor) >= amount_min_minor)
            if amount_max_minor is not None:
                amount_conditions.append(func.abs(Posting.amount_minor) <= amount_max_minor)
            statement = statement.where(exists(select(Posting.id).where(*amount_conditions)))
        return statement

    async def get_many_for_update(self, transaction_ids: list[UUID]) -> list[LedgerTransaction]:
        statement = (
            select(LedgerTransaction)
            .where(LedgerTransaction.id.in_(transaction_ids))
            .order_by(LedgerTransaction.id)
            .options(selectinload(LedgerTransaction.postings))
            .with_for_update()
        )
        return list((await self.session.scalars(statement)).all())

    async def accounts_by_ids(self, account_ids: set[UUID]) -> dict[UUID, Account]:
        if not account_ids:
            return {}
        rows = await self.session.scalars(select(Account).where(Account.id.in_(account_ids)))
        return {item.id: item for item in rows.all()}

    async def categories_by_ids(self, category_ids: set[UUID]) -> dict[UUID, Category]:
        if not category_ids:
            return {}
        rows = await self.session.scalars(select(Category).where(Category.id.in_(category_ids)))
        return {item.id: item for item in rows.all()}

    async def replace_postings(
        self,
        transaction_id: UUID,
        postings: list[Posting],
    ) -> None:
        await self.session.execute(delete(Posting).where(Posting.transaction_id == transaction_id))
        await self.session.flush()
        self.session.add_all(postings)

    async def list_cycle_page(
        self,
        cycle_id: UUID,
        *,
        limit: int,
        cursor_occurred_at: datetime | None,
        cursor_id: UUID | None,
    ) -> list[LedgerTransaction]:
        statement = (
            select(LedgerTransaction)
            .where(
                LedgerTransaction.credit_cycle_id == cycle_id,
                LedgerTransaction.voided_at.is_(None),
            )
            .options(selectinload(LedgerTransaction.postings))
        )
        if cursor_occurred_at is not None and cursor_id is not None:
            statement = statement.where(
                or_(
                    LedgerTransaction.occurred_at < cursor_occurred_at,
                    and_(
                        LedgerTransaction.occurred_at == cursor_occurred_at,
                        LedgerTransaction.id < cursor_id,
                    ),
                )
            )
        statement = statement.order_by(
            LedgerTransaction.occurred_at.desc(), LedgerTransaction.id.desc()
        ).limit(limit + 1)
        return list((await self.session.scalars(statement)).all())

    async def account(self, account_id: UUID) -> Account | None:
        return await self.session.get(Account, account_id)

    async def category(self, category_id: UUID) -> Category | None:
        return await self.session.get(Category, category_id)

    def add(self, transaction: LedgerTransaction) -> None:
        self.session.add(transaction)

    def add_revision(self, revision: TransactionRevision) -> None:
        self.session.add(revision)

    async def adjust_account_usage(self, account_id: UUID, delta: int) -> None:
        await self.session.execute(
            update(Account)
            .where(Account.id == account_id)
            .values(usage_count=Account.usage_count + delta)
        )

    async def adjust_category_usage(self, category_id: UUID, delta: int) -> None:
        await self.session.execute(
            update(Category)
            .where(Category.id == category_id)
            .values(usage_count=Category.usage_count + delta)
        )

    async def reassign_category(self, source_id: UUID, target_id: UUID) -> int:
        result = await self.session.execute(
            update(LedgerTransaction)
            .where(LedgerTransaction.category_id == source_id)
            .values(category_id=target_id)
        )
        return int(result.rowcount)  # type: ignore[attr-defined]

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

    async def summary(
        self,
        *,
        occurred_from: datetime | None,
        occurred_to_exclusive: datetime | None,
    ) -> list[tuple[str, UUID, str, int]]:
        statement = (
            select(
                LedgerTransaction.kind,
                LedgerTransaction.category_id,
                Category.name,
                func.sum(Posting.amount_minor),
            )
            .join(Posting, Posting.transaction_id == LedgerTransaction.id)
            .join(Category, Category.id == LedgerTransaction.category_id)
            .where(
                LedgerTransaction.voided_at.is_(None),
                LedgerTransaction.kind.in_(
                    [
                        "income",
                        "expense",
                        "credit_purchase",
                        "installment_fee",
                        "installment_refund",
                    ]
                ),
            )
            .group_by(LedgerTransaction.kind, LedgerTransaction.category_id, Category.name)
        )
        if occurred_from is not None:
            statement = statement.where(LedgerTransaction.occurred_at >= occurred_from)
        if occurred_to_exclusive is not None:
            statement = statement.where(LedgerTransaction.occurred_at < occurred_to_exclusive)
        rows = await self.session.execute(statement)
        return [
            (kind, category_id, category_name, int(amount))
            for kind, category_id, category_name, amount in rows.all()
        ]
