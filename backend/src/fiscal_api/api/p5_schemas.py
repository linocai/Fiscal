from datetime import date, datetime
from enum import StrEnum
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator, model_validator

from fiscal_api.api.installment_types import InstallmentPlanStatus
from fiscal_api.api.p3_schemas import (
    MAX_MINOR_UNITS,
    TransactionResponse,
    clean_note,
    clean_required,
)
from fiscal_api.db.models import CreditCycleStatus

NonnegativeMinor = Annotated[StrictInt, Field(ge=0, le=MAX_MINOR_UNITS)]
PositiveMinor = Annotated[StrictInt, Field(gt=0, le=MAX_MINOR_UNITS)]


class APIModel(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)


class InstallmentPeriodStatus(StrEnum):
    SCHEDULED = "scheduled"
    BILLED = "billed"
    PARTIAL = "partial"
    CYCLE_SETTLED = "cycle_settled"
    OVERDUE = "overdue"
    CANCELLED = "cancelled"
    SETTLED_EARLY = "settled_early"


class InstallmentPeriodPreview(APIModel):
    sequence: int
    scheduled_cycle_id: UUID | None
    effective_cycle_id: UUID | None
    scheduled_statement_date: date
    effective_statement_date: date
    due_date: date
    principal_minor: int
    fee_minor: int
    amount_due_minor: int
    locked: bool
    status: InstallmentPeriodStatus


class InstallmentPeriodResponse(APIModel):
    id: UUID
    plan_id: UUID
    sequence: int
    scheduled_cycle_id: UUID
    effective_cycle_id: UUID
    scheduled_statement_date: date
    effective_statement_date: date
    due_date: date
    principal_minor: int
    fee_minor: int
    amount_due_minor: int
    locked: bool
    status: InstallmentPeriodStatus
    cycle_status: CreditCycleStatus
    cancelled_at: datetime | None
    settled_early_at: datetime | None
    version: int
    created_at: datetime
    updated_at: datetime


class InstallmentPlanBase(APIModel):
    purchase_transaction_id: UUID
    credit_account_id: UUID
    fee_transaction_id: UUID | None
    fee_category_id: UUID | None
    fee_occurred_at: datetime | None
    title: str
    status: InstallmentPlanStatus
    principal_minor: int
    fee_minor: int
    total_financed_minor: int
    installment_count: int
    start_statement_date: date
    locked_count: int
    future_count: int
    cancelled_count: int
    cycle_settled_count: int
    scheduled_gross_minor: int
    future_scheduled_gross_minor: int


class InstallmentPlanResponse(InstallmentPlanBase):
    id: UUID
    next_period: InstallmentPeriodResponse | None
    periods: list[InstallmentPeriodResponse]
    version: int
    created_at: datetime
    updated_at: datetime


class InstallmentPlanPreview(InstallmentPlanBase):
    id: UUID | None
    next_period: InstallmentPeriodPreview | None
    periods: list[InstallmentPeriodPreview]


class InstallmentPlanPage(APIModel):
    items: list[InstallmentPlanResponse]
    next_cursor: str | None


class InstallmentCreate(APIModel):
    purchase_transaction_id: UUID
    installment_count: StrictInt = Field(ge=2, le=60)
    total_fee_minor: NonnegativeMinor
    fee_category_id: UUID | None = None
    fee_occurred_at: datetime | None = None
    start_statement_date: date

    @model_validator(mode="after")
    def validate_fee(self) -> "InstallmentCreate":
        if (self.total_fee_minor > 0) != (
            self.fee_category_id is not None and self.fee_occurred_at is not None
        ):
            raise ValueError(
                "positive fee requires fee_category_id and fee_occurred_at; zero fee forbids both"
            )
        if self.fee_occurred_at is not None and self.fee_occurred_at.utcoffset() is None:
            raise ValueError("fee_occurred_at must include a timezone")
        return self


class InstallmentPurchaseReplacement(APIModel):
    amount_minor: PositiveMinor
    occurred_at: datetime
    title: str = Field(min_length=1, max_length=120)
    note: str | None = Field(default=None, max_length=500)
    account_id: UUID
    category_id: UUID

    @field_validator("title", mode="before")
    @classmethod
    def title_clean(cls, value: str) -> str:
        return clean_required(value)

    @field_validator("note", mode="before")
    @classmethod
    def note_clean(cls, value: str | None) -> str | None:
        return clean_note(value)

    @field_validator("occurred_at")
    @classmethod
    def occurred_aware(cls, value: datetime) -> datetime:
        if value.utcoffset() is None:
            raise ValueError("occurred_at must include a timezone")
        return value


class InstallmentReplacement(APIModel):
    expected_version: StrictInt = Field(ge=1)
    purchase: InstallmentPurchaseReplacement
    installment_count: StrictInt = Field(ge=2, le=60)
    total_fee_minor: NonnegativeMinor
    fee_category_id: UUID | None = None
    fee_occurred_at: datetime | None = None
    start_statement_date: date

    @model_validator(mode="after")
    def validate_fee(self) -> "InstallmentReplacement":
        complete_fee = self.fee_category_id is not None and self.fee_occurred_at is not None
        if (self.total_fee_minor > 0) != complete_fee:
            raise ValueError(
                "positive fee requires fee_category_id and fee_occurred_at; zero fee forbids both"
            )
        if self.fee_occurred_at is not None and self.fee_occurred_at.utcoffset() is None:
            raise ValueError("fee_occurred_at must include a timezone")
        return self


class InstallmentCycleOption(APIModel):
    cycle_id: UUID | None
    statement_date: date
    due_date: date
    existing: bool
    eligible: bool


class InstallmentEligibility(APIModel):
    purchase_transaction_id: UUID
    eligible: bool
    reason_code: str | None
    credit_account_id: UUID
    principal_minor: int
    natural_statement_date: date
    start_options: list[InstallmentCycleOption]


class InstallmentTeaser(APIModel):
    plan_id: UUID
    title: str
    status: InstallmentPlanStatus
    installment_count: int
    future_count: int
    future_scheduled_gross_minor: int
    next_period: InstallmentPeriodResponse | None


class InstallmentLiabilityGroup(APIModel):
    month: str
    principal_scheduled_gross_minor: int
    fee_scheduled_gross_minor: int
    total_scheduled_gross_minor: int
    period_count: int
    plans: list[InstallmentTeaser]


class InstallmentLiabilities(APIModel):
    account_id: UUID
    total_future_scheduled_gross_minor: int
    groups: list[InstallmentLiabilityGroup]


class InstallmentActionRequest(APIModel):
    expected_version: StrictInt = Field(ge=1)
    occurred_at: datetime

    @field_validator("occurred_at")
    @classmethod
    def occurred_aware(cls, value: datetime) -> datetime:
        if value.utcoffset() is None:
            raise ValueError("occurred_at must include a timezone")
        return value


class InstallmentSettlementRequest(InstallmentActionRequest):
    payment_account_id: UUID
    target_statement_date: date


class InstallmentSettlementResult(APIModel):
    operation_id: UUID
    plan: InstallmentPlanResponse
    repayment_transaction: TransactionResponse
    replayed: bool


class InstallmentReverseSettlementResult(APIModel):
    operation_id: UUID
    plan: InstallmentPlanResponse
    voided_repayment_transaction: TransactionResponse
    replayed: bool


class InstallmentCancellationResult(APIModel):
    operation_id: UUID
    plan: InstallmentPlanResponse
    refund_transactions: list[TransactionResponse]
    replayed: bool


class InstallmentAffectedCycle(APIModel):
    statement_date: date
    cycle_id: UUID | None
    before_due_minor: int
    after_due_minor: int
    delta_minor: int


class InstallmentWarning(APIModel):
    code: str
    message: str


class InstallmentPlanChangePreview(APIModel):
    current_plan: InstallmentPlanResponse
    proposed_plan: InstallmentPlanPreview
    locked_periods: list[InstallmentPeriodResponse]
    future_periods: list[InstallmentPeriodPreview]
    affected_cycles: list[InstallmentAffectedCycle]
    warnings: list[InstallmentWarning]


class InstallmentSettlementPreview(APIModel):
    amount_minor: int
    current_plan: InstallmentPlanResponse
    proposed_plan: InstallmentPlanPreview
    affected_cycles: list[InstallmentAffectedCycle]
    payment_balance_before_minor: int
    payment_balance_after_minor: int
    debt_before_minor: int
    debt_after_minor: int
    warnings: list[InstallmentWarning]


class InstallmentReverseSettlementPreview(APIModel):
    eligible: bool
    repayment_transaction: TransactionResponse
    restored_periods: list[InstallmentPeriodPreview]
    affected_cycles: list[InstallmentAffectedCycle]
    payment_balance_before_minor: int
    payment_balance_after_minor: int
    debt_before_minor: int
    debt_after_minor: int
    warnings: list[InstallmentWarning]


class InstallmentCancellationPreview(APIModel):
    principal_refund_minor: int
    fee_refund_minor: int
    cancelled_periods: list[InstallmentPeriodPreview]
    current_plan: InstallmentPlanResponse
    proposed_plan: InstallmentPlanPreview
    affected_cycles: list[InstallmentAffectedCycle]
    debt_before_minor: int
    debt_after_minor: int
    expense_before_minor: int
    expense_after_minor: int
    warnings: list[InstallmentWarning]
