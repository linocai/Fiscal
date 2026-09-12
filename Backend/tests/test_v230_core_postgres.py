from __future__ import annotations

from datetime import UTC, datetime
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app
from fiscal_api.services.credit_payoffs import CreditPayoffService

URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(URL is None, reason="requires isolated PostgreSQL")
AUTH = {"Authorization": "Bearer v230-synthetic"}


@pytest.fixture
def api():
    async def ready():
        return None

    with TestClient(
        create_app(settings=Settings(environment="test", database_url=URL), readiness_check=ready),
        raise_server_exceptions=True,
    ) as client:
        yield client


def post(api, path, data, *, key=None, status=200):
    response = api.post(
        "/api/v1" + path, headers={**AUTH, "Idempotency-Key": str(key or uuid4())}, json=data
    )
    assert response.status_code == status, response.text
    return response.json()


def account(api, name, kind="debit", opening=100_000, **extra):
    return post(
        api,
        "/accounts",
        {"name": name, "kind": kind, "opening_balance_minor": opening, **extra},
        status=201,
    )


def setup(api, *, fixed=False):
    cash = account(api, "Synthetic cash")
    credit = account(
        api,
        "Synthetic debt",
        "credit",
        0,
        **(
            {"credit_limit_minor": 1_000_000, "statement_day": 10, "due_day": 22}
            if fixed
            else {"cycle_mode": "on_demand"}
        ),
    )
    return cash, credit


def borrow(api, cash, credit, *, amount=10000, when="2026-07-01T12:00:00+08:00"):
    return post(
        api,
        "/transactions",
        {
            "kind": "borrowing",
            "amount_minor": amount,
            "occurred_at": when,
            "title": "Synthetic borrowing",
            "account_id": credit["id"],
            "destination_account_id": cash["id"],
        },
        status=201,
    )


def summary(api, credit):
    response = api.get("/api/v1/credit-accounts/" + credit["id"], headers=AUTH)
    assert response.status_code == 200, response.text
    return response.json()


def request(cash, amount=10000, **extra):
    return {
        "payment_account_id": cash["id"],
        "occurred_at": "2026-09-01T12:00:00+08:00",
        "actual_amount_minor": amount,
        "bank_confirmed_settled": True,
        **extra,
    }


def payoff(api, credit, payload):
    preview = post(api, f"/credit-accounts/{credit['id']}/payoff-preview", payload)
    key = uuid4()
    commit = {**payload, "preview_token": preview["preview_token"]}
    receipt = post(api, f"/credit-accounts/{credit['id']}/payoff", commit, key=key)
    return preview, receipt, commit, key


def test_on_demand_borrow_repay_prefix_and_no_calendar(api):
    cash, credit = setup(api)
    loan = borrow(api, cash, credit)
    data = summary(api, credit)
    for field in [
        "current_cycle",
        "next_due_cycle",
        "credit_limit_minor",
        "available_credit_minor",
        "over_limit_minor",
    ]:
        assert data[field] is None
    assert data["current_debt_minor"] == 10000
    assert (
        api.get(f"/api/v1/credit-accounts/{credit['id']}/cycles", headers=AUTH).json()["items"]
        == []
    )
    draft = {
        "kind": "repayment",
        "amount_minor": 4000,
        "occurred_at": "2026-07-02T12:00:00+08:00",
        "title": "Synthetic repayment",
        "account_id": cash["id"],
        "destination_account_id": credit["id"],
    }
    post(api, "/transactions", draft, status=201)
    assert summary(api, credit)["current_debt_minor"] == 6000
    error = post(api, "/transactions", {**draft, "amount_minor": 6001}, status=409)["error"]
    assert error["details"] == {"remaining_minor": 6000, "input_minor": 6001, "difference_minor": 1}
    error = post(
        api, "/transactions", {**draft, "occurred_at": "2026-06-30T12:00:00+08:00"}, status=409
    )["error"]
    assert error["code"] == "credit_liability_predates_repayment"
    post(api, f"/transactions/{loan['id']}/void", {"expected_version": loan["version"]}, status=409)
    post(api, "/transactions", {**draft, "amount_minor": 6000}, status=201)
    borrow(api, cash, credit, amount=900)
    assert summary(api, credit)["current_debt_minor"] == 900


def test_payoff_permanent_replay_reverse_and_system_write_guard(api):
    cash, credit = setup(api)
    borrow(api, cash, credit)
    before = api.get(f"/api/v1/accounts/{cash['id']}", headers=AUTH).json()["current_balance_minor"]
    preview, receipt, commit, key = payoff(
        api,
        credit,
        request(
            cash,
            8500,
            additional_fee_minor=500,
            waived_principal_minor=2000,
            note="Bank verified waiver and fee",
        ),
    )
    assert preview["debt_before_minor"] == 10000
    assert summary(api, credit)["current_debt_minor"] == 0
    assert (
        api.get(f"/api/v1/accounts/{cash['id']}", headers=AUTH).json()["current_balance_minor"]
        == before - 8500
    )
    assert len(receipt["transaction_ids"]) == 3
    assert post(api, f"/credit-accounts/{credit['id']}/payoff", commit, key=key) == receipt
    post(
        api,
        f"/credit-accounts/{credit['id']}/payoff",
        {**commit, "note": "different"},
        key=key,
        status=409,
    )
    post(
        api,
        f"/transactions/{receipt['transaction_ids'][0]}/void",
        {"expected_version": 1},
        status=409,
    )
    assert (
        api.get(f"/api/v1/credit-accounts/{credit['id']}/payoffs", headers=AUTH).json()[0][
            "operation_id"
        ]
        == receipt["operation_id"]
    )
    reverse = post(api, f"/credit-payoffs/{receipt['operation_id']}/reverse-preview", {})
    reverse_key = uuid4()
    result = post(
        api,
        f"/credit-payoffs/{receipt['operation_id']}/reverse",
        {"preview_token": reverse["preview_token"]},
        key=reverse_key,
    )
    assert result["status"] == "reversed"
    assert summary(api, credit)["current_debt_minor"] == 10000
    assert (
        post(
            api,
            f"/credit-payoffs/{receipt['operation_id']}/reverse",
            {"preview_token": reverse["preview_token"]},
            key=reverse_key,
        )
        == result
    )


def test_payoff_changed_preview_atomic_failure_and_reverse_dependency(api, monkeypatch):
    cash, credit = setup(api)
    borrow(api, cash, credit)
    payload = request(cash, 8000, waived_principal_minor=2000, note="verified")
    preview = post(api, f"/credit-accounts/{credit['id']}/payoff-preview", payload)
    original = CreditPayoffService._write_transaction

    async def fail_second(self, operation, kind, amount, cycle_id, request, index):
        if index == 1:
            raise RuntimeError("synthetic mid-write failure")
        return await original(self, operation, kind, amount, cycle_id, request, index)

    monkeypatch.setattr(CreditPayoffService, "_write_transaction", fail_second)
    api._transport.raise_server_exceptions = False
    post(
        api,
        f"/credit-accounts/{credit['id']}/payoff",
        {**payload, "preview_token": preview["preview_token"]},
        status=500,
    )
    assert summary(api, credit)["current_debt_minor"] == 10000
    assert api.get(f"/api/v1/credit-accounts/{credit['id']}/payoffs", headers=AUTH).json() == []
    monkeypatch.setattr(CreditPayoffService, "_write_transaction", original)
    api._transport.raise_server_exceptions = True
    borrow(api, cash, credit, amount=1000)
    post(
        api,
        f"/credit-accounts/{credit['id']}/payoff",
        {**payload, "preview_token": preview["preview_token"]},
        status=409,
    )
    _, receipt, _, _ = payoff(api, credit, request(cash, 11000))
    borrow(api, cash, credit, amount=1000, when="2026-09-02T12:00:00+08:00")
    result = post(api, f"/credit-payoffs/{receipt['operation_id']}/reverse-preview", {}, status=409)
    assert result["error"]["code"] == "payoff_reverse_dependency"


def test_payoff_fixed_multiple_cycles_and_waiver_validation(api):
    cash, credit = setup(api, fixed=True)
    for date in ["2026-07-01", "2026-08-01"]:
        post(
            api,
            "/transactions",
            {
                "kind": "credit_purchase",
                "amount_minor": 5000,
                "occurred_at": date + "T12:00:00+08:00",
                "title": "Synthetic purchase",
                "account_id": credit["id"],
            },
            status=201,
        )
    post(api, f"/credit-accounts/{credit['id']}/payoff-preview", request(cash, 9900), status=422)
    post(
        api,
        f"/credit-accounts/{credit['id']}/payoff-preview",
        request(cash, 9900, waived_fee_minor=100, note="unproven fee"),
        status=422,
    )
    preview, _, _, _ = payoff(api, credit, request(cash))
    assert len(preview["allocations"]) == 2
    assert all(
        item["remaining_minor"] == 0
        for item in api.get(f"/api/v1/credit-accounts/{credit['id']}/cycles", headers=AUTH).json()[
            "items"
        ]
    )


@pytest.mark.parametrize(
    "extra",
    [
        {"credit_limit_minor": 1},
        {"due_day": 1},
        {"statement_day": 1},
        {"opening_due_date": "2026-09-01"},
        {"opening_balance_minor": 1},
    ],
)
def test_on_demand_invalid_configuration(api, extra):
    data = {
        "name": "Synthetic",
        "kind": "credit",
        "cycle_mode": "on_demand",
        "opening_balance_minor": 0,
        **extra,
    }
    post(api, "/accounts", data, status=422)


def test_payoff_installments_fee_once_and_reverse_restores_future(api, monkeypatch):
    monkeypatch.setattr(
        "fiscal_api.services.reporting.utc_now", lambda: datetime(2026, 8, 1, tzinfo=UTC)
    )
    cash, credit = setup(api, fixed=True)
    category = post(
        api,
        "/categories",
        {"name": "Synthetic fee", "direction": "expense", "icon": "star", "color_hex": "#336699"},
        status=201,
    )
    purchase = post(
        api,
        "/transactions",
        {
            "kind": "credit_purchase",
            "amount_minor": 30000,
            "occurred_at": "2026-07-15T08:00:00+08:00",
            "title": "Synthetic installment",
            "account_id": credit["id"],
            "category_id": category["id"],
        },
        status=201,
    )
    plan = post(
        api,
        "/installment-plans",
        {
            "purchase_transaction_id": purchase["id"],
            "installment_count": 3,
            "total_fee_minor": 3000,
            "fee_category_id": category["id"],
            "fee_occurred_at": "2026-07-15T09:00:00+08:00",
            "start_statement_date": "2026-08-10",
        },
        status=201,
    )
    preview, receipt, _, _ = payoff(
        api,
        credit,
        request(
            cash,
            28500,
            waived_principal_minor=3000,
            waived_fee_minor=2000,
            additional_fee_minor=500,
            note="Bank confirmed synthetic fee waiver",
        ),
    )
    assert preview["debt_before_minor"] == 33000
    assert preview["fee_minor"] == 3000
    assert sum(a["remaining_minor"] for a in preview["allocations"]) == 33000
    assert summary(api, credit)["future_scheduled_gross_minor"] == 0
    future = api.get(
        "/api/v1/reports/future-events",
        headers=AUTH,
        params={"window_days": 30, "account_id": credit["id"]},
    )
    assert future.status_code == 200, future.text
    assert future.json()["items"] == []
    current = api.get(f"/api/v1/installment-plans/{plan['id']}", headers=AUTH).json()
    assert current["status"] == "settled_early"
    reverse = post(api, f"/credit-payoffs/{receipt['operation_id']}/reverse-preview", {})
    post(
        api,
        f"/credit-payoffs/{receipt['operation_id']}/reverse",
        {"preview_token": reverse["preview_token"]},
    )
    assert summary(api, credit)["current_debt_minor"] == 33000
    restored = api.get(f"/api/v1/installment-plans/{plan['id']}", headers=AUTH).json()
    assert all(x["settled_early_at"] is None for x in restored["periods"])
