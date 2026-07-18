from datetime import date, datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt

from fiscal_api.api.p5_schemas import InstallmentPeriodResponse, InstallmentTeaser
from fiscal_api.db.models import CreditCycleMode, CreditCycleStatus


class APIModel(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)


class CreditCycleResponse(APIModel):
    id: UUID
    account_id: UUID
    period_start: date
    period_end: date
    statement_date: date
    due_date: date
    is_opening_cycle: bool
    purchase_minor: int
    opening_minor: int
    amount_due_minor: int
    repaid_minor: int
    remaining_minor: int
    status: CreditCycleStatus
    is_overdue: bool
    version: int
    created_at: datetime
    updated_at: datetime
    installment_principal_minor: int = 0
    installment_fee_minor: int = 0
    installment_periods: list[InstallmentPeriodResponse] = []


class CreditCyclePage(APIModel):
    items: list[CreditCycleResponse]
    next_cursor: str | None


class CreditAccountSummary(APIModel):
    account_id: UUID
    name: str
    institution: str | None
    last_four: str | None
    credit_limit_minor: int
    current_debt_minor: int
    available_credit_minor: int
    over_limit_minor: int
    opening_configuration_required: bool
    statement_day: int
    due_day: int
    cycle_mode: CreditCycleMode
    current_cycle: CreditCycleResponse
    next_due_cycle: CreditCycleResponse | None
    has_overdue_cycle: bool
    active_installment_count: int = 0
    future_scheduled_gross_minor: int = 0
    next_installment: InstallmentTeaser | None = None


class CreditScheduleChangeRequest(APIModel):
    expected_version: StrictInt = Field(ge=1)
    cycle_mode: CreditCycleMode
    statement_day: StrictInt = Field(ge=1, le=28)
    due_day: StrictInt = Field(ge=1, le=28)


class CreditScheduleChangeResult(APIModel):
    account_id: UUID
    cycle_mode: CreditCycleMode
    statement_day: int
    due_day: int
    affected_cycle_count: int
    purchase_count: int
    repayment_count: int
    installment_period_count: int
    conflicts: list[str] = []
