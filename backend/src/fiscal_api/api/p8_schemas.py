from __future__ import annotations

from datetime import date, datetime
from typing import Annotated, Literal
from urllib.parse import urlparse
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator

from fiscal_api.api.p3_schemas import (
    MAX_MINOR_UNITS,
    TransactionDraft,
    TransactionResponse,
)
from fiscal_api.db.models import TransactionKind

ConfidenceBPS = Annotated[StrictInt, Field(ge=0, le=10_000)]
SafeConfidenceBPS = Annotated[StrictInt, Field(ge=9_000, le=10_000)]
SafeAutoLimit = Annotated[StrictInt, Field(ge=1, le=100_000)]
ProposalStatus = Literal["processing", "pending", "executed", "failed", "ignored", "undone"]
ProposalSource = Literal["text", "ocr", "shortcut_text"]
AIField = Literal[
    "kind",
    "amount_minor",
    "occurred_at",
    "title",
    "note",
    "account_id",
    "category_id",
    "destination_account_id",
]


class P8Model(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)


class AICandidate(P8Model):
    id: UUID
    name: str = Field(min_length=1, max_length=120)
    kind: str | None = Field(default=None, max_length=32)
    direction: str | None = Field(default=None, max_length=16)


class AIParseRequest(P8Model):
    text: str = Field(min_length=1, max_length=2_000)
    business_date: date
    accounts: list[AICandidate] = Field(max_length=500)
    categories: list[AICandidate] = Field(max_length=1_000)


class AIFieldConfidences(P8Model):
    kind: ConfidenceBPS = 0
    amount_minor: ConfidenceBPS = 0
    occurred_at: ConfidenceBPS = 0
    title: ConfidenceBPS = 0
    note: ConfidenceBPS = 0
    account_id: ConfidenceBPS = 0
    category_id: ConfidenceBPS = 0
    destination_account_id: ConfidenceBPS = 0


class AIProviderResult(P8Model):
    kind: TransactionKind | None = None
    amount_minor: Annotated[StrictInt, Field(gt=0, le=MAX_MINOR_UNITS)] | None = None
    occurred_at: datetime | None = None
    title: str | None = Field(default=None, min_length=1, max_length=120)
    note: str | None = Field(default=None, max_length=500)
    account_id: UUID | None = None
    category_id: UUID | None = None
    destination_account_id: UUID | None = None
    confidences: AIFieldConfidences
    overall_confidence_bps: ConfidenceBPS
    missing_fields: list[AIField] = Field(default_factory=lambda: list[AIField](), max_length=8)
    explanation: str | None = Field(default=None, max_length=240)

    @field_validator("occurred_at")
    @classmethod
    def aware_datetime(cls, value: datetime | None) -> datetime | None:
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("occurred_at must include a timezone")
        return value

    @field_validator("missing_fields")
    @classmethod
    def unique_missing_fields(cls, value: list[AIField]) -> list[AIField]:
        if len(value) != len(set(value)):
            raise ValueError("missing_fields must be unique")
        return value


class AISettingsResponse(P8Model):
    auto_execute_enabled: bool
    ocr_source_enabled: bool
    shortcut_text_source_enabled: bool
    auto_execute_limit_minor: int
    minimum_confidence_bps: int
    version: int
    provider_configured: bool
    effective_auto_execute: bool
    created_at: datetime
    updated_at: datetime


class AISettingsReplace(P8Model):
    auto_execute_enabled: bool
    ocr_source_enabled: bool
    shortcut_text_source_enabled: bool
    auto_execute_limit_minor: SafeAutoLimit
    minimum_confidence_bps: SafeConfidenceBPS
    expected_version: Annotated[StrictInt, Field(ge=1)]


class AIProviderSettingsResponse(P8Model):
    provider: Literal["openai_compatible"] | None
    base_url: str | None
    model: str | None
    api_key_configured: bool
    version: int
    updated_at: datetime


class AIProviderSettingsReplace(P8Model):
    provider: Literal["openai_compatible"] = "openai_compatible"
    base_url: str = Field(min_length=8, max_length=500)
    model: str = Field(min_length=1, max_length=200)
    api_key: str | None = Field(default=None, min_length=8, max_length=4096)
    expected_version: Annotated[StrictInt, Field(ge=1)]

    @field_validator("base_url")
    @classmethod
    def valid_provider_url(cls, value: str) -> str:
        parsed = urlparse(value)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("base_url must be an absolute HTTP(S) URL")
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError("base_url must not contain credentials, query, or fragment")
        return value.rstrip("/")

    @field_validator("model")
    @classmethod
    def normalized_model(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("model must not be blank")
        return value


class AIProposalCreate(P8Model):
    source: ProposalSource
    text: str = Field(min_length=1, max_length=2_000)

    @field_validator("text")
    @classmethod
    def validate_untrusted_text(cls, value: str) -> str:
        if any(ord(character) < 32 and character not in {"\n", "\r", "\t"} for character in value):
            raise ValueError("text contains a control character")
        if not value.strip():
            raise ValueError("text must not be blank")
        return value


class AIProposalResponse(P8Model):
    id: UUID
    source: ProposalSource
    text: str
    content_fingerprint: str
    provider: str | None
    model: str | None
    kind: TransactionKind | None
    amount_minor: int | None
    occurred_at: datetime | None
    title: str | None
    note: str | None
    account_id: UUID | None
    category_id: UUID | None
    destination_account_id: UUID | None
    credit_cycle_id: UUID | None
    field_confidences: AIFieldConfidences
    overall_confidence_bps: int | None
    missing_fields: list[AIField]
    reason_codes: list[str]
    explanation: str | None
    status: ProposalStatus
    error_code: str | None
    error_message: str | None
    transaction_id: UUID | None
    transaction_version: int | None
    version: int
    created_at: datetime
    updated_at: datetime
    executed_at: datetime | None
    ignored_at: datetime | None
    undone_at: datetime | None


class AIProposalPage(P8Model):
    items: list[AIProposalResponse]
    next_cursor: str | None
    pending_count: int


class AIProposalReplace(P8Model):
    draft: TransactionDraft
    expected_version: Annotated[StrictInt, Field(ge=1)]


class AIProposalVersionRequest(P8Model):
    expected_version: Annotated[StrictInt, Field(ge=1)]


class AIProposalRetryRequest(AIProposalVersionRequest):
    pass


class AIProposalUndoRequest(AIProposalVersionRequest):
    expected_transaction_version: Annotated[StrictInt, Field(ge=1)]


class AIProposalMutationResponse(P8Model):
    proposal: AIProposalResponse
    transaction: TransactionResponse | None = None
