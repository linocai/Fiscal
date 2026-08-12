from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import Field

from fiscal_api.api.p24_schemas import P24Model, StatementImportBoundingBox
from fiscal_api.api.p27_schemas import ResolutionKind, ValidationStatus


def _empty_bounding_boxes() -> list[StatementImportBoundingBox]:
    return []


def _empty_rows() -> list[StatementImportWorkbenchRow]:
    return []


class StatementImportWorkbenchFilters(P24Model):
    resolution: ResolutionKind | None = None
    candidate_kind: Literal["provider_candidate", "existing_transaction"] | None = None
    check_status: ValidationStatus | None = None
    evidence_state: Literal["available", "unavailable"] | None = None


class StatementImportWorkbenchCheck(P24Model):
    check_kind: str
    status: ValidationStatus
    evidence_row_ids: list[UUID]


class StatementImportWorkbenchCandidate(P24Model):
    id: UUID
    candidate_kind: Literal["provider_candidate", "existing_transaction"]
    transaction_id: UUID | None
    transaction_date: str | None
    amount_minor: int | None


class StatementImportWorkbenchDraft(P24Model):
    id: UUID
    resolution: ResolutionKind
    matched_transaction_id: UUID | None
    ignored_reason: str | None
    version: int


class StatementImportWorkbenchRow(P24Model):
    id: UUID
    row_number: int
    page_number: int | None
    row_version: int
    source_kind: Literal["text", "scanned_image", "mixed", "unsupported"] | None
    evidence_text_masked: str | None
    bounding_box: StatementImportBoundingBox | None
    draft: StatementImportWorkbenchDraft | None
    candidates: list[StatementImportWorkbenchCandidate]
    final_create_draft_version: int | None


class StatementImportWorkbenchResponse(P24Model):
    batch_id: UUID
    batch_version: int
    status: str
    review_available: bool
    validation_run_id: UUID | None
    checks: list[StatementImportWorkbenchCheck]
    rows: list[StatementImportWorkbenchRow]
    next_cursor: int | None
    source_unavailable_count: int


class StatementImportWorkbenchPageResponse(P24Model):
    batch_id: UUID
    page_number: int
    source_available: bool
    source_kind: Literal["text", "scanned_image", "mixed", "unsupported"] | None
    evidence_text_masked: str | None = Field(default=None, max_length=20_000)
    bounding_boxes: list[StatementImportBoundingBox] = Field(default_factory=_empty_bounding_boxes)
    rows: list[StatementImportWorkbenchRow] = Field(default_factory=_empty_rows)
