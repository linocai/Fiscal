from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from os import environ
from uuid import UUID, uuid4

import pytest

from test_p27_statement_import_review_postgres import _client, _seed, _snapshot
from test_v230_core_postgres import (
    AUTH,
    account,
    borrow,
    post,
    request,
    setup,
    summary,
)
from test_v230_core_postgres import (
    api as api,
)

pytestmark = pytest.mark.skipif(
    environ.get("FISCAL_TEST_DATABASE_URL") is None, reason="requires PostgreSQL"
)


def test_projection_skips_on_demand_and_voided_history_locks_mode(api):
    cash, credit = setup(api)
    fixed = account(
        api, "Synthetic fixed", "credit", 0, credit_limit_minor=100000, statement_day=10, due_day=22
    )
    current = summary(api, fixed)["current_cycle"]
    result = api.get(f"/api/v1/credit-cycles/{current['id']}", headers=AUTH)
    assert result.status_code == 200, result.text
    loan = borrow(api, cash, credit)
    post(api, f"/transactions/{loan['id']}/void", {"expected_version": loan["version"]})
    response = api.patch(
        f"/api/v1/accounts/{credit['id']}",
        headers=AUTH,
        json={
            "expected_version": credit["version"],
            "cycle_mode": "statement_day_cutoff",
            "credit_limit_minor": 100000,
            "statement_day": 10,
            "due_day": 22,
        },
    )
    assert response.status_code == 409, response.text
    assert response.json()["error"]["code"] == "credit_mode_locked"


def test_full_waiver_zero_cash_and_two_competing_payoff_keys(api):
    cash, credit = setup(api)
    borrow(api, cash, credit)
    before = api.get(f"/api/v1/accounts/{cash['id']}", headers=AUTH).json()["current_balance_minor"]
    payload = request(
        cash, 0, waived_principal_minor=10000, note="Bank verified all principal waived"
    )
    preview = post(api, f"/credit-accounts/{credit['id']}/payoff-preview", payload)
    commit = {**payload, "preview_token": preview["preview_token"]}

    def send():
        return api.post(
            f"/api/v1/credit-accounts/{credit['id']}/payoff",
            headers={**AUTH, "Idempotency-Key": str(uuid4())},
            json=commit,
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: send(), range(2)))
    assert sorted(r.status_code for r in results) == [200, 409]
    assert summary(api, credit)["current_debt_minor"] == 0
    assert (
        api.get(f"/api/v1/accounts/{cash['id']}", headers=AUTH).json()["current_balance_minor"]
        == before
    )
    assert len(api.get(f"/api/v1/credit-accounts/{credit['id']}/payoffs", headers=AUTH).json()) == 1


@pytest.mark.parametrize("kind", ["borrowing", "repayment"])
def test_final_import_draft_on_demand_confirm_replay(kind):
    with _client() as client:
        cash, credit = setup(client)
        if kind == "repayment":
            borrow(client, cash, credit, amount=5000)
        batch, auth = _seed(client)
        snapshot = asyncio.run(_snapshot(UUID(batch["id"])))
        review = client.post(
            f"/api/v1/statement-imports/{batch['id']}/validation-runs",
            headers=auth,
            json={
                "expected_batch_version": batch["version"],
                "provider_snapshot_id": str(snapshot),
            },
        ).json()
        row_id = review["candidates"][0]["statement_import_row_id"]
        resolution = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/draft-resolution",
            headers=auth,
            json={
                "expected_batch_version": review["batch_version"],
                "expected_row_version": 1,
                "expected_resolution_version": 0,
                "resolution": "create_new",
            },
        )
        assert resolution.status_code == 200, resolution.text
        draft = {
            "kind": kind,
            "amount_minor": 1850,
            "occurred_at": "2026-08-12T12:00:00+08:00",
            "title": "Synthetic import loan",
            "account_id": credit["id"] if kind == "borrowing" else cash["id"],
            "destination_account_id": cash["id"] if kind == "borrowing" else credit["id"],
        }
        final = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/final-create-draft",
            headers=auth,
            json={"expected_version": 0, "transaction": draft},
        )
        assert final.status_code == 200, final.text
        key = str(uuid4())
        payload = {
            "expected_batch_version": client.get(
                f"/api/v1/statement-imports/{batch['id']}", headers=auth
            ).json()["version"],
            "rows": [
                {
                    "row_id": row_id,
                    "expected_row_version": 1,
                    "expected_draft_version": 1,
                    "expected_final_create_draft_version": 1,
                }
            ],
        }
        path = f"/api/v1/statement-imports/{batch['id']}/confirm"
        first = client.post(path, headers={**auth, "Idempotency-Key": key}, json=payload)
        assert first.status_code == 200, first.text
        repeat = client.post(path, headers={**auth, "Idempotency-Key": key}, json=payload)
        assert repeat.status_code == 200, repeat.text
        assert repeat.json()["replay"]
        assert (
            first.json()["row_results"][0]["transaction_id"]
            == repeat.json()["row_results"][0]["transaction_id"]
        )
        assert summary(client, credit)["current_debt_minor"] == (
            1850 if kind == "borrowing" else 3150
        )


def test_installment_allocation_and_repayment_share_one_timestamp(api):
    cash, credit = setup(api, fixed=True)
    category = post(
        api,
        "/categories",
        {"name": "Synthetic", "direction": "expense", "icon": "star", "color_hex": "#336699"},
        status=201,
    )
    occurred = "2026-07-15T08:00:00+08:00"
    purchase = post(
        api,
        "/transactions",
        {
            "kind": "credit_purchase",
            "amount_minor": 30000,
            "occurred_at": occurred,
            "title": "Synthetic",
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
            "total_fee_minor": 0,
            "start_statement_date": "2026-08-10",
        },
        status=201,
    )
    post(
        api,
        "/transactions",
        {
            "kind": "repayment",
            "amount_minor": 10000,
            "occurred_at": occurred,
            "title": "Synthetic simultaneous payment",
            "account_id": cash["id"],
            "destination_account_id": credit["id"],
            "credit_cycle_id": plan["periods"][0]["effective_cycle_id"],
        },
        status=201,
    )
    assert summary(api, credit)["current_debt_minor"] == 20000
