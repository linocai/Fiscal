from datetime import UTC, datetime
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_p21_checkpoint_is_derived_and_attention_is_dismissible(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    # This fixture models an August 2026 reconciliation. Keep its expiry
    # relative to that business clock rather than the test runner's wall time.
    monkeypatch.setattr(
        "fiscal_api.services.reconciliation.utc_now",
        lambda: datetime(2026, 8, 11, 12, tzinfo=UTC),
    )

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(environment="test", database_url=TEST_DATABASE_URL), readiness_check=ready
    )
    auth = {"Authorization": "Bearer p21-token"}
    with TestClient(app) as client:
        account = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"P21 {uuid4().hex[:8]}",
                "kind": "debit",
                "opening_balance_minor": 10000,
            },
        )
        assert account.status_code == 201, account.text
        checkpoint = client.post(
            "/api/v1/reconciliation/checkpoints",
            headers=auth,
            json={
                "target_kind": "account",
                "account_id": account.json()["id"],
                "as_of": "2026-08-11T12:00:00+08:00",
                "actual_balance_minor": 10000,
                "note": "bank app",
            },
        )
        assert checkpoint.status_code == 201, checkpoint.text
        assert checkpoint.json()["state"] == "reconciled"
        before = client.get(f"/api/v1/accounts/{account.json()['id']}", headers=auth).json()[
            "current_balance_minor"
        ]
        category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"P21 cat {uuid4().hex[:8]}",
                "direction": "expense",
                "icon": "tag",
                "color_hex": "#123456",
            },
        ).json()
        tx = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "expense",
                "amount_minor": 500,
                "occurred_at": "2026-08-11T11:00:00+08:00",
                "title": "P21 backfill",
                "account_id": account.json()["id"],
                "category_id": category["id"],
            },
        )
        assert tx.status_code == 201, tx.text
        checkpoints = client.get(
            "/api/v1/reconciliation/checkpoints",
            headers=auth,
            params={"account_id": account.json()["id"]},
        )
        assert checkpoints.status_code == 200
        assert checkpoints.json()[0]["difference_minor"] == 500
        assert checkpoints.json()[0]["state"] == "open"
        assert (
            client.get(f"/api/v1/accounts/{account.json()['id']}", headers=auth).json()[
                "current_balance_minor"
            ]
            == before - 500
        )
        attention = client.get("/api/v1/reconciliation/attention", headers=auth)
        item = next(
            row
            for row in attention.json()["items"]
            if row["source_type"] == "reconciliation_checkpoint"
        )
        ignored = client.post(
            f"/api/v1/reconciliation/attention/{item['source_type']}/{item['source_id']}/ignore",
            headers=auth,
            json={"expires_at": "2026-08-12T12:00:00+08:00"},
        )
        assert ignored.status_code == 204
        assert all(
            row["source_id"] != item["source_id"]
            for row in client.get("/api/v1/reconciliation/attention", headers=auth).json()["items"]
        )
