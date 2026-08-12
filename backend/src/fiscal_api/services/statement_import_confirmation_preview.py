from __future__ import annotations

from collections import Counter
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p27_confirmation_schemas import (
    StatementImportConfirmationRow,
    StatementImportConfirmReceipt,
    StatementImportConfirmRequest,
)
from fiscal_api.api.p28_schemas import (
    StatementImportConfirmationPreviewAmounts,
    StatementImportConfirmationPreviewCheck,
    StatementImportConfirmationPreviewCounts,
    StatementImportConfirmationPreviewRequest,
    StatementImportConfirmationPreviewResponse,
    StatementImportConfirmationPreviewRow,
)
from fiscal_api.db.models.statement_import import StatementImport, StatementImportRow
from fiscal_api.db.models.statement_import_confirmation import (
    StatementImportConfirmationOperation,
    StatementImportFinalCreateDraft,
)
from fiscal_api.db.models.statement_import_review import (
    StatementImportDraftResolution,
    StatementImportReviewCandidate,
    StatementImportValidationCheck,
    StatementImportValidationRun,
)
from fiscal_api.services.common import conflict, not_found


class StatementImportConfirmationPreviewService:
    """Read-only, locked confirmation preparation for the P28-C sheet."""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def preview(
        self, batch_id: UUID, request: StatementImportConfirmationPreviewRequest
    ) -> StatementImportConfirmationPreviewResponse:
        if len(set(request.row_ids)) != len(request.row_ids):
            conflict("statement_import_confirmation_invalid", "Rows must be unique")
        batch = await self.session.scalar(
            select(StatementImport).where(StatementImport.id == batch_id).with_for_update()
        )
        if batch is None:
            not_found("statement_import_not_found", "Statement import was not found")
        run = await self.session.scalar(
            select(StatementImportValidationRun)
            .where(StatementImportValidationRun.statement_import_id == batch.id)
            .order_by(StatementImportValidationRun.created_at.desc())
            .limit(1)
        )
        if run is None:
            conflict("statement_import_confirmation_invalid", "Review is not available")
        rows = list(
            (
                await self.session.scalars(
                    select(StatementImportRow)
                    .where(
                        StatementImportRow.statement_import_id == batch.id,
                        StatementImportRow.id.in_(request.row_ids),
                    )
                    .with_for_update()
                )
            ).all()
        )
        if len(rows) != len(request.row_ids):
            conflict("statement_import_confirmation_invalid", "Rows are unavailable")
        selected_rows = sorted(rows, key=lambda row: row.row_number)
        canonical_rows: list[StatementImportConfirmationRow] = []
        preview_rows: list[StatementImportConfirmationPreviewRow] = []
        counts: Counter[str] = Counter()
        known_create_minor = 0
        known_match_minor = 0
        unknown_selected_count = 0
        for row in selected_rows:
            if row.confirmed_at is not None:
                conflict("statement_import_row_confirmed", "Confirmed rows are frozen")
            draft = await self.session.scalar(
                select(StatementImportDraftResolution)
                .where(StatementImportDraftResolution.statement_import_row_id == row.id)
                .with_for_update()
            )
            if draft is None or draft.resolution == "unresolved":
                conflict("statement_import_confirmation_invalid", "Row is unresolved")
            final: StatementImportFinalCreateDraft | None = None
            if draft.resolution == "create_new":
                final = await self.session.scalar(
                    select(StatementImportFinalCreateDraft)
                    .where(StatementImportFinalCreateDraft.statement_import_row_id == row.id)
                    .with_for_update()
                )
                if final is None:
                    conflict(
                        "statement_import_final_draft_missing", "Final create draft is required"
                    )
                known_create_minor += TransactionDraft.model_validate(final.payload).amount_minor
            elif draft.resolution == "match_existing":
                amount_minor = await self.session.scalar(
                    select(StatementImportReviewCandidate.amount_minor).where(
                        StatementImportReviewCandidate.validation_run_id == run.id,
                        StatementImportReviewCandidate.statement_import_row_id == row.id,
                        StatementImportReviewCandidate.transaction_id
                        == draft.matched_transaction_id,
                    )
                )
                if amount_minor is None:
                    unknown_selected_count += 1
                else:
                    known_match_minor += amount_minor
            else:
                unknown_selected_count += 1
            counts[draft.resolution] += 1
            canonical_rows.append(
                StatementImportConfirmationRow(
                    row_id=row.id,
                    expected_row_version=row.version,
                    expected_draft_version=draft.version,
                    expected_final_create_draft_version=final.version if final else None,
                )
            )
            preview_rows.append(
                StatementImportConfirmationPreviewRow.model_validate(
                    {
                        "row_id": row.id,
                        "expected_row_version": row.version,
                        "expected_draft_version": draft.version,
                        "expected_final_create_draft_version": final.version if final else None,
                        "resolution": draft.resolution,
                        "is_confirmed": False,
                    }
                )
            )
        batch_unresolved = await self._unresolved_count(batch.id)
        checks = await self._checks(run.id)
        warnings = self._warnings(batch.status, checks, batch_unresolved)
        return StatementImportConfirmationPreviewResponse(
            batch_id=batch.id,
            batch_version=batch.version,
            status=batch.status,
            selected_rows=preview_rows,
            counts=StatementImportConfirmationPreviewCounts(
                selected=len(preview_rows),
                create_new=counts["create_new"],
                match_existing=counts["match_existing"],
                ignore_non_transaction=counts["ignore_non_transaction"],
                ignore_intentional=counts["ignore_intentional"],
                unresolved=counts["unresolved"],
                batch_unresolved=batch_unresolved,
            ),
            amounts=StatementImportConfirmationPreviewAmounts(
                known_create_minor=known_create_minor,
                known_match_minor=known_match_minor,
                known_total_minor=known_create_minor + known_match_minor,
                unknown_selected_count=unknown_selected_count,
            ),
            checks=checks,
            warnings=warnings,
            request=StatementImportConfirmRequest(
                expected_batch_version=batch.version, rows=canonical_rows
            ),
        )

    async def receipt(self, batch_id: UUID, key: UUID) -> StatementImportConfirmReceipt:
        operation = await self.session.scalar(
            select(StatementImportConfirmationOperation).where(
                StatementImportConfirmationOperation.statement_import_id == batch_id,
                StatementImportConfirmationOperation.idempotency_key == key,
            )
        )
        if operation is None or not operation.receipt:
            not_found(
                "statement_import_confirmation_receipt_not_found",
                "No persisted confirmation receipt was found",
            )
        return StatementImportConfirmReceipt.model_validate({**operation.receipt, "replay": True})

    async def _unresolved_count(self, batch_id: UUID) -> int:
        rows = list(
            (
                await self.session.scalars(
                    select(StatementImportRow).where(
                        StatementImportRow.statement_import_id == batch_id,
                        StatementImportRow.confirmed_at.is_(None),
                    )
                )
            ).all()
        )
        result = 0
        for row in rows:
            draft = await self.session.scalar(
                select(StatementImportDraftResolution.resolution).where(
                    StatementImportDraftResolution.statement_import_row_id == row.id
                )
            )
            if draft is None or draft == "unresolved":
                result += 1
        return result

    async def _checks(self, run_id: UUID) -> list[StatementImportConfirmationPreviewCheck]:
        items = list(
            (
                await self.session.scalars(
                    select(StatementImportValidationCheck)
                    .where(StatementImportValidationCheck.validation_run_id == run_id)
                    .order_by(StatementImportValidationCheck.check_kind)
                )
            ).all()
        )
        return [
            StatementImportConfirmationPreviewCheck.model_validate(
                {"check_kind": item.check_kind, "status": item.status}
            )
            for item in items
        ]

    @staticmethod
    def _warnings(
        batch_status: str,
        checks: list[StatementImportConfirmationPreviewCheck],
        batch_unresolved: int,
    ) -> list[str]:
        warnings: list[str] = []
        if batch_status == "partially_confirmed":
            warnings.append("batch_partially_confirmed")
        if batch_status == "confirmed":
            warnings.append("batch_confirmed")
        if batch_unresolved:
            warnings.append("batch_unresolved_rows_remain")
        statuses = {item.status for item in checks}
        if "failed" in statuses:
            warnings.append("failed_checks_present")
        if "unavailable" in statuses:
            warnings.append("unavailable_checks_present")
        return warnings
