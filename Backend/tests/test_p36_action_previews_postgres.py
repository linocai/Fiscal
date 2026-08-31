from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from os import environ
from threading import Event
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from httpx import Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app
from fiscal_api.services.common import MUTATION_LOCK_ID

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def _app() -> tuple[object, dict[str, str]]:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    return (
        create_app(
            settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
            readiness_check=ready,
        ),
        {"Authorization": "Bearer p36-token"},
    )


def _account(
    client: TestClient,
    auth: dict[str, str],
    *,
    name: str,
    kind: str = "debit",
    opening_balance_minor: int = 100_000,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "name": name,
        "kind": kind,
        "opening_balance_minor": opening_balance_minor,
    }
    if kind == "credit":
        payload.update(
            {
                "credit_limit_minor": 100_000,
                "statement_day": 10,
                "due_day": 22,
            }
        )
    response = client.post("/api/v1/accounts", headers=auth, json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def _category(client: TestClient, auth: dict[str, str], *, name: str) -> dict[str, object]:
    response = client.post(
        "/api/v1/categories",
        headers=auth,
        json={
            "name": name,
            "direction": "expense",
            "icon": "fork.knife",
            "color_hex": "#336699",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _transaction(
    client: TestClient, auth: dict[str, str], payload: dict[str, object]
) -> dict[str, object]:
    response = client.post(
        "/api/v1/transactions",
        headers={**auth, "Idempotency-Key": str(uuid4())},
        json=payload,
    )
    assert response.status_code == 201, response.text
    return response.json()


def _error_code(response: Response) -> str:
    return str(response.json()["error"]["code"])


async def _expire_preview(preview_token: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    try:
        async with engine.begin() as connection:
            await connection.execute(
                text(
                    "UPDATE action_preview_sessions "
                    "SET expires_at = now() - interval '1 second' WHERE id = :id"
                ),
                {"id": preview_token},
            )
    finally:
        await engine.dispose()


async def _hold_revision_bump(acquired: Event, release: Event) -> None:
    """Commit a competing revision only after the formal request is waiting."""
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    try:
        async with engine.begin() as connection:
            await connection.execute(
                text("SELECT pg_advisory_xact_lock(:lock_id)"),
                {"lock_id": MUTATION_LOCK_ID},
            )
            await connection.execute(
                text("UPDATE data_revision SET revision = revision + 1 WHERE id = 1")
            )
            acquired.set()
            assert await asyncio.to_thread(release.wait, 10)
    finally:
        await engine.dispose()


async def _wait_for_blocked_advisory_lock() -> bool:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    try:
        for _ in range(200):
            async with engine.connect() as connection:
                waiting = await connection.scalar(
                    text(
                        "SELECT EXISTS ("
                        "SELECT 1 FROM pg_locks "
                        "WHERE locktype = 'advisory' AND NOT granted"
                        ")"
                    )
                )
            if waiting:
                return True
            await asyncio.sleep(0.01)
        return False
    finally:
        await engine.dispose()


def test_p36_category_preview_is_version_bound_single_use_and_replayable() -> None:
    app, auth = _app()
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        account = _account(client, auth, name=f"P36 分类账户 {suffix}")
        category = _category(client, auth, name=f"P36 餐饮 {suffix}")
        transaction = _transaction(
            client,
            auth,
            {
                "kind": "expense",
                "amount_minor": 1_234,
                "occurred_at": "2026-08-30T10:00:00+08:00",
                "title": "P36 待分类",
                "account_id": account["id"],
            },
        )
        request = {
            "items": [
                {
                    "transaction_id": transaction["id"],
                    "expected_version": transaction["version"],
                }
            ],
            "category_id": category["id"],
        }
        preview = client.post("/api/v1/transactions/category-preview", headers=auth, json=request)
        assert preview.status_code == 200, preview.text
        body = preview.json()
        assert body["changed_count"] == 1
        assert body["items"][0]["previous_category_id"] is None
        assert body["items"][0]["proposed_category_id"] == category["id"]

        unchanged = client.get(f"/api/v1/transactions/{transaction['id']}", headers=auth)
        assert unchanged.status_code == 200, unchanged.text
        assert unchanged.json()["category_id"] is None

        key = str(uuid4())
        commit = client.post(
            "/api/v1/transactions/category-commit",
            headers={**auth, "Idempotency-Key": key},
            json={"preview_token": body["meta"]["preview_token"]},
        )
        assert commit.status_code == 200, commit.text
        receipt = commit.json()
        assert receipt["action"] == "category_change"
        assert receipt["replay"] is False
        assert receipt["result"]["changed_count"] == 1

        replay = client.post(
            "/api/v1/transactions/category-commit",
            headers={**auth, "Idempotency-Key": key},
            json={"preview_token": body["meta"]["preview_token"]},
        )
        assert replay.status_code == 200, replay.text
        assert replay.json() == {**receipt, "replay": True}
        operation = client.get(f"/api/v1/action-operations/{key}", headers=auth)
        assert operation.status_code == 200, operation.text
        assert operation.json() == replay.json()

        consumed = client.post(
            "/api/v1/transactions/category-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"preview_token": body["meta"]["preview_token"]},
        )
        assert consumed.status_code == 409, consumed.text
        assert _error_code(consumed) == "action_preview_consumed"

        updated = client.get(f"/api/v1/transactions/{transaction['id']}", headers=auth)
        assert updated.status_code == 200, updated.text
        assert updated.json()["category_id"] == category["id"]


def test_p36_category_preview_rejects_stale_and_expired_tokens() -> None:
    app, auth = _app()
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        account = _account(client, auth, name=f"P36 失效账户 {suffix}")
        category = _category(client, auth, name=f"P36 失效分类 {suffix}")
        transaction = _transaction(
            client,
            auth,
            {
                "kind": "expense",
                "amount_minor": 99,
                "occurred_at": "2026-08-30T11:00:00+08:00",
                "title": "P36 失效预览",
                "account_id": account["id"],
            },
        )
        request = {
            "items": [
                {
                    "transaction_id": transaction["id"],
                    "expected_version": transaction["version"],
                }
            ],
            "category_id": category["id"],
        }
        stale_preview = client.post(
            "/api/v1/transactions/category-preview", headers=auth, json=request
        ).json()
        _account(client, auth, name=f"P36 并发变更 {suffix}", opening_balance_minor=0)
        stale = client.post(
            "/api/v1/transactions/category-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"preview_token": stale_preview["meta"]["preview_token"]},
        )
        assert stale.status_code == 409, stale.text
        assert _error_code(stale) == "action_preview_stale"
        assert stale.json()["error"]["details"]["safe_to_reload"] is True

        fresh_preview = client.post(
            "/api/v1/transactions/category-preview", headers=auth, json=request
        ).json()
        asyncio.run(_expire_preview(fresh_preview["meta"]["preview_token"]))
        expired = client.post(
            "/api/v1/transactions/category-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"preview_token": fresh_preview["meta"]["preview_token"]},
        )
        assert expired.status_code == 409, expired.text
        assert _error_code(expired) == "action_preview_expired"


def test_p36_category_commit_checks_revision_after_acquiring_global_write_lock() -> None:
    app, auth = _app()
    suffix = uuid4().hex[:8]
    with TestClient(app, raise_server_exceptions=False) as client:
        account = _account(client, auth, name=f"P36 锁账户 {suffix}")
        category = _category(client, auth, name=f"P36 锁分类 {suffix}")
        transaction = _transaction(
            client,
            auth,
            {
                "kind": "expense",
                "amount_minor": 321,
                "occurred_at": "2026-08-30T11:30:00+08:00",
                "title": "P36 锁内校验",
                "account_id": account["id"],
            },
        )
        preview = client.post(
            "/api/v1/transactions/category-preview",
            headers=auth,
            json={
                "items": [
                    {
                        "transaction_id": transaction["id"],
                        "expected_version": transaction["version"],
                    }
                ],
                "category_id": category["id"],
            },
        )
        assert preview.status_code == 200, preview.text

        acquired = Event()
        release = Event()
        with ThreadPoolExecutor(max_workers=2) as executor:
            holder = executor.submit(
                asyncio.run,
                _hold_revision_bump(acquired, release),
            )
            assert acquired.wait(5)
            commit = executor.submit(
                client.post,
                "/api/v1/transactions/category-commit",
                headers={**auth, "Idempotency-Key": str(uuid4())},
                json={"preview_token": preview.json()["meta"]["preview_token"]},
            )
            try:
                assert asyncio.run(_wait_for_blocked_advisory_lock())
            finally:
                release.set()
            holder.result(timeout=5)
            response = commit.result(timeout=5)

        assert response.status_code == 409, response.text
        assert _error_code(response) == "action_preview_stale"
        unchanged = client.get(f"/api/v1/transactions/{transaction['id']}", headers=auth)
        assert unchanged.status_code == 200, unchanged.text
        assert unchanged.json()["category_id"] is None


def test_p36_repayment_and_cash_flow_confirmation_require_preview_receipts() -> None:
    app, auth = _app()
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        payment = _account(client, auth, name=f"P36 储蓄卡 {suffix}")
        credit = _account(
            client,
            auth,
            name=f"P36 信用卡 {suffix}",
            kind="credit",
            opening_balance_minor=0,
        )
        category = _category(client, auth, name=f"P36 还款分类 {suffix}")
        purchase = _transaction(
            client,
            auth,
            {
                "kind": "credit_purchase",
                "amount_minor": 2_000,
                "occurred_at": "2026-08-20T12:00:00+08:00",
                "title": "P36 信用消费",
                "account_id": credit["id"],
                "category_id": category["id"],
            },
        )
        repayment_draft = {
            "kind": "repayment",
            "amount_minor": 500,
            "occurred_at": "2026-08-21T12:00:00+08:00",
            "title": "P36 还款",
            "account_id": payment["id"],
            "destination_account_id": credit["id"],
            "credit_cycle_id": purchase["credit_cycle_id"],
        }
        repayment_preview = client.post(
            "/api/v1/transactions/repayment-preview",
            headers=auth,
            json={"draft": repayment_draft},
        )
        assert repayment_preview.status_code == 200, repayment_preview.text
        preview_body = repayment_preview.json()
        assert preview_body["payment_balance_after_minor"] == 99_500
        assert preview_body["cycle_remaining_after_minor"] == 1_500
        repayment_commit = client.post(
            "/api/v1/transactions/repayment-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"preview_token": preview_body["meta"]["preview_token"]},
        )
        assert repayment_commit.status_code == 200, repayment_commit.text
        assert repayment_commit.json()["result"]["kind"] == "repayment"
        cycle = client.get(f"/api/v1/credit-cycles/{purchase['credit_cycle_id']}", headers=auth)
        assert cycle.status_code == 200, cycle.text
        assert cycle.json()["repaid_minor"] == 500

        created = client.post(
            "/api/v1/cash-flow-items",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "title": "P36 待确认支出",
                "direction": "outflow",
                "planned_amount_minor": 800,
                "expected_date": "2026-09-01",
                "account_id": payment["id"],
                "category_id": category["id"],
            },
        )
        assert created.status_code == 201, created.text
        item = created.json()["items"][0]
        item_id = item["manual_item_id"]
        confirmation_preview = client.post(
            f"/api/v1/cash-flow-items/{item_id}/confirm-preview",
            headers=auth,
            json={"expected_version": item["version"]},
        )
        assert confirmation_preview.status_code == 200, confirmation_preview.text
        confirmation_body = confirmation_preview.json()
        assert confirmation_body["item_before"]["status"] == "expected"
        assert confirmation_body["status_after"] == "confirmed"
        confirmed = client.post(
            f"/api/v1/cash-flow-items/{item_id}/confirm-commit",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={"preview_token": confirmation_body["meta"]["preview_token"]},
        )
        assert confirmed.status_code == 200, confirmed.text
        assert confirmed.json()["action"] == "cash_flow_confirm"
        assert confirmed.json()["result"]["status"] == "confirmed"
        persisted = client.get(f"/api/v1/cash-flow-items/{item_id}", headers=auth)
        assert persisted.status_code == 200, persisted.text
        assert persisted.json()["status"] == "confirmed"
