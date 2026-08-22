from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import Field

from fiscal_api.api.p24_schemas import P24Model, StatementImportBoundingBox
from fiscal_api.api.p27_confirmation_schemas import StatementImportConfirmRequest
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
    is_confirmed: bool


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


class StatementImportConfirmationPreviewRequest(P24Model):
    """The explicit selected subset. Versions are always freshly server-derived."""

    row_ids: list[UUID] = Field(min_length=1, max_length=1000)


class StatementImportConfirmationPreviewRow(P24Model):
    row_id: UUID
    expected_row_version: int
    expected_draft_version: int
    expected_final_create_draft_version: int | None
    resolution: ResolutionKind
    is_confirmed: bool


class StatementImportConfirmationPreviewCounts(P24Model):
    selected: int
    create_new: int
    match_existing: int
    ignore_non_transaction: int
    ignore_intentional: int
    unresolved: int
    batch_unresolved: int


class StatementImportConfirmationPreviewAmounts(P24Model):
    """Only source values that are actually stored are summed; unknown is explicit."""

    known_create_minor: int
    known_match_minor: int
    known_total_minor: int
    unknown_selected_count: int


class StatementImportConfirmationPreviewCheck(P24Model):
    check_kind: str
    status: ValidationStatus


class StatementImportConfirmationPreviewResponse(P24Model):
    batch_id: UUID
    batch_version: int
    status: str
    selected_rows: list[StatementImportConfirmationPreviewRow]
    counts: StatementImportConfirmationPreviewCounts
    amounts: StatementImportConfirmationPreviewAmounts
    checks: list[StatementImportConfirmationPreviewCheck]
    warnings: list[str]
    request: StatementImportConfirmRequest
