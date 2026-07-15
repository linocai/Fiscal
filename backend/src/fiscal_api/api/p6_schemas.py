from __future__ import annotations

from datetime import date, datetime
from typing import Annotated
from uuid import UUID

from pydantic import Field, StrictInt, field_validator

from fiscal_api.api.p3_schemas import APIModel, TransactionResponse, clean_note, clean_required
from fiscal_api.db.models import ReimbursementClaimStatus

MAX_MINOR = 9_223_372_036_854_775_807
PositiveMinor = Annotated[StrictInt, Field(gt=0, le=MAX_MINOR)]


class ReimbursementAllocationDraft(APIModel):
    id: UUID | None = None
    transaction_id: UUID
    amount_minor: PositiveMinor


class ReimbursementPartyDraft(APIModel):
    id: UUID | None = None
    name: str = Field(min_length=1, max_length=120)
    expected_date: date | None = None
    note: str | None = Field(default=None, max_length=500)
    allocations: list[ReimbursementAllocationDraft] = Field(min_length=1)

    @field_validator("name", mode="before")
    @classmethod
    def trim_name(cls, value: str) -> str:
        return clean_required(value)

    @field_validator("note", mode="before")
    @classmethod
    def trim_note(cls, value: str | None) -> str | None:
        return clean_note(value)


class ReimbursementClaimDraft(APIModel):
    title: str = Field(min_length=1, max_length=120)
    note: str | None = Field(default=None, max_length=500)
    parties: list[ReimbursementPartyDraft] = Field(min_length=1)

    @field_validator("title", mode="before")
    @classmethod
    def trim_title(cls, value: str) -> str:
        return clean_required(value)

    @field_validator("note", mode="before")
    @classmethod
    def trim_note(cls, value: str | None) -> str | None:
        return clean_note(value)


class ReimbursementClaimReplace(ReimbursementClaimDraft):
    expected_version: StrictInt = Field(ge=1)


class ReimbursementVersionRequest(APIModel):
    expected_version: StrictInt = Field(ge=1)


class ReimbursementAllocationResponse(APIModel):
    id: UUID
    transaction_id: UUID
    expense_title: str
    expense_amount_minor: int
    amount_minor: int
    received_minor: int
    outstanding_minor: int
    locked: bool
    position: int


class ReimbursementPartyResponse(APIModel):
    id: UUID
    name: str
    expected_date: date | None
    note: str | None
    claimed_minor: int
    received_minor: int
    outstanding_minor: int
    status: str
    position: int
    allocations: list[ReimbursementAllocationResponse]


class ReimbursementReceiptAllocationResponse(APIModel):
    id: UUID
    allocation_id: UUID
    amount_minor: int
    position: int


class ReimbursementReceiptResponse(APIModel):
    id: UUID
    claim_id: UUID
    party_id: UUID
    amount_minor: int
    received_at: datetime
    destination_account_id: UUID
    title: str
    note: str | None
    transaction: TransactionResponse
    allocations: list[ReimbursementReceiptAllocationResponse]
    version: int
    voided_at: datetime | None
    created_at: datetime
    updated_at: datetime


class ReimbursementClaimResponse(APIModel):
    id: UUID
    title: str
    note: str | None
    status: ReimbursementClaimStatus
    total_claimed_minor: int
    received_minor: int
    outstanding_minor: int
    expense_count: int
    party_count: int
    receipt_count: int
    parties: list[ReimbursementPartyResponse]
    latest_receipt: ReimbursementReceiptResponse | None
    version: int
    submitted_at: datetime | None
    cancelled_at: datetime | None
    voided_at: datetime | None
    archived_at: datetime | None
    created_at: datetime
    updated_at: datetime


class ReimbursementClaimPage(APIModel):
    items: list[ReimbursementClaimResponse]
    next_cursor: str | None


class ReimbursementReceiptPage(APIModel):
    items: list[ReimbursementReceiptResponse]
    next_cursor: str | None


class ReimbursementClaimPreview(APIModel):
    current: ReimbursementClaimResponse
    proposed: ReimbursementClaimResponse
    released_minor: int
    newly_claimed_minor: int
    warnings: list[str]


class ReimbursementCancelPreview(APIModel):
    current: ReimbursementClaimResponse
    proposed_status: ReimbursementClaimStatus
    released_minor: int
    retained_received_minor: int


class ReimbursementReceiptDraft(APIModel):
    expected_claim_version: StrictInt = Field(ge=1)
    party_id: UUID
    amount_minor: PositiveMinor
    received_at: datetime
    destination_account_id: UUID
    title: str = Field(min_length=1, max_length=120)
    note: str | None = Field(default=None, max_length=500)

    @field_validator("received_at")
    @classmethod
    def aware(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("received_at must include a timezone")
        return value

    @field_validator("title", mode="before")
    @classmethod
    def trim_title(cls, value: str) -> str:
        return clean_required(value)

    @field_validator("note", mode="before")
    @classmethod
    def trim_note(cls, value: str | None) -> str | None:
        return clean_note(value)


class ReimbursementReceiptReplace(ReimbursementReceiptDraft):
    expected_receipt_version: StrictInt = Field(ge=1)


class ReimbursementReceiptVersionRequest(APIModel):
    expected_claim_version: StrictInt = Field(ge=1)
    expected_receipt_version: StrictInt = Field(ge=1)


class ReimbursementReceiptPreview(APIModel):
    claim_before: ReimbursementClaimResponse
    party_id: UUID
    amount_minor: int
    party_received_before_minor: int
    party_received_after_minor: int
    claim_received_before_minor: int
    claim_received_after_minor: int
    persisted_allocations: list[ReimbursementReceiptAllocationResponse]


class ReimbursementEligibility(APIModel):
    eligible: bool
    transaction_id: UUID
    canonical_amount_minor: int
    allocated_minor: int
    available_minor: int
    reasons: list[str]


class ReimbursementExpenseOption(APIModel):
    transaction_id: UUID
    title: str
    business_date: date
    kind: str
    account_id: UUID
    category_id: UUID
    canonical_amount_minor: int
    allocated_minor: int
    available_minor: int


class ReimbursementSummary(APIModel):
    gross_expense_minor: int
    merchant_principal_refund_minor: int
    expected_reimbursement_minor: int
    received_reimbursement_minor: int
    personal_expected_expense_minor: int
    personal_realized_expense_minor: int
    outstanding_minor: int
