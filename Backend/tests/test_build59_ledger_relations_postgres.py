from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_ledger_list_carries_reimbursement_relations_and_claim_edit_replays() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer build59-token"}
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        account = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={"name": f"B59 银行 {suffix}", "kind": "debit", "opening_balance_minor": 500000},
        ).json()
        category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"B59 宠物 {suffix}",
                "direction": "expense",
                "icon": "tag",
                "color_hex": "#445566",
            },
        ).json()
        title = f"B59 豆豆 {suffix}"
        expense = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "expense",
                "amount_minor": 140000,
                "occurred_at": "2026-09-12T10:00:00+08:00",
                "title": title,
                "account_id": account["id"],
                "category_id": category["id"],
            },
        ).json()
        claim = client.post(
            "/api/v1/reimbursement-claims",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "title": title,
                "counterparty_name": "我",
                "expenses": [{"transaction_id": expense["id"], "amount_minor": 140000}],
            },
        ).json()

        listed = client.get(
            "/api/v1/transactions",
            headers=auth,
            params={"query": suffix, "date_from": "2026-09-01", "date_to": "2026-09-30"},
        )
        assert listed.status_code == 200, listed.text
        row = next(item for item in listed.json()["items"] if item["id"] == expense["id"])
        detail = client.get(f"/api/v1/transactions/{expense['id']}", headers=auth).json()
        assert row["reimbursement_relations"] == detail["reimbursement_relations"]
        assert [
            (rel["claim_id"], rel["counterparty_name"]) for rel in row["reimbursement_relations"]
        ] == [(claim["id"], "我")]

        allocation = claim["expenses"][0]
        draft = {
            "title": claim["title"],
            "note": claim["note"],
            "counterparty_name": "公司",
            "expected_date": claim["expected_date"],
            "expenses": [
                {
                    "id": allocation["id"],
                    "transaction_id": expense["id"],
                    "amount_minor": 140000,
                }
            ],
            "expected_version": claim["version"],
        }
        preview = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/preview", headers=auth, json=draft
        )
        assert preview.status_code == 200, preview.text
        key = str(uuid4())
        updated = client.put(
            f"/api/v1/reimbursement-claims/{claim['id']}",
            headers={**auth, "Idempotency-Key": key},
            json={**draft, "preview_token": preview.json()["preview_token"]},
        )
        assert updated.status_code == 200, updated.text
        assert updated.json()["counterparty_name"] == "公司"
        assert updated.json()["outstanding_minor"] == 140000
        replay = client.put(
            f"/api/v1/reimbursement-claims/{claim['id']}",
            headers={**auth, "Idempotency-Key": key},
            json={**draft, "preview_token": str(uuid4())},
        )
        assert replay.status_code == 200, replay.text
        assert replay.json()["version"] == updated.json()["version"]
