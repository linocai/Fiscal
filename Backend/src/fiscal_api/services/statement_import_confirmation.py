from __future__ import annotations

import hashlib
import json
from uuid import UUID, uuid5

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p27_confirmation_schemas import (
    StatementImportConfirmationRowReceipt,
    StatementImportConfirmReceipt,
    StatementImportConfirmRequest,
)
from fiscal_api.core.time import utc_now
from fiscal_api.db.models.statement_import import StatementImport, StatementImportRow
from fiscal_api.db.models.statement_import_confirmation import (
    StatementImportConfirmationOperation,
    StatementImportFinalCreateDraft,
    StatementImportTransactionProvenance,
)
from fiscal_api.db.models.statement_import_review import StatementImportDraftResolution
from fiscal_api.services.common import acquire_mutation_lock, check_version, conflict, not_found
from fiscal_api.services.transactions import TransactionService


class StatementImportConfirmationService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def confirm(
        self, batch_id: UUID, request: StatementImportConfirmRequest, key: UUID
    ) -> StatementImportConfirmReceipt:
        payload_hash = hashlib.sha256(
            json.dumps(
                request.model_dump(mode="json"), sort_keys=True, separators=(",", ":")
            ).encode()
        ).hexdigest()
        await acquire_mutation_lock(self.session)
        prior = await self.session.scalar(
            select(StatementImportConfirmationOperation).where(
                StatementImportConfirmationOperation.idempotency_key == key
            )
        )
        if prior is not None:
            if prior.payload_hash != payload_hash or prior.statement_import_id != batch_id:
                conflict("idempotency_key_reused", "Idempotency key was reused")
            return StatementImportConfirmReceipt.model_validate({**prior.receipt, "replay": True})
        batch = await self.session.scalar(
            select(StatementImport).where(StatementImport.id == batch_id).with_for_update()
        )
        if batch is None:
            not_found("statement_import_not_found", "Statement import was not found")
        check_version(batch.version, request.expected_batch_version)
        rows = list(
            (
                await self.session.scalars(
                    select(StatementImportRow)
                    .where(
                        StatementImportRow.id.in_([item.row_id for item in request.rows]),
                        StatementImportRow.statement_import_id == batch.id,
                    )
                    .with_for_update()
                )
            ).all()
        )
        if len(rows) != len(request.rows):
            conflict("statement_import_confirmation_invalid", "Rows are unavailable")
        by_id = {row.id: row for row in rows}
        drafts: dict[UUID, StatementImportDraftResolution] = {}
        finals: dict[UUID, StatementImportFinalCreateDraft] = {}
        for selected in request.rows:
            row = by_id[selected.row_id]
            check_version(row.version, selected.expected_row_version)
            if row.confirmed_at is not None:
                conflict("statement_import_row_confirmed", "Confirmed rows are frozen")
            draft = await self.session.scalar(
                select(StatementImportDraftResolution)
                .where(StatementImportDraftResolution.statement_import_row_id == row.id)
                .with_for_update()
            )
            if draft is None or draft.resolution == "unresolved":
                conflict("statement_import_confirmation_invalid", "Row is unresolved")
            check_version(draft.version, selected.expected_draft_version)
            drafts[row.id] = draft
            if draft.resolution == "create_new":
                final = await self.session.scalar(
                    select(StatementImportFinalCreateDraft)
                    .where(StatementImportFinalCreateDraft.statement_import_row_id == row.id)
                    .with_for_update()
                )
                if final is None or selected.expected_final_create_draft_version is None:
                    conflict(
                        "statement_import_final_draft_missing", "Final create draft is required"
                    )
                check_version(final.version, selected.expected_final_create_draft_version)
                finals[row.id] = final
        op = StatementImportConfirmationOperation(
            statement_import_id=batch.id, idempotency_key=key, payload_hash=payload_hash, receipt={}
        )
        self.session.add(op)
        await self.session.flush()
        confirmed: list[UUID] = []
        row_results: list[StatementImportConfirmationRowReceipt] = []
        created_count = matched_count = skipped_count = 0
        transactions = TransactionService(self.session)
        for selected in request.rows:
            row, draft = by_id[selected.row_id], drafts[selected.row_id]
            transaction_id = draft.matched_transaction_id
            if draft.resolution == "create_new":
                created = await transactions.create_statement_import(
                    TransactionDraft.model_validate(finals[row.id].payload),
                    uuid5(key, str(row.id)),
                    commit=False,
                )
                transaction_id = created.id
                created_count += 1
            elif draft.resolution == "match_existing":
                matched_count += 1
            else:
                skipped_count += 1
            if transaction_id is not None:
                self.session.add(
                    StatementImportTransactionProvenance(
                        statement_import_id=batch.id,
                        statement_import_row_id=row.id,
                        confirmation_operation_id=op.id,
                        transaction_id=transaction_id,
                        resolution=draft.resolution,
                        draft_version=draft.version,
                    )
                )
            row.confirmed_at = utc_now()
            row.confirmation_operation_id = op.id
            row.version += 1
            confirmed.append(row.id)
            row_results.append(
                StatementImportConfirmationRowReceipt(
                    row_id=row.id,
                    resolution=draft.resolution,
                    outcome="applied" if transaction_id is not None else "skipped",
                    transaction_id=transaction_id,
                )
            )
        remaining = await self.session.scalar(
            select(StatementImportRow.id)
            .where(
                StatementImportRow.statement_import_id == batch.id,
                StatementImportRow.confirmed_at.is_(None),
            )
            .limit(1)
        )
        batch.status = "confirmed" if remaining is None else "partially_confirmed"
        if batch.status == "confirmed":
            batch.confirmed_at = utc_now()
        batch.version += 1
        receipt: dict[str, object] = {
            "operation_id": str(op.id),
            "batch_id": str(batch.id),
            "batch_version": batch.version,
            "status": batch.status,
            "confirmed_row_ids": [str(value) for value in confirmed],
            "row_results": [item.model_dump(mode="json") for item in row_results],
            "created_count": created_count,
            "matched_count": matched_count,
            "skipped_count": skipped_count,
            "result_detail_status": "complete",
            "replay": False,
        }
        op.receipt = receipt
        await self.session.commit()
        return StatementImportConfirmReceipt.model_validate(receipt)
