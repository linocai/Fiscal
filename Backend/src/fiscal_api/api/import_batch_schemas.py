from __future__ import annotations

import re
from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import Field, StrictInt, field_validator, model_validator

from fiscal_api.api.p3_schemas import APIModel, PositiveMinorUnits, clean_note, clean_required
from fiscal_api.db.models import ImportBatchSource, ImportBatchStatus, TransactionKind


class ImportCandidate(APIModel):
    client_id: str = Field(min_length=1, max_length=120)
    kind: TransactionKind
    amount_minor: PositiveMinorUnits
    occurred_at: datetime
    title: str = Field(min_length=1, max_length=120)
    note: str | None = Field(default=None, max_length=500)
    account_id: UUID | None = None
    category_id: UUID | None = None
    destination_account_id: UUID | None = None
    credit_cycle_id: UUID | None = None
    field_confidences: dict[str, StrictInt] = Field(default_factory=dict)
    overall_confidence_bps: StrictInt | None = Field(default=None, ge=0, le=10_000)
    missing_fields: list[str] = Field(default_factory=list, max_length=8)
    source_text: str | None = Field(default=None, max_length=2_000)

    @field_validator("client_id", "title", mode="before")
    @classmethod
    def trim_required(cls, value: str) -> str:
        return clean_required(value)

    @field_validator("note", mode="before")
    @classmethod
    def trim_note(cls, value: str | None) -> str | None:
        return clean_note(value)

    @field_validator("occurred_at")
    @classmethod
    def require_aware_datetime(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("occurred_at must include a timezone")
        return value

    @field_validator("field_confidences")
    @classmethod
    def validate_confidences(cls, value: dict[str, StrictInt]) -> dict[str, StrictInt]:
        if any(not key.strip() for key in value):
            raise ValueError("confidence field names must not be empty")
        if any(item < 0 or item > 10_000 for item in value.values()):
            raise ValueError("confidence values must be between 0 and 10000")
        return value


class ImportBatchCreate(APIModel):
    source: ImportBatchSource
    original_content_sha256: str = Field(min_length=64, max_length=64)
    candidates: list[ImportCandidate] = Field(min_length=1, max_length=500)
    idempotency_key: str = Field(min_length=8, max_length=128)

    @field_validator("original_content_sha256")
    @classmethod
    def validate_fingerprint(cls, value: str) -> str:
        if re.fullmatch(r"[0-9a-fA-F]{64}", value) is None:
            raise ValueError("original_content_sha256 must be a SHA-256 hex digest")
        return value.lower()

    @field_validator("idempotency_key", mode="before")
    @classmethod
    def trim_idempotency_key(cls, value: str) -> str:
        return clean_required(value)

    @model_validator(mode="after")
    def require_unique_client_ids(self) -> ImportBatchCreate:
        ids = [candidate.client_id for candidate in self.candidates]
        if len(ids) != len(set(ids)):
            raise ValueError("candidate client_id values must be unique within a batch")
        return self


class ImportBatchVersionRequest(APIModel):
    expected_version: StrictInt = Field(ge=1)


class ImportBatchCommitRequest(ImportBatchVersionRequest):
    confirmation_token: str = Field(min_length=16, max_length=512)
    idempotency_key: str = Field(min_length=8, max_length=128)

    @field_validator("confirmation_token", "idempotency_key", mode="before")
    @classmethod
    def trim_required(cls, value: str) -> str:
        return clean_required(value)


class ImportBatchIgnoreRequest(ImportBatchVersionRequest):
    reason: str | None = Field(default=None, max_length=240)

    @field_validator("reason", mode="before")
    @classmethod
    def trim_reason(cls, value: str | None) -> str | None:
        return clean_note(value)


class ImportBatchResponse(APIModel):
    id: UUID
    source: ImportBatchSource
    original_content_sha256: str
    status: ImportBatchStatus
    candidates: list[dict[str, Any]]
    validation_errors: list[dict[str, Any]]
    transaction_receipts: list[dict[str, Any]]
    ignored_reason: str | None
    version: int
    created_at: datetime
    updated_at: datetime
    validated_at: datetime | None
    committed_at: datetime | None
    ignored_at: datetime | None


class ImportBatchPage(APIModel):
    items: list[ImportBatchResponse]
    next_cursor: str | None = None
