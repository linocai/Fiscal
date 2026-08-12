from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator, model_validator


class P24Model(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)


DocumentSHA256 = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
ImportStatus = Literal[
    "created",
    "extracting",
    "parsing",
    "review_required",
    "ready_to_confirm",
    "partially_confirmed",
    "confirmed",
    "failed",
    "abandoned",
]
AttemptStatus = Literal["started", "succeeded", "failed", "abandoned"]
EvidencePageKind = Literal["text", "scanned_image", "mixed", "unsupported"]


def _empty_bounding_boxes() -> list[StatementImportBoundingBox]:
    return []


def _empty_evidence_rows() -> list[StatementImportEvidenceRow]:
    return []


ImportErrorCode = Literal[
    "client_extraction_failed",
    "document_unavailable",
    "document_invalid",
    "document_cancelled",
]


class StatementImportRegister(P24Model):
    document_sha256: DocumentSHA256
    byte_size: Annotated[StrictInt, Field(gt=0, le=2**63 - 1)]
    page_count: Annotated[StrictInt, Field(ge=1, le=10_000)]
    mime_type: Literal["application/pdf"]
    display_name: str = Field(min_length=1, max_length=255)

    @field_validator("display_name")
    @classmethod
    def display_name_is_filename(cls, value: str) -> str:
        if not value.strip() or any(character in value for character in {"/", "\\", "\x00"}):
            raise ValueError("display_name must be a filename")
        return value.strip()


class StatementImportVersionRequest(P24Model):
    expected_version: Annotated[StrictInt, Field(ge=1)]


class StatementImportFailure(StatementImportVersionRequest):
    error_code: ImportErrorCode


class StatementImportBoundingBox(P24Model):
    x: float = Field(ge=0, le=1)
    y: float = Field(ge=0, le=1)
    width: float = Field(gt=0, le=1)
    height: float = Field(gt=0, le=1)

    @model_validator(mode="after")
    def stays_within_page(self) -> StatementImportBoundingBox:
        if self.x + self.width > 1 or self.y + self.height > 1:
            raise ValueError("bounding_box must stay within the normalized page")
        return self


class StatementImportEvidencePage(P24Model):
    page_number: Annotated[StrictInt, Field(ge=1, le=10_000)]
    source_kind: EvidencePageKind
    evidence_text_masked: str | None = Field(default=None, max_length=20_000)
    bounding_boxes: list[StatementImportBoundingBox] = Field(
        default_factory=_empty_bounding_boxes, max_length=2_000
    )


class StatementImportEvidenceRow(P24Model):
    row_number: Annotated[StrictInt, Field(ge=1, le=100_000)]
    page_number: Annotated[StrictInt, Field(ge=1, le=10_000)]
    evidence_text_masked: str = Field(min_length=1, max_length=20_000)
    bounding_box: StatementImportBoundingBox


class StatementImportEvidenceSubmission(StatementImportVersionRequest):
    """A redacted local-extraction result. It deliberately has no PDF/image fields."""

    attempt_id: UUID
    pages: list[StatementImportEvidencePage] = Field(min_length=1, max_length=10_000)
    rows: list[StatementImportEvidenceRow] = Field(
        default_factory=_empty_evidence_rows, max_length=100_000
    )


class StatementImportAttemptResponse(P24Model):
    id: UUID
    attempt_number: int
    kind: Literal["local_extraction", "provider_parse"]
    status: AttemptStatus
    error_code: str | None
    started_at: datetime
    completed_at: datetime | None


class StatementImportResponse(P24Model):
    id: UUID
    document_sha256: str
    byte_size: int
    page_count: int
    mime_type: str
    display_name: str
    currency: Literal["CNY"]
    status: ImportStatus
    latest_attempt_id: UUID | None
    version: int
    created_at: datetime
    updated_at: datetime
    confirmed_at: datetime | None
    abandoned_at: datetime | None


class StatementImportRegistrationResponse(StatementImportResponse):
    duplicate: bool


class StatementImportEvidenceResponse(StatementImportResponse):
    attempt_id: UUID
    evidence_sha256: str
    row_count: int
    duplicate: bool
