from __future__ import annotations

from datetime import date, datetime
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator

from fiscal_api.api.installment_types import InstallmentRelation
from fiscal_api.db.models import PostingRole, TransactionKind

MAX_MINOR_UNITS = 9_223_372_036_854_775_807
PositiveMinorUnits = Annotated[StrictInt, Field(gt=0, le=MAX_MINOR_UNITS)]


def clean_required(value: str) -> str:
    result = value.strip()
    if not result:
        raise ValueError("value must not be empty")
    return result


def clean_note(value: str | None) -> str | None:
    if value is None:
        return None
    result = value.strip()
    return result or None


class APIModel(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)


class TransactionDraft(APIModel):
    kind: TransactionKind
    amount_minor: PositiveMinorUnits
    occurred_at: datetime
    title: str = Field(min_length=1, max_length=120)
    note: str | None = Field(default=None, max_length=500)
    account_id: UUID | None = None
    category_id: UUID | None = None
    destination_account_id: UUID | None = None
    credit_cycle_id: UUID | None = None

    @field_validator("title", mode="before")
    @classmethod
    def trim_title(cls, value: str) -> str:
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

    @field_validator("kind")
    @classmethod
    def manual_kinds_only(cls, value: TransactionKind) -> TransactionKind:
        if value in {TransactionKind.INSTALLMENT_FEE, TransactionKind.INSTALLMENT_REFUND}:
            raise ValueError("installment transaction kinds are server-owned")
        return value


class TransactionReplace(TransactionDraft):
    expected_version: StrictInt = Field(ge=1)


class PostingResponse(APIModel):
    id: UUID
    account_id: UUID
    role: PostingRole
    amount_minor: int
    position: int


class TransactionResponse(APIModel):
    id: UUID
    kind: TransactionKind
    amount_minor: int
    occurred_at: datetime
    business_date: date
    title: str
    note: str | None
    category_id: UUID | None
    account_id: UUID | None
    destination_account_id: UUID | None
    credit_cycle_id: UUID | None
    source: str
    postings: list[PostingResponse]
    version: int
    voided_at: datetime | None
    created_at: datetime
    updated_at: datetime
    installment_plan_id: UUID | None = None
    installment_relation: InstallmentRelation | None = None


class TransactionPage(APIModel):
    items: list[TransactionResponse]
    next_cursor: str | None


class TransactionVersionRequest(APIModel):
    expected_version: StrictInt = Field(ge=1)


class CategorySummaryItem(APIModel):
    category_id: UUID
    category_name: str
    direction: TransactionKind
    amount_minor: int


class TransactionSummary(APIModel):
    income_minor: int
    expense_minor: int
    net_minor: int
    by_category: list[CategorySummaryItem]
