from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator

from fiscal_api.api.p3_schemas import AvailableAction


class APIModel(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)


class ReconciliationTargetKind(StrEnum):
    ACCOUNT = "account"
    CREDIT_CYCLE = "credit_cycle"


class ReconciliationState(StrEnum):
    OPEN = "open"
    RECONCILED = "reconciled"


class CheckpointCreate(APIModel):
    target_kind: ReconciliationTargetKind
    account_id: UUID | None = None
    credit_cycle_id: UUID | None = None
    as_of: datetime
    actual_balance_minor: StrictInt
    note: str | None = Field(default=None, max_length=500)

    @field_validator("as_of")
    @classmethod
    def aware(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("as_of must include a timezone")
        return value


class CheckpointResponse(APIModel):
    id: UUID
    target_kind: ReconciliationTargetKind
    account_id: UUID | None
    credit_cycle_id: UUID | None
    as_of: datetime
    actual_balance_minor: int
    book_balance_minor: int
    difference_minor: int
    state: ReconciliationState
    note: str | None
    created_at: datetime


class BalanceDiagnosisItem(APIModel):
    transaction_id: UUID
    occurred_at: datetime
    title: str
    amount_minor: int
    account_impact_minor: int


class BalanceDiagnosis(APIModel):
    target_kind: ReconciliationTargetKind
    account_id: UUID | None
    credit_cycle_id: UUID | None
    as_of: datetime
    from_as_of: datetime | None
    opening_balance_minor: int
    book_balance_minor: int
    actual_balance_minor: int | None
    difference_minor: int | None
    entries: list[BalanceDiagnosisItem]


class AttentionSeverity(StrEnum):
    INFO = "info"
    WARNING = "warning"
    CRITICAL = "critical"


class AttentionItem(APIModel):
    source_type: str
    source_id: UUID
    severity: AttentionSeverity
    amount_minor: int | None = None
    occurred_at: datetime | None = None
    explanation: str
    suggested_action: str
    deep_link: str
    available_actions: list[AvailableAction] = Field(
        default_factory=lambda: list[AvailableAction]()
    )


class AttentionPage(APIModel):
    items: list[AttentionItem]


class AttentionIgnore(APIModel):
    expires_at: datetime

    @field_validator("expires_at")
    @classmethod
    def future_aware(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("expires_at must include a timezone")
        return value
