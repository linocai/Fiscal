import csv
import io
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_p10_filter_bulk_and_csv_api() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(
            environment="test",
            database_url=TEST_DATABASE_URL,
            device_token=SecretStr("p10-api-token"),
        ),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer p10-api-token"}
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        account = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"P10 搜索账户 {suffix}",
                "kind": "debit",
                "opening_balance_minor": 100_000,
            },
        )
        old_category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"P10 旧分类 {suffix}",
                "direction": "expense",
                "icon": "tag",
                "color_hex": "#334455",
            },
        )
        target = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"P10 新分类 {suffix}",
                "direction": "expense",
                "icon": "tag.fill",
                "color_hex": "#445566",
            },
        )
        assert account.status_code == old_category.status_code == target.status_code == 201
        created = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "expense",
                "amount_minor": 456,
                "occurred_at": "2026-07-16T12:00:00+08:00",
                "title": "@P10 CSV",
                "account_id": account.json()["id"],
                "category_id": old_category.json()["id"],
            },
        )
        assert created.status_code == 201, created.text
        uncategorized = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "expense",
                "amount_minor": 789,
                "occurred_at": "2026-07-16T12:01:00+08:00",
                "title": "P10 待归类入口",
                "account_id": account.json()["id"],
            },
        )
        assert uncategorized.status_code == 201, uncategorized.text
        inbox = client.get("/api/v1/transactions?classification=uncategorized", headers=auth)
        assert inbox.status_code == 200, inbox.text
        assert [item["id"] for item in inbox.json()["items"]] == [uncategorized.json()["id"]]
        assert inbox.json()["items"][0]["category_id"] is None

        searched = client.get(
            headers=auth,
            url="/api/v1/transactions",
            params={
                "query": f"P10 搜索账户 {suffix}",
                "amount_min_minor": 456,
                "amount_max_minor": 456,
                "classification": "categorized",
                "source": "manual",
            },
        )
        assert searched.status_code == 200, searched.text
        assert [item["id"] for item in searched.json()["items"]] == [created.json()["id"]]
        cursor_page = client.get("/api/v1/transactions?limit=1", headers=auth)
        cursor = cursor_page.json()["next_cursor"]
        if cursor is not None:
            mismatch = client.get(
                f"/api/v1/transactions?limit=1&kind=expense&cursor={cursor}", headers=auth
            )
            assert mismatch.status_code == 422
            assert mismatch.json()["error"]["code"] == "invalid_transaction_cursor"

        changed = client.post(
            "/api/v1/transactions/bulk-category",
            headers=auth,
            json={
                "items": [
                    {
                        "transaction_id": created.json()["id"],
                        "expected_version": created.json()["version"],
                    }
                ],
                "category_id": target.json()["id"],
            },
        )
        assert changed.status_code == 200, changed.text
        assert changed.json()["changed_count"] == 1
        assert changed.json()["items"][0]["category_id"] == target.json()["id"]

        exported = client.get(
            f"/api/v1/transactions/export.csv?category_id={target.json()['id']}", headers=auth
        )
        assert exported.status_code == 200, exported.text
        assert exported.headers["content-type"].startswith("text/csv")
        assert "fiscal-transactions-v1.csv" in exported.headers["content-disposition"]
        rows = list(csv.reader(io.StringIO(exported.text)))
        assert rows[0] == ["# Fiscal Transactions CSV schema=v1"]
        assert rows[1][0:4] == ["id", "kind", "amount_minor", "currency"]
        assert rows[2][0] == created.json()["id"]
        assert rows[2][6] == "'@P10 CSV"


def test_p10_api_rejects_duplicate_batch_and_invalid_amount_range() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(
            environment="test",
            database_url=TEST_DATABASE_URL,
            device_token=SecretStr("p10-policy-token"),
        ),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer p10-policy-token"}
    transaction_id = str(uuid4())
    with TestClient(app) as client:
        duplicate = client.post(
            "/api/v1/transactions/bulk-category",
            headers=auth,
            json={
                "items": [
                    {"transaction_id": transaction_id, "expected_version": 1},
                    {"transaction_id": transaction_id, "expected_version": 1},
                ],
                "category_id": str(uuid4()),
            },
        )
        assert duplicate.status_code == 422
        invalid_range = client.get(
            "/api/v1/transactions?amount_min_minor=200&amount_max_minor=100", headers=auth
        )
        assert invalid_range.status_code == 422
        assert invalid_range.json()["error"]["code"] == "invalid_transaction_configuration"
