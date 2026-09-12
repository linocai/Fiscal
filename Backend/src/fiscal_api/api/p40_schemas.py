from datetime import datetime
from typing import Annotated
from uuid import UUID

from pydantic import Field, StrictInt, field_validator

from fiscal_api.api.p2_schemas import INT64_MAX, APIModel

NonnegativeMinor = Annotated[StrictInt, Field(ge=0, le=INT64_MAX)]


class CreditPayoffRequest(APIModel):
    payment_account_id: UUID
    occurred_at: datetime
    actual_amount_minor: NonnegativeMinor
    additional_fee_minor: NonnegativeMinor = 0
    waived_principal_minor: NonnegativeMinor = 0
    waived_fee_minor: NonnegativeMinor = 0
    bank_confirmed_settled: bool = False
    note: str | None = Field(default=None, max_length=500)

    @field_validator("occurred_at")
    @classmethod
    def timezone_required(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("occurred_at must include a timezone")
        return value


class CreditPayoffCommitRequest(CreditPayoffRequest):
    preview_token: UUID


class CreditPayoffAllocation(APIModel):
    cycle_id: UUID | None
    remaining_minor: int
    principal_minor: int
    fee_minor: int
    repaid_minor: int
    waived_principal_minor: int
    waived_fee_minor: int
    installment_plan_ids: list[UUID] = Field(default_factory=lambda: list[UUID]())


class CreditPayoffPreview(APIModel):
    account_id: UUID
    payment_account_id: UUID
    preview_token: UUID
    preview_expires_at: datetime
    data_revision: int
    payment_balance_before_minor: int
    payment_balance_after_minor: int
    debt_before_minor: int
    debt_after_minor: int
    actual_amount_minor: int
    principal_minor: int
    fee_minor: int
    additional_fee_minor: int
    waived_principal_minor: int
    waived_fee_minor: int
    allocations: list[CreditPayoffAllocation]
    closing_installment_plan_ids: list[UUID]
    warnings: list[str] = Field(default_factory=list)
    executable: bool


class CreditPayoffReceipt(APIModel):
    operation_id: UUID
    account_id: UUID
    payment_account_id: UUID
    occurred_at: datetime
    status: str
    data_revision: int
    actual_amount_minor: int
    debt_before_minor: int
    debt_after_minor: int
    transaction_ids: list[UUID]
    allocations: list[CreditPayoffAllocation]
    reversed_at: datetime | None = None


class CreditPayoffReversePreview(APIModel):
    operation_id: UUID
    preview_token: UUID
    preview_expires_at: datetime
    data_revision: int
    executable: bool
    warnings: list[str] = Field(default_factory=list)


class CreditPayoffReverseRequest(APIModel):
    preview_token: UUID
