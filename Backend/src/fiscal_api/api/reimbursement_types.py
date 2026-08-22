from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel, ConfigDict

from fiscal_api.db.models import ReimbursementClaimStatus, ReimbursementRelationRole


class ReimbursementRelation(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)
    role: ReimbursementRelationRole
    claim_id: UUID
    claim_title: str
    claim_status: ReimbursementClaimStatus
    party_id: UUID | None
    party_name: str | None
    receipt_id: UUID | None
    allocated_minor: int
    received_minor: int
    outstanding_minor: int
