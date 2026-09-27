"""Old party-shaped revision JSON remains readable after 0042."""

from __future__ import annotations

from copy import deepcopy
from uuid import uuid4

import pytest
from pydantic import ValidationError

from fiscal_api.api.p3_schemas import TransactionResponse
from fiscal_api.api.p6_schemas import (
    ReimbursementClaimResponse,
    ReimbursementReceiptResponse,
    adapt_legacy_reimbursement_receipt_snapshot,
    adapt_legacy_reimbursement_snapshot,
)
from fiscal_api.api.reimbursement_types import (
    ReimbursementRelation,
    adapt_legacy_transaction_snapshot,
)

AT = "2024-03-10T12:00:00+08:00"


def _old_snapshots() -> tuple[dict[str, object], dict[str, object], dict[str, object]]:
    claim_id, party_id, receipt_id, allocation_id = (str(uuid4()) for _ in range(4))
    account_id, transaction_id, expense_id = (str(uuid4()) for _ in range(3))
    transaction: dict[str, object] = {
        "id": transaction_id,
        "kind": "reimbursement_receipt",
        "amount_minor": 600,
        "occurred_at": AT,
        "business_date": "2024-03-10",
        "title": "Synthetic receipt",
        "note": None,
        "category_id": None,
        "account_id": account_id,
        "destination_account_id": None,
        "credit_cycle_id": None,
        "source": "system",
        "postings": [
            {
                "id": str(uuid4()),
                "account_id": account_id,
                "role": "account",
                "amount_minor": 600,
                "position": 0,
            }
        ],
        "version": 1,
        "voided_at": None,
        "created_at": AT,
        "updated_at": AT,
        "reimbursement_relations": [
            {
                "role": "receipt",
                "claim_id": claim_id,
                "claim_title": "Synthetic claim",
                "claim_status": "partial_received",
                "party_id": party_id,
                "party_name": "Synthetic payer",
                "receipt_id": receipt_id,
                "allocated_minor": 600,
                "received_minor": 600,
                "outstanding_minor": 0,
            }
        ],
        "available_actions": [],
    }
    receipt: dict[str, object] = {
        "id": receipt_id,
        "claim_id": claim_id,
        "party_id": party_id,
        "amount_minor": 600,
        "received_at": AT,
        "destination_account_id": account_id,
        "title": "Synthetic receipt",
        "note": None,
        "transaction": transaction,
        "allocations": [
            {
                "id": str(uuid4()),
                "allocation_id": allocation_id,
                "amount_minor": 600,
                "position": 0,
            }
        ],
        "version": 1,
        "voided_at": None,
        "created_at": AT,
        "updated_at": AT,
    }
    claim: dict[str, object] = {
        "id": claim_id,
        "title": "Synthetic claim",
        "note": None,
        "status": "partial_received",
        "total_claimed_minor": 1200,
        "received_minor": 600,
        "outstanding_minor": 600,
        "expense_count": 1,
        "receipt_count": 1,
        "parties": [
            {
                "id": party_id,
                "name": "Synthetic payer",
                "expected_date": "2024-03-31",
                "allocations": [
                    {
                        "id": allocation_id,
                        "transaction_id": expense_id,
                        "expense_title": "Synthetic expense",
                        "expense_amount_minor": 1200,
                        "amount_minor": 1200,
                        "received_minor": 600,
                        "outstanding_minor": 600,
                        "locked": False,
                        "position": 0,
                    }
                ],
            }
        ],
        "party_count": 1,
        "latest_receipt": receipt,
        "version": 2,
        "submitted_at": AT,
        "cancelled_at": None,
        "voided_at": None,
        "archived_at": None,
        "created_at": AT,
        "updated_at": AT,
    }
    return claim, receipt, transaction


def test_old_claim_receipt_and_transaction_revisions_are_read_without_mutation() -> None:
    claim, receipt, transaction = _old_snapshots()
    original = deepcopy((claim, receipt, transaction))

    with pytest.raises(ValidationError):
        ReimbursementRelation.model_validate(transaction["reimbursement_relations"][0])

    adapted_claim = adapt_legacy_reimbursement_snapshot(claim)
    parsed_claim = ReimbursementClaimResponse.model_validate(adapted_claim)
    parsed_receipt = ReimbursementReceiptResponse.model_validate(
        adapt_legacy_reimbursement_receipt_snapshot(receipt)
    )
    parsed_transaction = TransactionResponse.model_validate(
        adapt_legacy_transaction_snapshot(transaction)
    )

    assert parsed_claim.counterparty_name == "Synthetic payer"
    assert parsed_claim.outstanding_minor == 600
    assert parsed_claim.latest_receipt is not None
    assert (
        parsed_claim.latest_receipt.transaction.reimbursement_relations[0].counterparty_name
        == "Synthetic payer"
    )
    relation = parsed_claim.latest_receipt.transaction.reimbursement_relations[0]
    assert (relation.allocated_minor, relation.received_minor, relation.outstanding_minor) == (
        600,
        600,
        0,
    )
    assert parsed_receipt.amount_minor == parsed_transaction.amount_minor == 600
    assert parsed_receipt.allocations[0].amount_minor == 600
    assert parsed_transaction.postings[0].amount_minor == 600
    assert (claim, receipt, transaction) == original


def test_current_transaction_snapshot_is_unchanged_by_adapter() -> None:
    _, _, transaction = _old_snapshots()
    current = adapt_legacy_transaction_snapshot(transaction)
    assert current is not transaction
    assert isinstance(current["reimbursement_relations"], list)
    assert adapt_legacy_transaction_snapshot(current) is current
    assert TransactionResponse.model_validate(current).amount_minor == 600
