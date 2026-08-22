from __future__ import annotations

from uuid import UUID

from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models import (
    Merchant,
    MerchantIdentifier,
    MerchantOperation,
    TransactionMerchantMapping,
)


class MerchantRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def merchant(self, merchant_id: UUID, *, for_update: bool = False) -> Merchant | None:
        statement = select(Merchant).where(Merchant.id == merchant_id)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def merchants_page(
        self,
        *,
        include_archived: bool,
        query_key: str | None,
        after_key: str | None,
        after_id: UUID | None,
        limit: int,
    ) -> list[Merchant]:
        canonical = MerchantIdentifier
        statement = select(Merchant).join(
            canonical,
            and_(canonical.merchant_id == Merchant.id, canonical.kind == "canonical"),
        )
        if not include_archived:
            statement = statement.where(Merchant.archived_at.is_(None))
        if query_key:
            statement = statement.where(
                canonical.normalized_key.contains(query_key, autoescape=True)
            )
        if after_key is not None and after_id is not None:
            statement = statement.where(
                or_(
                    canonical.normalized_key > after_key,
                    and_(canonical.normalized_key == after_key, Merchant.id > after_id),
                )
            )
        statement = statement.order_by(canonical.normalized_key, Merchant.id).limit(limit)
        return list((await self.session.scalars(statement)).all())

    async def identifiers(self, merchant_id: UUID) -> list[MerchantIdentifier]:
        statement = select(MerchantIdentifier).where(MerchantIdentifier.merchant_id == merchant_id)
        statement = statement.order_by(
            MerchantIdentifier.kind, MerchantIdentifier.display_value, MerchantIdentifier.id
        )
        return list((await self.session.scalars(statement)).all())

    async def aliases_for_merchants(self, merchant_ids: list[UUID]) -> dict[UUID, list[str]]:
        if not merchant_ids:
            return {}
        rows = list(
            (
                await self.session.scalars(
                    select(MerchantIdentifier)
                    .where(
                        MerchantIdentifier.merchant_id.in_(merchant_ids),
                        MerchantIdentifier.kind == "alias",
                    )
                    .order_by(
                        MerchantIdentifier.merchant_id,
                        MerchantIdentifier.display_value,
                        MerchantIdentifier.id,
                    )
                )
            ).all()
        )
        result: dict[UUID, list[str]] = {merchant_id: [] for merchant_id in merchant_ids}
        for row in rows:
            result.setdefault(row.merchant_id, []).append(row.display_value)
        return result

    async def mapping(
        self, transaction_id: UUID, *, for_update: bool = False
    ) -> TransactionMerchantMapping | None:
        statement = select(TransactionMerchantMapping).where(
            TransactionMerchantMapping.transaction_id == transaction_id
        )
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def operation(self, idempotency_key: UUID) -> MerchantOperation | None:
        return await self.session.scalar(
            select(MerchantOperation).where(MerchantOperation.idempotency_key == idempotency_key)
        )

    def add(self, item: object) -> None:
        self.session.add(item)

    async def replace_identifiers(
        self, merchant: Merchant, *, name_key: str, aliases: list[tuple[str, str]]
    ) -> None:
        existing = await self.identifiers(merchant.id)
        for identifier in existing:
            await self.session.delete(identifier)
        # Flush deletion first: an alias may become the canonical name (or vice versa).
        await self.session.flush()
        self.session.add(
            MerchantIdentifier(
                merchant_id=merchant.id,
                normalized_key=name_key,
                display_value=merchant.name,
                kind="canonical",
            )
        )
        self.session.add_all(
            [
                MerchantIdentifier(
                    merchant_id=merchant.id,
                    normalized_key=key,
                    display_value=value,
                    kind="alias",
                )
                for key, value in aliases
            ]
        )
