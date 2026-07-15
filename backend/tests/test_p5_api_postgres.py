from datetime import date
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app
from fiscal_api.services.installments import InstallmentService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(
    TEST_DATABASE_URL is None,
    reason="requires a migrated disposable PostgreSQL database",
)


def test_all_installment_http_gates() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(
            environment="test",
            database_url=TEST_DATABASE_URL,
            device_token=SecretStr("p5-api-token"),
        ),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer p5-api-token"}
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        payment = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"P5 储蓄卡 {suffix}",
                "kind": "debit",
                "opening_balance_minor": 1_000_000,
            },
        ).json()
        credit = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"P5 信用卡 {suffix}",
                "kind": "credit",
                "opening_balance_minor": 0,
                "credit_limit_minor": 1_000_000,
                "statement_day": 10,
                "due_day": 20,
            },
        ).json()
        category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"P5 电子产品 {suffix}",
                "direction": "expense",
                "icon": "laptopcomputer",
                "color_hex": "#AA5500",
            },
        ).json()
        purchase = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "credit_purchase",
                "amount_minor": 329_900,
                "occurred_at": "2026-07-15T08:00:00+08:00",
                "title": "Mac",
                "account_id": credit["id"],
                "category_id": category["id"],
            },
        ).json()
        eligibility = client.get(
            f"/api/v1/transactions/{purchase['id']}/installment-eligibility",
            headers=auth,
        )
        assert eligibility.status_code == 200 and eligibility.json()["eligible"]
        options = client.get(
            "/api/v1/installment-cycle-options",
            headers=auth,
            params={"purchase_transaction_id": purchase["id"], "months": 6},
        )
        assert options.status_code == 200 and len(options.json()) == 6
        created = client.post(
            "/api/v1/installment-plans",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "purchase_transaction_id": purchase["id"],
                "installment_count": 6,
                "total_fee_minor": 10_000,
                "fee_category_id": category["id"],
                "fee_occurred_at": "2026-07-15T09:00:00+08:00",
                "start_statement_date": "2026-08-10",
            },
        )
        assert created.status_code == 201, created.text
        plan = created.json()
        plan_id = plan["id"]
        locked_repayment = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "repayment",
                "amount_minor": plan["periods"][0]["amount_due_minor"],
                "occurred_at": "2026-07-15T09:30:00+08:00",
                "title": "锁定首期",
                "account_id": payment["id"],
                "destination_account_id": credit["id"],
                "credit_cycle_id": plan["periods"][0]["effective_cycle_id"],
            },
        )
        assert locked_repayment.status_code == 201, locked_repayment.text
        existing_plan_options = client.get(
            "/api/v1/installment-cycle-options",
            headers=auth,
            params={"purchase_transaction_id": purchase["id"], "months": 6},
        )
        assert existing_plan_options.status_code == 200, existing_plan_options.text
        assert len(existing_plan_options.json()) == 6
        assert client.get(f"/api/v1/installment-plans/{plan_id}", headers=auth).status_code == 200
        assert client.get("/api/v1/installment-plans", headers=auth).status_code == 200
        assert (
            client.get(
                "/api/v1/installment-liabilities",
                headers=auth,
                params={"account_id": credit["id"]},
            ).status_code
            == 200
        )
        replacement = {
            "expected_version": plan["version"],
            "purchase": {
                "amount_minor": 329_900,
                "occurred_at": purchase["occurred_at"],
                "title": "MacBook",
                "note": None,
                "account_id": credit["id"],
                "category_id": category["id"],
            },
            "installment_count": 7,
            "total_fee_minor": 10_000,
            "fee_category_id": category["id"],
            "fee_occurred_at": plan["fee_occurred_at"],
            "start_statement_date": plan["start_statement_date"],
        }
        assert (
            client.post(
                f"/api/v1/installment-plans/{plan_id}/preview",
                headers=auth,
                json=replacement,
            ).status_code
            == 200
        )
        updated = client.put(f"/api/v1/installment-plans/{plan_id}", headers=auth, json=replacement)
        assert updated.status_code == 200, updated.text
        plan = updated.json()
        assert plan["locked_count"] == 1
        assert plan["installment_count"] == 7
        settlement = {
            "expected_version": plan["version"],
            "payment_account_id": payment["id"],
            "target_statement_date": "2026-09-10",
            "occurred_at": "2026-07-15T10:00:00+08:00",
        }
        assert (
            client.post(
                f"/api/v1/installment-plans/{plan_id}/settlement-preview",
                headers=auth,
                json=settlement,
            ).status_code
            == 200
        )
        settled = client.post(
            f"/api/v1/installment-plans/{plan_id}/settle-early",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json=settlement,
        )
        assert settled.status_code == 200, settled.text
        reverse = {
            "expected_version": settled.json()["plan"]["version"],
            "occurred_at": "2026-07-15T11:00:00+08:00",
        }
        assert (
            client.post(
                f"/api/v1/installment-plans/{plan_id}/reverse-settlement-preview",
                headers=auth,
                json=reverse,
            ).status_code
            == 200
        )
        reversed_result = client.post(
            f"/api/v1/installment-plans/{plan_id}/reverse-settlement",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json=reverse,
        )
        assert reversed_result.status_code == 200, reversed_result.text
        cancel = {
            "expected_version": reversed_result.json()["plan"]["version"],
            "occurred_at": "2026-07-15T12:00:00+08:00",
        }
        assert (
            client.post(
                f"/api/v1/installment-plans/{plan_id}/cancel-preview",
                headers=auth,
                json=cancel,
            ).status_code
            == 200
        )
        cancelled = client.post(
            f"/api/v1/installment-plans/{plan_id}/cancel-future",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json=cancel,
        )
        assert cancelled.status_code == 200, cancelled.text


def test_historical_purchase_options_roll_to_future_and_settlement_preview(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(
            environment="test",
            database_url=TEST_DATABASE_URL,
            device_token=SecretStr("p5-history-token"),
        ),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer p5-history-token"}
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        payment = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"历史付款 {suffix}",
                "kind": "debit",
                "opening_balance_minor": 100_000,
            },
        ).json()
        credit = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"历史信用卡 {suffix}",
                "kind": "credit",
                "opening_balance_minor": 0,
                "credit_limit_minor": 100_000,
                "statement_day": 10,
                "due_day": 20,
            },
        ).json()
        category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"历史分类 {suffix}",
                "direction": "expense",
                "icon": "clock",
                "color_hex": "#CC5500",
            },
        ).json()
        purchase = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "credit_purchase",
                "amount_minor": 6_000,
                "occurred_at": "2026-07-15T08:00:00+08:00",
                "title": "六十个月前消费",
                "account_id": credit["id"],
                "category_id": category["id"],
            },
        ).json()
        plan_response = client.post(
            "/api/v1/installment-plans",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "purchase_transaction_id": purchase["id"],
                "installment_count": 60,
                "total_fee_minor": 0,
                "fee_category_id": None,
                "fee_occurred_at": None,
                "start_statement_date": "2027-08-10",
            },
        )
        assert plan_response.status_code == 201, plan_response.text
        plan = plan_response.json()
        for period in plan["periods"]:
            if period["effective_statement_date"] >= "2031-08-01":
                continue
            repayment = client.post(
                "/api/v1/transactions",
                headers={**auth, "Idempotency-Key": str(uuid4())},
                json={
                    "kind": "repayment",
                    "amount_minor": period["amount_due_minor"],
                    "occurred_at": "2031-07-31T08:00:00+08:00",
                    "title": f"历史期次 {period['sequence']}",
                    "account_id": payment["id"],
                    "destination_account_id": credit["id"],
                    "credit_cycle_id": period["effective_cycle_id"],
                },
            )
            assert repayment.status_code == 201, repayment.text
        monkeypatch.setattr(
            InstallmentService,
            "_today",
            staticmethod(lambda: date(2031, 8, 1)),
        )
        options = client.get(
            "/api/v1/installment-cycle-options",
            headers=auth,
            params={"purchase_transaction_id": purchase["id"], "months": 60},
        )
        assert options.status_code == 200, options.text
        assert options.json()[0]["statement_date"] == "2031-08-10"
        assert all(item["eligible"] for item in options.json())
        preview = client.post(
            f"/api/v1/installment-plans/{plan['id']}/settlement-preview",
            headers=auth,
            json={
                "expected_version": plan["version"],
                "payment_account_id": payment["id"],
                "target_statement_date": "2031-08-10",
                "occurred_at": "2031-08-01T08:00:00+08:00",
            },
        )
        assert preview.status_code == 200, preview.text
        assert preview.json()["proposed_plan"]["start_statement_date"] == "2027-08-10"
