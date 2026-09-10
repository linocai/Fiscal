from __future__ import annotations

import re
from datetime import date
from decimal import Decimal, InvalidOperation
from typing import Annotated, Literal
from uuid import UUID

from pydantic import Field, StrictInt, field_validator, model_validator

from fiscal_api.api.p24_schemas import P24Model, StatementImportBoundingBox, StatementImportResponse

StatementProviderSchemaVersion = Literal["statement-provider-v1"]
StatementProviderDirection = Literal["inflow", "outflow", "unknown"]
StatementProviderTransactionKind = Literal[
    "expense", "income", "refund", "transfer", "repayment", "fee", "interest", "unknown"
]
StatementProviderDocumentStatus = Literal["synthetic", "complete", "partial", "unknown"]
StatementProviderUncertainField = Literal[
    "transaction_date",
    "posted_date",
    "raw_amount",
    "direction",
    "transaction_kind",
    "summary_evidence",
]


def _empty_source_rows() -> list[Annotated[StrictInt, Field(ge=1)]]:
    return []


def _empty_candidates() -> list[StatementProviderCandidate]:
    return []


def _empty_uncertain_fields() -> list[StatementProviderUncertainField]:
    return []


class StatementProviderAuthorization(P24Model):
    confirmed: Literal[True]
    provider: Literal["synthetic_statement", "openai_compatible"]
    provider_model: str = Field(min_length=1, max_length=200)
    configuration_revision: str | None = Field(default=None, max_length=128)
    prompt_version: Literal["statement-p26-v1"]
    schema_version: StatementProviderSchemaVersion
    evidence_sha256: Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
    page_numbers: list[Annotated[StrictInt, Field(ge=1, le=10_000)]] = Field(
        min_length=1, max_length=10_000
    )
    row_count: Annotated[StrictInt, Field(ge=0, le=100_000)]
    redaction_version: Literal["statement-redaction-v1"]
    redaction_count: Annotated[StrictInt, Field(ge=0, le=100_000)]


class StatementImportProviderAttemptCreate(P24Model):
    expected_version: Annotated[StrictInt, Field(ge=1)]
    evidence_sha256: Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
    authorization: StatementProviderAuthorization


class StatementProviderOutboundPage(P24Model):
    page_number: int
    source_kind: Literal["text", "scanned_image", "mixed", "unsupported"]
    evidence_text_masked: str | None


class StatementProviderOutboundRow(P24Model):
    row_number: int
    page_number: int
    evidence_text_masked: str
    bounding_box: StatementImportBoundingBox


class StatementProviderOutboundRequest(P24Model):
    schema_version: StatementProviderSchemaVersion
    currency: Literal["CNY"]
    pages: list[StatementProviderOutboundPage]
    rows: list[StatementProviderOutboundRow]


class StatementProviderCandidate(P24Model):
    source_row_numbers: list[Annotated[StrictInt, Field(ge=1)]] = Field(
        min_length=1, max_length=100
    )
    transaction_date: date | None = None
    posted_date: date | None = None
    raw_amount: str | None = Field(default=None, max_length=80)
    direction: StatementProviderDirection
    transaction_kind: StatementProviderTransactionKind
    summary_evidence: str | None = Field(default=None, max_length=500)
    uncertain_fields: list[StatementProviderUncertainField] = Field(
        default_factory=_empty_uncertain_fields, max_length=20
    )
    unparsed_source_row_numbers: list[Annotated[StrictInt, Field(ge=1)]] = Field(
        default_factory=_empty_source_rows, max_length=100
    )

    @field_validator("transaction_date", "posted_date", mode="before")
    @classmethod
    def exact_date(cls, value: object) -> object:
        if value is None or type(value) is date:
            return value
        if not isinstance(value, str) or re.fullmatch(r"\d{4}-\d{2}-\d{2}", value) is None:
            raise ValueError("statement dates must use YYYY-MM-DD")
        return value

    @field_validator("raw_amount")
    @classmethod
    def cny_decimal(cls, value: str | None) -> str | None:
        if value is None:
            return None
        if re.fullmatch(r"[+-]?\d+(?:\.\d{1,2})?", value) is None:
            raise ValueError("raw_amount must use plain decimal notation")
        try:
            amount = Decimal(value)
        except InvalidOperation as error:
            raise ValueError("raw_amount must be decimal") from error
        if not amount.is_finite() or abs(amount) > Decimal("92233720368547758.07"):
            raise ValueError("raw_amount is outside Int64 minor units")
        exponent = amount.as_tuple().exponent
        if isinstance(exponent, int) and exponent < -2:
            raise ValueError("raw_amount has more than two decimal places")
        return value

    @model_validator(mode="after")
    def unique_sources(self) -> StatementProviderCandidate:
        if len(set(self.source_row_numbers)) != len(self.source_row_numbers):
            raise ValueError("source_row_numbers must be unique")
        return self


class StatementProviderDocument(P24Model):
    status: StatementProviderDocumentStatus = "unknown"


class StatementProviderResult(P24Model):
    schema_version: StatementProviderSchemaVersion = "statement-provider-v1"
    document: StatementProviderDocument = Field(default_factory=StatementProviderDocument)
    candidates: list[StatementProviderCandidate] = Field(
        default_factory=_empty_candidates, max_length=100_000
    )


class StatementImportProviderAttemptResponse(StatementImportResponse):
    provider_attempt_id: str
    provider_snapshot_id: UUID | None = None
    attempt_id: str
    provider: str
    provider_model: str
    prompt_version: str
    schema_version: str
    provider_status: str
    candidate_count: int
    replay: bool
    # Provider parsing is request-bound.  A disconnect/cancellation is never
    # advertised as a detached background task that will continue off-device.
    execution_scope: Literal["request_bound"] = "request_bound"


class StatementProviderAuthorizationPreview(P24Model):
    batch_version: int
    configured: bool
    provider: str | None = None
    provider_model: str | None = None
    prompt_version: str | None = None
    schema_version: str | None = None
    configuration_revision: str | None = None
    evidence_sha256: str | None = None
    page_numbers: list[int]
    row_count: int
    redaction_count: int
    redaction_version: str = "statement-redaction-v1"
    description: str


class StatementImportRecovery(P24Model):
    batch: StatementImportResponse
    next_action: str
    evidence_sha256: str | None = None
    row_count: int
    active_attempt_id: UUID | None = None
    provider_attempt_id: UUID | None = None
    provider_status: str | None = None
    provider_snapshot_id: UUID | None = None
    validation_run_id: UUID | None = None
    has_confirmed_rows: bool
    confirmation_status: str | None = None
    failure_reason: str | None = None
