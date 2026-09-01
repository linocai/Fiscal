from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_real_report_api_smoke(monkeypatch: pytest.MonkeyPatch) -> None:
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
    auth = {"Authorization": "Bearer p7-api-token"}
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        account = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"P7 银行 {suffix}",
                "kind": "debit",
                "opening_balance_minor": 10_000,
            },
        )
        assert account.status_code == 201, account.text
        category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"P7 餐饮 {suffix}",
                "direction": "expense",
                "icon": "fork.knife",
                "color_hex": "#334455",
            },
        )
        assert category.status_code == 201, category.text
        expense = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "expense",
                "amount_minor": 1_234,
                "occurred_at": "2020-01-15T00:00:00+08:00",
                "title": "P7 API 午餐",
                "account_id": account.json()["id"],
                "category_id": category.json()["id"],
            },
        )
        assert expense.status_code == 201, expense.text

        spending = client.get(
            "/api/v1/reports/spending?date_from=2020-01-15&date_to=2020-01-15",
            headers=auth,
        )
        assert spending.status_code == 200, spending.text
        assert spending.json()["gross_consumption_minor"] == 1_234
        assert spending.json()["trend"][0]["date"] == "2020-01-15"

        cash = client.get(
            "/api/v1/reports/cash-flow?date_from=2020-01-15&date_to=2020-01-15&today=2026-07-15",
            headers=auth,
        )
        assert cash.status_code == 200, cash.text
        assert cash.json()["outflow_minor"] == 1_234

        overview = client.get("/api/v1/reports/overview?month=2020-01", headers=auth)
        assert overview.status_code == 200, overview.text
        assert overview.json()["spending"]["gross_consumption_minor"] == 1_234

        facts = client.get(
            "/api/v1/reports/facts?window_days=30",
            headers=auth,
        )
        assert facts.status_code == 200, facts.text
        assert facts.json()["meta"]["data_revision"] >= 1
        assert facts.json()["window"] == {"date_from": "2026-07-15", "date_to": "2026-08-13"}
        assert facts.json()["cash"]["current_balance_minor"] == 8_766
        assert facts.json()["completeness"]["open_reconciliation_difference_count"] == 0
        assert facts.json()["completeness"]["last_reconciled_at"] is None
        assert facts.json()["future"]["after_confirmed_outflow_minor"] == 8_766
        assert facts.json()["known_future_events"] == []
        future = client.get(
            "/api/v1/reports/future-events?window_days=7&limit=1",
            headers=auth,
        )
        assert future.status_code == 200, future.text
        assert future.json()["window"] == {"date_from": "2026-07-15", "date_to": "2026-07-21"}
        assert future.json()["items"] == []
        assert future.json()["next_cursor"] is None
        cash_scope = facts.json()["cash"]["scope"]
        assert cash_scope["schema_version"] == "1"
        assert cash_scope["expected_data_revision"] == facts.json()["meta"]["data_revision"]
        cash_details = client.get(cash_scope["read_path"], headers=auth)
        assert cash_details.status_code == 200, cash_details.text
        assert cash_details.json()["scope"] == cash_scope
        assert (
            sum(item["current_balance_minor"] for item in cash_details.json()["items"])
            == facts.json()["cash"]["current_balance_minor"]
        )
        assert all("last_four" not in item for item in cash_details.json()["items"])
        assert all(item["last_reconciled_at"] is None for item in cash_details.json()["items"])
        stale_scope = client.get(
            "/api/v1/reports/facts/drill-down?scope=cash_accounts"
            f"&expected_data_revision={cash_scope['expected_data_revision'] + 1}",
            headers=auth,
        )
        assert stale_scope.status_code == 409, stale_scope.text
        assert stale_scope.json()["error"]["code"] == "report_facts_scope_changed"

        drill = client.get(
            "/api/v1/reports/drill-down?lens=spending&date_from=2020-01-15"
            f"&date_to=2020-01-15&category_id={category.json()['id']}",
            headers=auth,
        )
        assert drill.status_code == 200, drill.text
        assert [item["transaction_id"] for item in drill.json()["items"]] == [expense.json()["id"]]

        debt = client.get("/api/v1/reports/debt?as_of=2026-07-15", headers=auth)
        assert debt.status_code == 200, debt.text
