from datetime import UTC, datetime, timedelta
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_real_api_claim_and_receipt_smoke() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(
            environment="test",
            database_url=TEST_DATABASE_URL,
            device_token=SecretStr("p6-api-token"),
        ),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer p6-api-token"}
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        account = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"P6 银行 {suffix}",
                "kind": "debit",
                "opening_balance_minor": 100000,
            },
        )
        category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"P6 差旅 {suffix}",
                "direction": "expense",
                "icon": "airplane",
                "color_hex": "#445566",
            },
        )
        expense = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "expense",
                "amount_minor": 30000,
                "occurred_at": "2026-07-15T08:00:00+08:00",
                "title": "酒店垫付",
                "account_id": account.json()["id"],
                "category_id": category.json()["id"],
            },
        )
        claim = client.post(
            "/api/v1/reimbursement-claims",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "title": "出差报销",
                "parties": [
                    {
                        "name": "公司",
                        "allocations": [
                            {
                                "transaction_id": expense.json()["id"],
                                "amount_minor": 20000,
                            }
                        ],
                    }
                ],
            },
        )
        assert claim.status_code == 201, claim.text
        body = claim.json()
        invalid_receipt = {
            "expected_claim_version": body["version"],
            "party_id": body["parties"][0]["id"],
            "amount_minor": 12000,
            "received_at": (datetime.now(UTC) + timedelta(days=1)).isoformat(),
            "destination_account_id": account.json()["id"],
            "title": "未来回款",
        }
        future_preview = client.post(
            f"/api/v1/reimbursement-claims/{body['id']}/receipt-preview",
            headers=auth,
            json=invalid_receipt,
        )
        future_action = client.post(
            f"/api/v1/reimbursement-claims/{body['id']}/receipts",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json=invalid_receipt,
        )
        assert future_preview.status_code == future_action.status_code == 422
        receipt = client.post(
            f"/api/v1/reimbursement-claims/{body['id']}/receipts",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "expected_claim_version": body["version"],
                "party_id": body["parties"][0]["id"],
                "amount_minor": 12000,
                "received_at": (datetime.now(UTC) - timedelta(seconds=1)).isoformat(),
                "destination_account_id": account.json()["id"],
                "title": "公司回款",
            },
        )
        assert receipt.status_code == 201, receipt.text
        assert receipt.json()["transaction"]["kind"] == "reimbursement_receipt"
        assert receipt.json()["transaction"]["reimbursement_relations"][0]["role"] == "receipt"
        detail = client.get(f"/api/v1/reimbursement-claims/{body['id']}", headers=auth)
        assert detail.json()["status"] == "partial_received"
        assert detail.json()["receipt_count"] == 1
