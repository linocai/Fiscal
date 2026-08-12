from __future__ import annotations

from datetime import date
from typing import Annotated, Literal
from uuid import UUID

from pydantic import Field

from fiscal_api.api.p24_schemas import P24Model

ValidationStatus = Literal["passed", "failed", "unavailable"]
ResolutionKind = Literal[
    "unresolved", "create_new", "match_existing", "ignore_non_transaction", "ignore_intentional"
]


class StatementImportValidationRunCreate(P24Model):
    expected_batch_version: Annotated[int, Field(ge=1)]
    provider_snapshot_id: UUID


class StatementImportDraftResolutionPut(P24Model):
    expected_batch_version: Annotated[int, Field(ge=1)]
    expected_row_version: Annotated[int, Field(ge=1)]
    expected_resolution_version: Annotated[int, Field(ge=0)]
    resolution: ResolutionKind
    matched_transaction_id: UUID | None = None
    ignored_reason: str | None = Field(default=None, min_length=1, max_length=160)


class StatementImportValidationCheckResponse(P24Model):
    check_kind: str
    status: ValidationStatus
    evidence_row_ids: list[UUID]


class StatementImportReviewCandidateResponse(P24Model):
    id: UUID
    statement_import_row_id: UUID
    candidate_kind: Literal["provider_candidate", "existing_transaction"]
    provider_candidate_index: int | None
    transaction_id: UUID | None
    transaction_date: date | None
    amount_minor: int | None


class StatementImportDraftResolutionResponse(P24Model):
    id: UUID
    statement_import_row_id: UUID
    resolution: ResolutionKind
    matched_transaction_id: UUID | None
    ignored_reason: str | None
    version: int


class StatementImportReviewResponse(P24Model):
    batch_id: UUID
    batch_version: int
    status: Literal["review_required"]
    validation_run_id: UUID
    provider_snapshot_id: UUID
    checks: list[StatementImportValidationCheckResponse]
    candidates: list[StatementImportReviewCandidateResponse]
    drafts: list[StatementImportDraftResolutionResponse]
    replay: bool = False
