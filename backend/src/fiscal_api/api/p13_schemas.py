from datetime import date, datetime
from enum import StrEnum
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator, model_validator

from fiscal_api.api.p3_schemas import MAX_MINOR_UNITS, clean_note, clean_required
from fiscal_api.db.models import (
    CashFlowDirection,
    CashFlowRecurrence,
    CashFlowSource,
    CashFlowStatus,
)

PositiveMinorUnits = Annotated[StrictInt, Field(gt=0, le=MAX_MINOR_UNITS)]


class APIModel(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)


class CashFlowMutationScope(StrEnum):
    OCCURRENCE = "occurrence"
    THIS_AND_FUTURE = "this_and_future"


class CashFlowSystemKind(StrEnum):
    CREDIT_CYCLE = "credit_cycle"
    REIMBURSEMENT = "reimbursement"


class CashFlowAction(StrEnum):
    CONFIRM = "confirm"
    SETTLE = "settle"
    EDIT = "edit"
    CANCEL = "cancel"
    CONFIRM_REPAYMENT = "confirm_repayment"
    MARK_RECEIVED = "mark_received"


class CashFlowDraft(APIModel):
    title: str = Field(min_length=1, max_length=120)
    note: str | None = Field(default=None, max_length=500)
    direction: CashFlowDirection
    planned_amount_minor: PositiveMinorUnits
    expected_date: date
    account_id: UUID | None = None
    destination_account_id: UUID | None = None
    category_id: UUID | None = None
    recurrence: CashFlowRecurrence | None = None
    recurrence_end_date: date | None = None

    @field_validator("title", mode="before")
    @classmethod
    def trim_title(cls, value: str) -> str:
        return clean_required(value)

    @field_validator("note", mode="before")
    @classmethod
    def trim_note(cls, value: str | None) -> str | None:
        return clean_note(value)

    @model_validator(mode="after")
    def validate_shape(self) -> "CashFlowDraft":
        if self.direction is CashFlowDirection.TRANSFER:
            if self.account_id is None or self.destination_account_id is None:
                raise ValueError("transfer requires source and destination accounts")
            if self.account_id == self.destination_account_id:
                raise ValueError("transfer accounts must differ")
            if self.category_id is not None:
                raise ValueError("transfer cannot have a category")
        elif self.destination_account_id is not None:
            raise ValueError("destination account is only valid for transfers")
        if self.recurrence is not None:
            if self.recurrence_end_date is None:
                raise ValueError("monthly recurrence requires an end date")
            if self.recurrence_end_date < self.expected_date:
                raise ValueError("recurrence end date cannot precede expected date")
        elif self.recurrence_end_date is not None:
            raise ValueError("recurrence_end_date requires recurrence")
        return self


class CashFlowReplace(CashFlowDraft):
    expected_version: StrictInt = Field(ge=1)
    scope: CashFlowMutationScope = CashFlowMutationScope.OCCURRENCE


class CashFlowVersionRequest(APIModel):
    expected_version: StrictInt = Field(ge=1)
    scope: CashFlowMutationScope = CashFlowMutationScope.OCCURRENCE


class CashFlowSettlementDraft(APIModel):
    expected_version: StrictInt = Field(ge=1)
    actual_amount_minor: PositiveMinorUnits
    occurred_at: datetime
    account_id: UUID
    destination_account_id: UUID | None = None
    category_id: UUID | None = None
    title: str | None = Field(default=None, max_length=120)
    note: str | None = Field(default=None, max_length=500)

    @field_validator("title", mode="before")
    @classmethod
    def trim_title(cls, value: str | None) -> str | None:
        return clean_required(value) if value is not None else None

    @field_validator("note", mode="before")
    @classmethod
    def trim_note(cls, value: str | None) -> str | None:
        return clean_note(value)

    @field_validator("occurred_at")
    @classmethod
    def aware_datetime(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("occurred_at must include a timezone")
        return value


class CashFlowItemResponse(APIModel):
    id: str
    manual_item_id: UUID | None = None
    system_kind: CashFlowSystemKind | None = None
    system_reference_id: UUID | None = None
    series_id: UUID | None = None
    title: str
    note: str | None = None
    direction: CashFlowDirection
    planned_amount_minor: int
    expected_date: date
    account_id: UUID | None = None
    destination_account_id: UUID | None = None
    category_id: UUID | None = None
    status: CashFlowStatus
    source: CashFlowSource | str
    version: int
    linked_transaction_id: UUID | None = None
    actual_amount_minor: int | None = None
    actual_date: date | None = None
    is_overdue: bool
    actions: list[CashFlowAction]
    created_at: datetime | None = None
    updated_at: datetime | None = None


class CashFlowSummary(APIModel):
    date_from: date
    date_to: date
    inflow_minor: int
    outflow_minor: int
    net_minor: int


class CashFlowActiveResponse(APIModel):
    summary: CashFlowSummary
    items: list[CashFlowItemResponse]


class CashFlowHistoryResponse(APIModel):
    month: str
    items: list[CashFlowItemResponse]


class CashFlowCreateResponse(APIModel):
    items: list[CashFlowItemResponse]
