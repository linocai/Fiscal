from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(
    TEST_DATABASE_URL is None,
    reason="requires a migrated disposable PostgreSQL database",
)


def test_real_api_credit_purchase_and_repayment_smoke() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(
            environment="test",
            database_url=TEST_DATABASE_URL,
            device_token=SecretStr("p4-api-token"),
        ),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer p4-api-token"}
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        payment = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"API 储蓄卡 {suffix}",
                "kind": "debit",
                "opening_balance_minor": 100000,
            },
        )
        assert payment.status_code == 201
        credit = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"API 信用卡 {suffix}",
                "kind": "credit",
                "opening_balance_minor": 0,
                "credit_limit_minor": 10000,
                "statement_day": 10,
                "due_day": 22,
            },
        )
        assert credit.status_code == 201
        category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"API 餐饮 {suffix}",
                "direction": "expense",
                "icon": "fork.knife",
                "color_hex": "#AA5500",
            },
        )
        assert category.status_code == 201

        purchase = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "credit_purchase",
                "amount_minor": 2000,
                "occurred_at": "2026-07-15T12:00:00+08:00",
                "title": "API 信用消费",
                "account_id": credit.json()["id"],
                "category_id": category.json()["id"],
            },
        )
        assert purchase.status_code == 201
        cycle_id = purchase.json()["credit_cycle_id"]
        repayment = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "repayment",
                "amount_minor": 500,
                "occurred_at": "2026-07-16T12:00:00+08:00",
                "title": "API 还款",
                "account_id": payment.json()["id"],
                "destination_account_id": credit.json()["id"],
                "credit_cycle_id": cycle_id,
            },
        )
        assert repayment.status_code == 201
        cycle = client.get(f"/api/v1/credit-cycles/{cycle_id}", headers=auth)
        assert cycle.status_code == 200
        assert (cycle.json()["amount_due_minor"], cycle.json()["repaid_minor"]) == (2000, 500)
        credit_summary = client.get(f"/api/v1/credit-accounts/{credit.json()['id']}", headers=auth)
        assert credit_summary.json()["current_debt_minor"] == 1500
        assert (
            client.get(f"/api/v1/accounts/{payment.json()['id']}", headers=auth).json()[
                "current_balance_minor"
            ]
            == 99500
        )
        summary = client.get("/api/v1/transactions/summary", headers=auth)
        own_category = next(
            item
            for item in summary.json()["by_category"]
            if item["category_id"] == category.json()["id"]
        )
        assert own_category["amount_minor"] == 2000
