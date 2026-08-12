from __future__ import annotations

from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p28_schemas import (
    StatementImportWorkbenchCandidate,
    StatementImportWorkbenchCheck,
    StatementImportWorkbenchDraft,
    StatementImportWorkbenchFilters,
    StatementImportWorkbenchPageResponse,
    StatementImportWorkbenchResponse,
    StatementImportWorkbenchRow,
)
from fiscal_api.db.models.statement_import import (
    StatementImport,
    StatementImportPage,
    StatementImportRow,
)
from fiscal_api.db.models.statement_import_confirmation import StatementImportFinalCreateDraft
from fiscal_api.db.models.statement_import_review import (
    StatementImportDraftResolution,
    StatementImportReviewCandidate,
    StatementImportValidationCheck,
    StatementImportValidationRun,
)
from fiscal_api.services.common import not_found


class StatementImportWorkbenchService:
    """Read-only projection for P28-B. It deliberately exposes stored masked evidence only."""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get(
        self, batch_id: UUID, *, cursor: int, limit: int, filters: StatementImportWorkbenchFilters
    ) -> StatementImportWorkbenchResponse:
        batch = await self._batch(batch_id)
        run = await self._run(batch.id)
        checks = await self._checks(run.id) if run else []
        rows = list(
            (
                await self.session.scalars(
                    select(StatementImportRow)
                    .where(
                        StatementImportRow.statement_import_id == batch.id,
                        StatementImportRow.row_number > cursor,
                    )
                    .order_by(StatementImportRow.row_number)
                )
            ).all()
        )
        projection = [await self._row(item, run.id if run else None) for item in rows]
        projection = [item for item in projection if self._matches(item, checks, filters)]
        selected = projection[:limit]
        # A filtered short page must not claim completion while more source rows remain.
        next_cursor = selected[-1].row_number if len(rows) > len(selected) else None
        unavailable = sum(
            1
            for item in projection
            if item.source_kind is None or item.evidence_text_masked is None
        )
        return StatementImportWorkbenchResponse(
            batch_id=batch.id,
            batch_version=batch.version,
            status=batch.status,
            review_available=run is not None,
            validation_run_id=run.id if run else None,
            checks=checks,
            rows=selected,
            next_cursor=next_cursor,
            source_unavailable_count=unavailable,
        )

    async def page(self, batch_id: UUID, page_number: int) -> StatementImportWorkbenchPageResponse:
        batch = await self._batch(batch_id)
        page = await self.session.scalar(
            select(StatementImportPage).where(
                StatementImportPage.statement_import_id == batch.id,
                StatementImportPage.page_number == page_number,
            )
        )
        run = await self._run(batch.id)
        rows = list(
            (
                await self.session.scalars(
                    select(StatementImportRow)
                    .where(
                        StatementImportRow.statement_import_id == batch.id,
                        StatementImportRow.page_number == page_number,
                    )
                    .order_by(StatementImportRow.row_number)
                )
            ).all()
        )
        projection = [await self._row(item, run.id if run else None) for item in rows]
        if page is None:
            return StatementImportWorkbenchPageResponse.model_validate(
                {
                    "batch_id": batch.id,
                    "page_number": page_number,
                    "source_available": False,
                    "rows": projection,
                }
            )
        return StatementImportWorkbenchPageResponse.model_validate(
            {
                "batch_id": batch.id,
                "page_number": page_number,
                "source_available": page.evidence_text_masked is not None,
                "source_kind": page.source_kind,
                "evidence_text_masked": page.evidence_text_masked,
                "bounding_boxes": page.bounding_boxes or [],
                "rows": projection,
            }
        )

    async def _batch(self, batch_id: UUID) -> StatementImport:
        item = await self.session.scalar(
            select(StatementImport).where(StatementImport.id == batch_id)
        )
        if item is None:
            not_found("statement_import_not_found", "Statement import was not found")
        return item

    async def _run(self, batch_id: UUID) -> StatementImportValidationRun | None:
        return await self.session.scalar(
            select(StatementImportValidationRun)
            .where(StatementImportValidationRun.statement_import_id == batch_id)
            .order_by(StatementImportValidationRun.created_at.desc())
            .limit(1)
        )

    async def _checks(self, run_id: UUID) -> list[StatementImportWorkbenchCheck]:
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
            StatementImportWorkbenchCheck.model_validate(
                {
                    "check_kind": item.check_kind,
                    "status": item.status,
                    "evidence_row_ids": item.evidence_row_ids,
                }
            )
            for item in items
        ]

    async def _row(
        self, row: StatementImportRow, run_id: UUID | None
    ) -> StatementImportWorkbenchRow:
        page = (
            await self.session.scalar(
                select(StatementImportPage).where(
                    StatementImportPage.statement_import_id == row.statement_import_id,
                    StatementImportPage.page_number == row.page_number,
                )
            )
            if row.page_number is not None
            else None
        )
        draft = None
        candidates: list[StatementImportWorkbenchCandidate] = []
        if run_id is not None:
            item = await self.session.scalar(
                select(StatementImportDraftResolution).where(
                    StatementImportDraftResolution.validation_run_id == run_id,
                    StatementImportDraftResolution.statement_import_row_id == row.id,
                )
            )
            if item is not None:
                draft = StatementImportWorkbenchDraft.model_validate(
                    {
                        "id": item.id,
                        "resolution": item.resolution,
                        "matched_transaction_id": item.matched_transaction_id,
                        "ignored_reason": item.ignored_reason,
                        "version": item.version,
                    }
                )
            matches = list(
                (
                    await self.session.scalars(
                        select(StatementImportReviewCandidate)
                        .where(
                            StatementImportReviewCandidate.validation_run_id == run_id,
                            StatementImportReviewCandidate.statement_import_row_id == row.id,
                        )
                        .order_by(StatementImportReviewCandidate.created_at)
                    )
                ).all()
            )
            candidates = [
                StatementImportWorkbenchCandidate.model_validate(
                    {
                        "id": item.id,
                        "candidate_kind": item.candidate_kind,
                        "transaction_id": item.transaction_id,
                        "transaction_date": item.transaction_date.isoformat()
                        if item.transaction_date
                        else None,
                        "amount_minor": item.amount_minor,
                    }
                )
                for item in matches
            ]
        final = await self.session.scalar(
            select(StatementImportFinalCreateDraft).where(
                StatementImportFinalCreateDraft.statement_import_row_id == row.id
            )
        )
        return StatementImportWorkbenchRow.model_validate(
            {
                "id": row.id,
                "row_number": row.row_number,
                "page_number": row.page_number,
                "row_version": row.version,
                "source_kind": page.source_kind if page else None,
                "evidence_text_masked": row.evidence_text_masked,
                "bounding_box": row.bounding_box,
                "draft": draft,
                "candidates": candidates,
                "final_create_draft_version": final.version if final else None,
            }
        )

    @staticmethod
    def _matches(
        row: StatementImportWorkbenchRow,
        checks: list[StatementImportWorkbenchCheck],
        filters: StatementImportWorkbenchFilters,
    ) -> bool:
        if filters.resolution is not None and (
            row.draft is None or row.draft.resolution != filters.resolution
        ):
            return False
        if filters.candidate_kind is not None and not any(
            candidate.candidate_kind == filters.candidate_kind for candidate in row.candidates
        ):
            return False
        available = row.source_kind is not None and row.evidence_text_masked is not None
        if filters.evidence_state == "available" and not available:
            return False
        if filters.evidence_state == "unavailable" and available:
            return False
        if filters.check_status is not None and not any(
            check.status == filters.check_status and row.id in check.evidence_row_ids
            for check in checks
        ):
            return False
        return True
