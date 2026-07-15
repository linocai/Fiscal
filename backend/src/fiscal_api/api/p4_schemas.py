from datetime import date, datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from fiscal_api.db.models import CreditCycleStatus


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
    current_cycle: CreditCycleResponse
    next_due_cycle: CreditCycleResponse | None
    has_overdue_cycle: bool
