from __future__ import annotations

import asyncio
from os import environ

import pytest
from sqlalchemy import text

from fiscal_api.db.session import create_engine
from test_v230_core_postgres import AUTH, account, post, setup
from test_v230_core_postgres import api as api

pytestmark = pytest.mark.skipif(
    environ.get("FISCAL_TEST_DATABASE_URL") is None, reason="requires isolated PostgreSQL"
)


def _legacy_opening(account_id: str, amount: int) -> None:
    async def seed() -> None:
        engine = create_engine(environ["FISCAL_TEST_DATABASE_URL"])
        try:
            async with engine.begin() as connection:
                await connection.execute(
                    text(
                        "UPDATE accounts SET opening_balance_minor=:amount, "
                        "opening_balance_as_of_date=NULL, opening_due_date=NULL WHERE id=:id"
                    ),
                    {"id": account_id, "amount": amount},
                )
        finally:
            await engine.dispose()

    asyncio.run(seed())


def _facts(api):
    response = api.get("/api/v1/reports/facts", headers=AUTH)
    assert response.status_code == 200, response.text
    return response.json()


def test_legacy_fixed_opening_debt_is_disclosed_without_inventing_due_date(api):
    _, credit = setup(api, fixed=True)
    _legacy_opening(credit["id"], 500000)
    facts = _facts(api)
    assert facts["credit"]["current_debt_minor"] == 500000
    assert facts["disposable"]["unscheduled_credit_debt_minor"] == 500000
    assert facts["disposable"]["expected_outflow_minor"] == 0
    assert facts["disposable"]["projected_balance_minor"] == 100000
    assert facts["disposable"]["overdue_outflow_minor"] == 0
    debt = api.get("/api/v1/reports/debt", headers=AUTH).json()
    assert debt["accounts"][0]["opening_configuration_required"] is True
    assert debt["cycles"] == []


def test_only_uncovered_debt_is_disclosed_and_configuring_dates_moves_it_to_outflow(api):
    _, credit = setup(api, fixed=True)
    post(
        api,
        "/transactions",
        {
            "kind": "credit_purchase",
            "amount_minor": 20000,
            "occurred_at": "2026-07-05T12:00:00+08:00",
            "title": "Synthetic known due purchase",
            "account_id": credit["id"],
        },
        status=201,
    )
    _legacy_opening(credit["id"], 500000)
    account(
        api,
        "Synthetic on-demand",
        "credit",
        10000,
        cycle_mode="on_demand",
        opening_balance_as_of_date="2026-07-01",
    )
    before = _facts(api)["disposable"]
    assert before["unscheduled_credit_debt_minor"] == 510000
    assert before["expected_outflow_minor"] == 20000
    current = api.get(f"/api/v1/accounts/{credit['id']}", headers=AUTH).json()
    changed = api.patch(
        f"/api/v1/accounts/{credit['id']}",
        headers=AUTH,
        json={
            "expected_version": current["version"],
            "opening_balance_as_of_date": "2026-07-01",
            "opening_due_date": "2026-07-20",
        },
    )
    assert changed.status_code == 200, changed.text
    after = _facts(api)["disposable"]
    assert after["unscheduled_credit_debt_minor"] == 10000
    assert after["expected_outflow_minor"] == 520000
    assert after["projected_balance_minor"] == after["current_cash_minor"] - 520000


@pytest.mark.parametrize(
    ("due_date", "expected_outflow", "expected_overdue"),
    [("2026-07-01", 0, 10000), ("2026-07-20", 10000, 0), ("2026-09-22", 0, 0)],
)
def test_dated_debt_inside_outside_or_before_window_is_not_unscheduled(
    api, due_date, expected_outflow, expected_overdue
):
    account(
        api,
        "Synthetic dated debt",
        "credit",
        10000,
        credit_limit_minor=100000,
        statement_day=10,
        due_day=22,
        opening_balance_as_of_date="2026-07-01",
        opening_due_date=due_date,
    )
    disposable = _facts(api)["disposable"]
    assert disposable["unscheduled_credit_debt_minor"] == 0
    assert disposable["expected_outflow_minor"] == expected_outflow
    assert disposable["overdue_outflow_minor"] == expected_overdue
