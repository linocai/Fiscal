from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator


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
