from datetime import UTC, datetime, timedelta
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app
from fiscal_api.services.archive import ArchiveService

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
        updated_expense = client.put(
            f"/api/v1/transactions/{expense.json()['id']}",
            headers=auth,
            json={
                "expected_version": expense.json()["version"],
                "kind": "expense",
                "amount_minor": 30000,
                "occurred_at": "2026-07-15T08:00:00+08:00",
                "title": "酒店垫付 updated",
                "account_id": account.json()["id"],
                "category_id": category.json()["id"],
            },
        )
        assert updated_expense.status_code == 200, updated_expense.text
        expected_void_action = {
            "action": "void",
            "enabled": False,
            "reason_code": "reimbursement_claim_in_use",
            "reason_message": "The source expense is used by a reimbursement claim",
        }
        assert updated_expense.json()["available_actions"] == [expected_void_action]
        transaction_detail = client.get(
            f"/api/v1/transactions/{expense.json()['id']}", headers=auth
        )
        assert transaction_detail.json()["available_actions"] == [expected_void_action]
        overview = client.get("/api/v1/reports/overview?month=2026-07", headers=auth)
        assert overview.status_code == 200, overview.text
        recent = next(
            item
            for item in overview.json()["recent_transactions"]
            if item["id"] == expense.json()["id"]
        )
        assert recent["available_actions"] == [expected_void_action]
        blocked_void = client.post(
            f"/api/v1/transactions/{expense.json()['id']}/void",
            headers=auth,
            json={"expected_version": updated_expense.json()["version"]},
        )
        assert blocked_void.status_code == 409
        assert blocked_void.json()["error"]["code"] == "reimbursement_claim_in_use"
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
        received_at = (datetime.now(UTC) - timedelta(seconds=1)).isoformat()
        receipt = client.post(
            f"/api/v1/reimbursement-claims/{body['id']}/receipt-preview",
            headers=auth,
            json={
                "expected_claim_version": body["version"],
                "party_id": body["parties"][0]["id"],
                "amount_minor": 12000,
                "received_at": received_at,
                "destination_account_id": account.json()["id"],
                "title": "公司回款",
            },
        )
        assert receipt.status_code == 200, receipt.text
        receipt_request = {
            "expected_claim_version": body["version"],
            "party_id": body["parties"][0]["id"],
            "amount_minor": 12000,
            "received_at": received_at,
            "destination_account_id": account.json()["id"],
            "title": "公司回款",
            "preview_token": receipt.json()["preview_token"],
        }
        receipt = client.post(
            f"/api/v1/reimbursement-claims/{body['id']}/receipts",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json=receipt_request,
        )
        assert receipt.status_code == 201, receipt.text
        assert receipt.json()["transaction"]["kind"] == "reimbursement_receipt"
        assert receipt.json()["transaction"]["reimbursement_relations"][0]["role"] == "receipt"
        password = uuid4().hex + uuid4().hex
        archive = client.post("/api/v1/archives/export", headers=auth, json={"password": password})
        assert archive.status_code == 200, archive.text
        _, archive_payload = ArchiveService.open(archive.content, password=password)
        assert "reimbursement_previews" not in archive_payload["entities"]
        assert archive_payload["entities"]["reimbursement_operations"][0]["preview_id"] is None
        detail = client.get(f"/api/v1/reimbursement-claims/{body['id']}", headers=auth)
        assert detail.json()["status"] == "partial_received"
        assert detail.json()["receipt_count"] == 1
