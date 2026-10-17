from datetime import UTC, datetime, timedelta
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_receipt_and_cancel_replay_with_a_fresh_preview_token() -> None:
    """An identical retry with the same Idempotency-Key returns the original
    result even though the single-use preview token differs."""
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer build58-token"}
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        account = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={"name": f"B58 银行 {suffix}", "kind": "debit", "opening_balance_minor": 100000},
        ).json()
        category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"B58 差旅 {suffix}",
                "direction": "expense",
                "icon": "tag",
                "color_hex": "#445566",
            },
        ).json()
        expense = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "expense",
                "amount_minor": 30000,
                "occurred_at": "2026-07-15T08:00:00+08:00",
                "title": "B58 酒店",
                "account_id": account["id"],
                "category_id": category["id"],
            },
        ).json()
        claim = client.post(
            "/api/v1/reimbursement-claims",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "title": "B58 出差",
                "counterparty_name": "公司",
                "expenses": [{"transaction_id": expense["id"], "amount_minor": 20000}],
            },
        ).json()
        claim = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/submit",
            headers=auth,
            json={"expected_version": claim["version"]},
        ).json()
        draft = {
            "expected_claim_version": claim["version"],
            "amount_minor": 12000,
            "received_at": (datetime.now(UTC) - timedelta(seconds=1)).isoformat(),
            "destination_account_id": account["id"],
            "title": "B58 公司回款",
        }
        receipt_key = str(uuid4())
        preview = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/receipt-preview", headers=auth, json=draft
        )
        assert preview.status_code == 200, preview.text
        first = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/receipts",
            headers={**auth, "Idempotency-Key": receipt_key},
            json={**draft, "preview_token": preview.json()["preview_token"]},
        )
        assert first.status_code == 201, first.text

        # The original preview version is now stale, so a retry cannot re-preview...
        stale = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/receipt-preview", headers=auth, json=draft
        )
        assert stale.status_code == 409
        # ...but replaying the commit with any preview token returns the original receipt.
        replay = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/receipts",
            headers={**auth, "Idempotency-Key": receipt_key},
            json={**draft, "preview_token": str(uuid4())},
        )
        assert replay.status_code == 201, replay.text
        assert replay.json()["id"] == first.json()["id"]
        changed = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/receipts",
            headers={**auth, "Idempotency-Key": receipt_key},
            json={**draft, "amount_minor": 1000, "preview_token": str(uuid4())},
        )
        assert changed.status_code == 409
        assert changed.json()["error"]["code"] == "idempotency_key_reused"
        balance = client.get(f"/api/v1/accounts/{account['id']}", headers=auth).json()
        assert balance["current_balance_minor"] == 100000 - 30000 + 12000

        current = client.get(f"/api/v1/reimbursement-claims/{claim['id']}", headers=auth).json()
        cancel_key = str(uuid4())
        cancel_preview = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/cancel-preview",
            headers=auth,
            json={"expected_version": current["version"]},
        )
        assert cancel_preview.status_code == 200, cancel_preview.text
        cancel_request = {"expected_version": current["version"]}
        cancelled = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/cancel-outstanding",
            headers={**auth, "Idempotency-Key": cancel_key},
            json={**cancel_request, "preview_token": cancel_preview.json()["preview_token"]},
        )
        assert cancelled.status_code == 200, cancelled.text
        assert cancelled.json()["status"] == "partially_received_cancelled"
        cancel_replay = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/cancel-outstanding",
            headers={**auth, "Idempotency-Key": cancel_key},
            json={**cancel_request, "preview_token": str(uuid4())},
        )
        assert cancel_replay.status_code == 200, cancel_replay.text
        assert cancel_replay.json()["version"] == cancelled.json()["version"]
