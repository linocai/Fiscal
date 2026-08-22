from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from fiscal_api.db.models import InstallmentLedgerRole


class InstallmentPlanStatus(StrEnum):
    ACTIVE = "active"
    COMPLETED = "completed"
    SETTLED_EARLY = "settled_early"
    PARTIALLY_CANCELLED = "partially_cancelled"
    CANCELLED = "cancelled"


class InstallmentRelation(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)

    plan_id: UUID
    role: InstallmentLedgerRole
    plan_title: str
    plan_status: InstallmentPlanStatus
