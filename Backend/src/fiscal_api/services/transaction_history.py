from __future__ import annotations

from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p31_schemas import (
    TransactionProvenanceLink,
    TransactionProvenanceResponse,
    TransactionRevisionPage,
    TransactionRevisionResponse,
)
from fiscal_api.db.models import (
    CashFlowItem,
    LedgerTransaction,
    StatementImportTransactionProvenance,
    TransactionMerchantMapping,
    TransactionRevision,
)
from fiscal_api.services.common import not_found


class TransactionHistoryService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def revisions(
        self, transaction_id: UUID, *, cursor: int | None, limit: int
    ) -> TransactionRevisionPage:
        await self._transaction(transaction_id)
        statement = select(TransactionRevision).where(
            TransactionRevision.transaction_id == transaction_id
        )
        if cursor is not None:
            statement = statement.where(TransactionRevision.version < cursor)
        rows = list(
            (
                await self.session.scalars(
                    statement.order_by(TransactionRevision.version.desc()).limit(limit + 1)
                )
            ).all()
        )
        items = [
            TransactionRevisionResponse(
                id=row.id,
                version=row.version,
                event=row.event,
                snapshot=self._safe_snapshot(row.snapshot),
                created_at=row.created_at,
            )
            for row in rows[:limit]
        ]
        return TransactionRevisionPage(
            items=items,
            next_cursor=str(items[-1].version) if len(rows) > limit and items else None,
        )

    async def provenance(self, transaction_id: UUID) -> TransactionProvenanceResponse:
        transaction = await self._transaction(transaction_id)
        links = [
            TransactionProvenanceLink(
                source_type=transaction.source,
                target_type="transaction_source",
                target_id=None,
                deep_link=None,
                recorded_at=transaction.created_at,
            )
        ]
        statement_links = list(
            (
                await self.session.scalars(
                    select(StatementImportTransactionProvenance).where(
                        StatementImportTransactionProvenance.transaction_id == transaction_id
                    )
                )
            ).all()
        )
        links.extend(
            TransactionProvenanceLink(
                source_type="statement_import_confirmation",
                target_type="statement_import",
                target_id=item.statement_import_id,
                deep_link=f"fiscal://statement-imports/{item.statement_import_id}",
                recorded_at=item.created_at,
            )
            for item in statement_links
        )
        cash_flow_items = list(
            (
                await self.session.scalars(
                    select(CashFlowItem).where(CashFlowItem.linked_transaction_id == transaction_id)
                )
            ).all()
        )
        links.extend(
            TransactionProvenanceLink(
                source_type="cash_flow",
                target_type="cash_flow_item",
                target_id=item.id,
                deep_link=f"fiscal://cash-flow/items/{item.id}",
                recorded_at=item.created_at,
            )
            for item in cash_flow_items
        )
        merchant_mapping = await self.session.scalar(
            select(TransactionMerchantMapping).where(
                TransactionMerchantMapping.transaction_id == transaction_id
            )
        )
        if merchant_mapping is not None:
            links.append(
                TransactionProvenanceLink(
                    source_type="merchant_mapping",
                    target_type="merchant",
                    target_id=merchant_mapping.merchant_id,
                    deep_link=f"fiscal://merchants/{merchant_mapping.merchant_id}",
                    recorded_at=merchant_mapping.confirmed_at,
                )
            )
        links.sort(key=lambda link: (link.recorded_at, str(link.target_id or "")))
        return TransactionProvenanceResponse(
            transaction_id=transaction_id,
            source=transaction.source,
            links=links,
        )

    async def _transaction(self, transaction_id: UUID) -> LedgerTransaction:
        transaction = await self.session.get(LedgerTransaction, transaction_id)
        if transaction is None:
            not_found("transaction_not_found", "The transaction does not exist")
        return transaction

    @staticmethod
    def _safe_snapshot(snapshot: dict[str, object]) -> dict[str, object]:
        # Revisions were built from TransactionResponse.  Keep that shared ledger
        # history, but never allow future internal/raw additions to become a read API.
        allowed = {
            "id",
            "kind",
            "amount_minor",
            "occurred_at",
            "business_date",
            "title",
            "note",
            "category_id",
            "account_id",
            "destination_account_id",
            "credit_cycle_id",
            "source",
            "postings",
            "version",
            "voided_at",
            "created_at",
            "updated_at",
            "available_actions",
        }
        return {key: value for key, value in snapshot.items() if key in allowed}
