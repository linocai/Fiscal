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
from fiscal_api.api.p13_schemas import CashFlowItemResponse
from fiscal_api.db.models import TransactionKind

ConfidenceBPS = Annotated[StrictInt, Field(ge=0, le=10_000)]
SafeConfidenceBPS = Annotated[StrictInt, Field(ge=9_000, le=10_000)]
SafeAutoLimit = Annotated[StrictInt, Field(ge=1, le=100_000)]
ProposalStatus = Literal["processing", "pending", "executed", "failed", "ignored", "undone"]
ProposalSource = Literal["text", "ocr", "shortcut_text"]
ProposalTarget = Literal["transaction", "cash_flow"]
QualityEventType = Literal[
    "parsed",
    "confirm_unchanged",
    "confirm_edited",
    "ignored",
    "execute_failed",
    "automatic_execute",
    "manual_execute",
    "undone",
    "provider_retry",
    "final_failure",
]
LearningRuleKind = Literal["merchant_category", "title_account", "category_alias"]
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
    # A false/missing value can only preserve or tighten an enabled strategy.
    confirm_relaxation: bool = False


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
    prompt_version: str = Field(default="p23-v1", min_length=1, max_length=80)
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
    target: ProposalTarget
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
    cash_flow_item_id: UUID | None
    cash_flow_item_version: int | None
    version: int
    created_at: datetime
    updated_at: datetime
    executed_at: datetime | None
    ignored_at: datetime | None
    undone_at: datetime | None
    initial_parse_snapshot: dict[str, object] | None
    final_confirmed_snapshot: dict[str, object] | None
    final_field_diff: dict[str, object] | None
    quality_status: Literal["available", "historical_unavailable"]


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
    expected_transaction_version: Annotated[StrictInt, Field(ge=1)] | None = None


class AIProposalMutationResponse(P8Model):
    proposal: AIProposalResponse
    transaction: TransactionResponse | None = None
    cash_flow_item: CashFlowItemResponse | None = None


class AIQualityEventResponse(P8Model):
    id: UUID
    proposal_id: UUID
    event_type: QualityEventType
    reason: str | None
    details: dict[str, object]
    occurred_at: datetime


class AIQualityMetricsRow(P8Model):
    source: ProposalSource
    provider: str | None
    model: str | None
    prompt_version: str | None
    transaction_kind: str | None
    amount_band: str
    total: int
    parse_succeeded: int
    historical_unavailable: int
    confirm_unchanged: int
    confirm_edited: int
    ignored: int
    execute_failed: int
    automatic_execute: int
    manual_execute: int
    undone: int
    provider_retry: int
    final_failure: int
    pending: int
    terminal_outcomes: int


class AIQualityMetricsResponse(P8Model):
    rows: list[AIQualityMetricsRow]


class AIExecutionPolicyResponse(P8Model):
    id: UUID
    version: int
    effective_at: datetime
    source: ProposalSource | None
    transaction_kind: str | None
    auto_execute_enabled: bool
    auto_execute_limit_minor: int
    minimum_confidence_bps: int
    minimum_sample_size: int
    change_reason: str
    changed_automatically: bool


class AIExecutionPolicyReplace(P8Model):
    source: ProposalSource | None = None
    transaction_kind: str | None = Field(default=None, max_length=32)
    auto_execute_enabled: bool
    auto_execute_limit_minor: SafeAutoLimit
    minimum_confidence_bps: SafeConfidenceBPS
    minimum_sample_size: Annotated[StrictInt, Field(ge=1, le=10_000)] = 30
    change_reason: str = Field(min_length=1, max_length=120)
    confirm_relaxation: bool = False


class AILearningRuleResponse(P8Model):
    id: UUID
    rule_kind: LearningRuleKind
    normalized_key: str
    source: ProposalSource | None
    category_id: UUID | None
    account_id: UUID | None
    evidence_count: int
    enabled: bool
    revoked_at: datetime | None
    created_at: datetime
    updated_at: datetime


class AIShadowEvaluationCreate(P8Model):
    provider: Literal["openai_compatible"] = "openai_compatible"
    model: str = Field(min_length=1, max_length=200)
    prompt_version: str = Field(min_length=1, max_length=80)
    corpus_fingerprint: str = Field(min_length=64, max_length=64, pattern="^[0-9a-f]{64}$")
    sample_size: Annotated[StrictInt, Field(ge=30, le=10_000)]
    passed_cases: Annotated[StrictInt, Field(ge=0, le=10_000)]
    evaluator_version: str = Field(min_length=1, max_length=80)


class AIShadowEvaluationResponse(P8Model):
    id: UUID
    provider: str
    model: str
    prompt_version: str
    corpus_fingerprint: str
    sample_size: int
    passed_cases: int
    evaluator_version: str
    completed_at: datetime
