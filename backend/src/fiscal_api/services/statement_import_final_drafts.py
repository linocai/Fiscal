from __future__ import annotations

from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p27_confirmation_schemas import (
    StatementImportFinalCreateDraftPut,
    StatementImportFinalCreateDraftResponse,
)
from fiscal_api.db.models.account import Account
from fiscal_api.db.models.category import Category
from fiscal_api.db.models.statement_import import StatementImport, StatementImportRow
from fiscal_api.db.models.statement_import_confirmation import StatementImportFinalCreateDraft
from fiscal_api.db.models.statement_import_review import StatementImportDraftResolution
from fiscal_api.services.common import acquire_mutation_lock, check_version, conflict, not_found


class StatementImportFinalDraftService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get(self, batch_id: UUID, row_id: UUID) -> StatementImportFinalCreateDraftResponse:
        item = await self.session.scalar(
            select(StatementImportFinalCreateDraft).where(
                StatementImportFinalCreateDraft.statement_import_id == batch_id,
                StatementImportFinalCreateDraft.statement_import_row_id == row_id,
            )
        )
        if item is None:
            not_found("statement_import_final_draft_not_found", "Final create draft was not found")
        return self._response(item)

    async def put(
        self, batch_id: UUID, row_id: UUID, request: StatementImportFinalCreateDraftPut
    ) -> StatementImportFinalCreateDraftResponse:
        await acquire_mutation_lock(self.session)
        batch = await self.session.scalar(
            select(StatementImport).where(StatementImport.id == batch_id).with_for_update()
        )
        if batch is None:
            not_found("statement_import_not_found", "Statement import was not found")
        if batch.status not in {"review_required", "ready_to_confirm"}:
            conflict("statement_import_final_draft_invalid", "The import is not editable")
        row = await self.session.scalar(
            select(StatementImportRow)
            .where(
                StatementImportRow.id == row_id, StatementImportRow.statement_import_id == batch_id
            )
            .with_for_update()
        )
        if row is None:
            not_found("statement_import_row_not_found", "Statement import row was not found")
        resolution = await self.session.scalar(
            select(StatementImportDraftResolution)
            .where(StatementImportDraftResolution.statement_import_row_id == row.id)
            .with_for_update()
        )
        if resolution is None or resolution.resolution != "create_new":
            conflict(
                "statement_import_final_draft_invalid", "Row must have a create_new resolution"
            )
        item = await self.session.scalar(
            select(StatementImportFinalCreateDraft)
            .where(StatementImportFinalCreateDraft.statement_import_row_id == row.id)
            .with_for_update()
        )
        check_version(0 if item is None else item.version, request.expected_version)
        await self._references(request)
        payload = request.transaction.model_dump(mode="json")
        if item is None:
            item = StatementImportFinalCreateDraft(
                statement_import_id=batch.id,
                statement_import_row_id=row.id,
                draft_resolution_id=resolution.id,
                payload=payload,
            )
            self.session.add(item)
        else:
            item.payload, item.draft_resolution_id, item.version = (
                payload,
                resolution.id,
                item.version + 1,
            )
        await self.session.commit()
        return self._response(item)

    async def _references(self, request: StatementImportFinalCreateDraftPut) -> None:
        draft = request.transaction
        for value, model, label in (
            (draft.account_id, Account, "account"),
            (draft.destination_account_id, Account, "destination account"),
            (draft.category_id, Category, "category"),
        ):
            if value is None:
                continue
            item = await self.session.scalar(select(model).where(model.id == value))
            if item is None or item.archived_at is not None:
                conflict(
                    "statement_import_final_draft_reference_invalid", f"The {label} is unavailable"
                )
        if (
            draft.kind.value not in {"income", "expense", "credit_purchase"}
            and draft.category_id is None
        ):
            return

    @staticmethod
    def _response(item: StatementImportFinalCreateDraft) -> StatementImportFinalCreateDraftResponse:
        return StatementImportFinalCreateDraftResponse(
            id=item.id,
            statement_import_row_id=item.statement_import_row_id,
            draft_resolution_id=item.draft_resolution_id,
            transaction=TransactionDraft.model_validate(item.payload),
            version=item.version,
        )
