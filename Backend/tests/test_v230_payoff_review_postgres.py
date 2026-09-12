from __future__ import annotations

import json
from os import environ
from pathlib import Path
from uuid import uuid4

import pytest

from test_v230_core_postgres import (
    AUTH,
    URL,
    borrow,
    payoff,
    post,
    request,
    setup,
    summary,
)
from test_v230_core_postgres import (
    api as api,
)

pytestmark = pytest.mark.skipif(URL is None, reason="requires isolated PostgreSQL")


def read_plan(api, plan):
    response = api.get(f"/api/v1/installment-plans/{plan['id']}", headers=AUTH)
    assert response.status_code == 200, response.text
    return response.json()


def seed_plan(api, credit, *, fee=0):
    category = post(
        api,
        "/categories",
        {
            "name": f"Synthetic fee {uuid4()}",
            "direction": "expense",
            "icon": "star",
            "color_hex": "#336699",
        },
        status=201,
    )
    purchase = post(
        api,
        "/transactions",
        {
            "kind": "credit_purchase",
            "amount_minor": 30000,
            "occurred_at": "2026-07-15T08:00:00+08:00",
            "title": "Synthetic history",
            "account_id": credit["id"],
            "category_id": category["id"],
        },
        status=201,
    )
    return post(
        api,
        "/installment-plans",
        {
            "purchase_transaction_id": purchase["id"],
            "installment_count": 3,
            "total_fee_minor": fee,
            "start_statement_date": "2026-08-10",
            **(
                {"fee_category_id": category["id"], "fee_occurred_at": "2026-07-15T09:00:00+08:00"}
                if fee
                else {}
            ),
        },
        status=201,
    )


def repay(api, cash, credit, cycle_id, amount):
    post(
        api,
        "/transactions",
        {
            "kind": "repayment",
            "amount_minor": amount,
            "occurred_at": "2026-08-22T12:00:00+08:00",
            "title": "Synthetic regular payment",
            "account_id": cash["id"],
            "destination_account_id": credit["id"],
            "credit_cycle_id": cycle_id,
        },
        status=201,
    )


def reverse(api, receipt):
    path = f"/credit-payoffs/{receipt['operation_id']}"
    preview = post(api, path + "/reverse-preview", {})
    body, key = {"preview_token": preview["preview_token"]}, uuid4()
    return post(api, path + "/reverse", body, key=key), body, key


@pytest.mark.parametrize("plan_count,fee,partial", [(1, 0, 0), (2, 3000, 500)])
def test_payoff_preserves_paid_period_history_and_closes_unpaid_cycles(
    api, plan_count, fee, partial
):
    cash, credit = setup(api, fixed=True)
    plans = [seed_plan(api, credit, fee=fee) for _ in range(plan_count)]
    first = plans[0]["periods"][0]
    repay(api, cash, credit, first["effective_cycle_id"], first["amount_due_minor"] * plan_count)
    if partial:
        # A fee-first partial payment does not settle this shared cycle. Every
        # plan using it remains open; no per-plan repayment allocation exists.
        repay(api, cash, credit, plans[0]["periods"][1]["effective_cycle_id"], partial)
    before = [read_plan(api, plan) for plan in plans]
    assert all(p["periods"][0]["status"] == "cycle_settled" for p in before)
    debt = 2 * first["amount_due_minor"] * plan_count - partial
    fee_remaining = 2 * (fee // 3) * plan_count - partial if fee else 0
    preview, receipt, _, _ = payoff(
        api,
        credit,
        request(
            cash,
            debt - fee_remaining,
            waived_fee_minor=fee_remaining,
            note="Synthetic bank fee waiver" if fee_remaining else None,
        ),
    )
    assert set(preview["closing_installment_plan_ids"]) == {p["id"] for p in plans}
    assert preview["fee_minor"] == fee_remaining
    for old, plan in zip(before, plans, strict=True):
        after = read_plan(api, plan)
        assert after["periods"][0] == old["periods"][0]
        assert after["status"] == "settled_early"
        assert after["future_scheduled_gross_minor"] == 0
        for original, changed in zip(old["periods"][1:], after["periods"][1:], strict=True):
            assert changed["status"] == "settled_early"
            assert changed["settled_early_at"] is not None
            assert changed["version"] == original["version"] + 1
    reverse(api, receipt)
    assert summary(api, credit)["current_debt_minor"] == debt
    for old, plan in zip(before, plans, strict=True):
        restored = read_plan(api, plan)
        assert restored["periods"][0] == old["periods"][0]
        assert restored["status"] == old["status"]
        assert restored["future_scheduled_gross_minor"] == old["future_scheduled_gross_minor"]
        for original, changed in zip(old["periods"][1:], restored["periods"][1:], strict=True):
            assert changed["status"] == original["status"]
            assert changed["settled_early_at"] is None
            assert changed["version"] == original["version"] + 2


def test_payoff_excludes_fully_paid_plan(api):
    cash, credit = setup(api, fixed=True)
    plan = seed_plan(api, credit)
    for period in plan["periods"]:
        repay(api, cash, credit, period["effective_cycle_id"], period["amount_due_minor"])
    before = read_plan(api, plan)
    assert before["status"] == "completed"
    post(
        api,
        "/transactions",
        {
            "kind": "credit_purchase",
            "amount_minor": 5000,
            "occurred_at": "2026-12-01T08:00:00+08:00",
            "title": "Synthetic later purchase",
            "account_id": credit["id"],
        },
        status=201,
    )
    preview, receipt, _, _ = payoff(
        api, credit, request(cash, 5000, occurred_at="2026-12-02T12:00:00+08:00")
    )
    assert preview["closing_installment_plan_ids"] == []
    assert read_plan(api, plan) == before
    reverse(api, receipt)
    assert read_plan(api, plan) == before


def test_payoff_receipts_match_real_debt_and_permanent_replays(api):
    cash, credit = setup(api)
    borrow(api, cash, credit, amount=20000)
    debt_before = summary(api, credit)["current_debt_minor"]
    _, completed, commit, commit_key = payoff(api, credit, request(cash, 20000))
    debt_after = summary(api, credit)["current_debt_minor"]
    assert (
        (completed["debt_before_minor"], completed["debt_after_minor"])
        == (debt_before, debt_after)
        == (20000, 0)
    )
    reversed_receipt, body, reverse_key = reverse(api, completed)
    debt_restored = summary(api, credit)["current_debt_minor"]
    assert (
        (reversed_receipt["debt_before_minor"], reversed_receipt["debt_after_minor"])
        == (debt_after, debt_restored)
        == (0, 20000)
    )
    for field in ("actual_amount_minor", "transaction_ids", "allocations"):
        assert reversed_receipt[field] == completed[field]
    path = f"/credit-payoffs/{completed['operation_id']}"
    assert post(api, path + "/reverse", body, key=reverse_key) == reversed_receipt
    assert (
        post(api, f"/credit-accounts/{credit['id']}/payoff", commit, key=commit_key)
        == reversed_receipt
    )
    assert api.get("/api/v1" + path, headers=AUTH).json() == reversed_receipt
    assert api.get(f"/api/v1/credit-accounts/{credit['id']}/payoffs", headers=AUTH).json() == [
        reversed_receipt
    ]
    # Opt-in actual API bytes for client JSON decoding / view integration.
    if destination := environ.get("FISCAL_PAYOFF_RECEIPT_EXPORT_DIR"):
        directory = Path(destination)
        directory.mkdir(parents=True, exist_ok=True)
        for name, receipt in (("completed", completed), ("reversed", reversed_receipt)):
            (directory / f"payoff_{name}.json").write_text(
                json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
            )
