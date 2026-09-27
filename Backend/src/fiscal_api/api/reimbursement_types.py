from __future__ import annotations

from typing import Any, cast
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from fiscal_api.db.models import ReimbursementClaimStatus, ReimbursementRelationRole


class ReimbursementRelation(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)
    role: ReimbursementRelationRole
    claim_id: UUID
    claim_title: str
    claim_status: ReimbursementClaimStatus
    counterparty_name: str
    receipt_id: UUID | None
    allocated_minor: int
    received_minor: int
    outstanding_minor: int


def adapt_legacy_transaction_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    """Translate retired party fields only when reading immutable revisions."""
    raw_relations = snapshot.get("reimbursement_relations")
    if not isinstance(raw_relations, list):
        return snapshot
    relations = cast(list[Any], raw_relations)
    converted: list[Any] = []
    changed = False
    for raw_relation in relations:
        if not isinstance(raw_relation, dict):
            converted.append(raw_relation)
            continue
        relation = cast(dict[str, Any], raw_relation)
        if "party_id" not in relation and "party_name" not in relation:
            converted.append(relation)
            continue
        changed = True
        current = {
            key: value for key, value in relation.items() if key not in {"party_id", "party_name"}
        }
        if "counterparty_name" not in current and "party_name" in relation:
            current["counterparty_name"] = relation["party_name"]
        converted.append(current)
    if not changed:
        return snapshot
    return {**snapshot, "reimbursement_relations": converted}
