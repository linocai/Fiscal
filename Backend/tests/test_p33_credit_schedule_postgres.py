from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime
from os import environ
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

from fiscal_api.core.config import Settings
from fiscal_api.db.models import (
    AIProposal,
    CreditCycleMode,
    InstallmentLedgerLink,
    InstallmentPeriod,
    InstallmentPlan,
    StatementImport,
    StatementImportRow,
)
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.main import create_app
from fiscal_api.services.archive import ArchiveService
from fiscal_api.services.credit import credit_schedule, schedule_for_statement

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
        {"Authorization": "Bearer p33-credit-token"},
    )


def _credit_account(
    client: TestClient,
    auth: dict[str, str],
    *,
    statement_day: int = 1,
    due_day: int = 20,
) -> dict[str, object]:
    response = client.post(
        "/api/v1/accounts",
        headers=auth,
        json={
            "name": f"P33 信用卡 {uuid4().hex[:8]}",
            "kind": "credit",
            "opening_balance_minor": 0,
            "credit_limit_minor": 100_000,
            "statement_day": statement_day,
            "due_day": due_day,
            "cycle_mode": "statement_day_cutoff",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _debit_account(client: TestClient, auth: dict[str, str]) -> dict[str, object]:
    response = client.post(
        "/api/v1/accounts",
        headers=auth,
        json={
            "name": f"P33 还款卡 {uuid4().hex[:8]}",
            "kind": "debit",
            "opening_balance_minor": 100_000,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _category(client: TestClient, auth: dict[str, str]) -> dict[str, object]:
    response = client.post(
        "/api/v1/categories",
        headers=auth,
        json={
            "name": f"P33 分类 {uuid4().hex[:8]}",
            "direction": "expense",
            "icon": "tag",
            "color_hex": "#123456",
            "aliases": [],
            "examples": [],
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _purchase(
    client: TestClient,
    auth: dict[str, str],
    account_id: str,
    category_id: str,
    amount: int = 12_345,
    occurred_at: str = "2026-08-10T10:00:00+08:00",
) -> dict[str, object]:
    response = client.post(
        "/api/v1/transactions",
        headers={**auth, "Idempotency-Key": str(uuid4())},
        json={
            "kind": "credit_purchase",
            "amount_minor": amount,
            "occurred_at": occurred_at,
            "title": "P33 待重排消费",
            "account_id": account_id,
            "category_id": category_id,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _preview_payload(account: dict[str, object]) -> dict[str, object]:
    return {
        "expected_version": account["version"],
        "cycle_mode": "previous_calendar_month",
        "statement_day": 5,
        "due_day": 25,
    }


def _due_only_payload(account: dict[str, object], due_day: int = 25) -> dict[str, object]:
    return {
        "expected_version": account["version"],
        "cycle_mode": account["cycle_mode"],
        "statement_day": account["statement_day"],
        "due_day": due_day,
    }


def _revision() -> int:
    async def read() -> int:
        assert TEST_DATABASE_URL is not None
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with engine.connect() as connection:
                return int(
                    await connection.scalar(text("SELECT revision FROM data_revision WHERE id = 1"))
                    or 0
                )
        finally:
            await engine.dispose()

    return asyncio.run(read())


def _add_ai_cycle_reference(cycle_id: str) -> None:
    async def add() -> None:
        assert TEST_DATABASE_URL is not None
        engine = create_engine(TEST_DATABASE_URL)
        try:
            factory = create_session_factory(engine)
            async with factory() as session:
                session.add(
                    AIProposal(
                        source="text",
                        raw_input="P33 credit-cycle reference",
                        content_fingerprint="a" * 64,
                        create_idempotency_key=uuid4(),
                        create_request_hash="b" * 64,
                        target="transaction",
                        status="pending",
                        credit_cycle_id=UUID(cycle_id),
                    )
                )
                await session.commit()
        finally:
            await engine.dispose()

    asyncio.run(add())


def _add_statement_cycle_candidate(cycle_id: str) -> None:
    async def add() -> None:
        assert TEST_DATABASE_URL is not None
        engine = create_engine(TEST_DATABASE_URL)
        try:
            factory = create_session_factory(engine)
            async with factory() as session:
                statement_import = StatementImport(
                    document_sha256=(uuid4().hex * 2)[:64],
                    byte_size=1,
                    page_count=1,
                    mime_type="application/pdf",
                    display_name="statement.pdf",
                    status="created",
                )
                session.add(statement_import)
                await session.flush()
                session.add(
                    StatementImportRow(
                        statement_import_id=statement_import.id,
                        row_number=1,
                        credit_cycle_id_candidate=UUID(cycle_id),
                    )
                )
                await session.commit()
        finally:
            await engine.dispose()

    asyncio.run(add())


def _add_installment_cycle_references(
    *,
    account_id: str,
    cycle_id: str,
    next_cycle_id: str,
    purchase_entries: list[tuple[str, int]],
) -> None:
    async def add() -> None:
        assert TEST_DATABASE_URL is not None
        engine = create_engine(TEST_DATABASE_URL)
        try:
            factory = create_session_factory(engine)
            async with factory() as session:
                for purchase_id, amount_minor in purchase_entries:
                    plan = InstallmentPlan(
                        purchase_transaction_id=UUID(purchase_id),
                        credit_account_id=UUID(account_id),
                        installment_count=2,
                        start_cycle_id=UUID(cycle_id),
                        lifecycle="active",
                        create_idempotency_key=uuid4(),
                        create_request_hash="c" * 64,
                    )
                    session.add(plan)
                    await session.flush()
                    session.add(
                        InstallmentLedgerLink(
                            transaction_id=UUID(purchase_id),
                            plan_id=plan.id,
                            role="purchase",
                        )
                    )
                    session.add_all(
                        [
                            InstallmentPeriod(
                                plan_id=plan.id,
                                sequence=1,
                                scheduled_cycle_id=UUID(cycle_id),
                                effective_cycle_id=UUID(cycle_id),
                                principal_minor=amount_minor // 2,
                                fee_minor=0,
                            ),
                            InstallmentPeriod(
                                plan_id=plan.id,
                                sequence=2,
                                scheduled_cycle_id=UUID(next_cycle_id),
                                effective_cycle_id=UUID(next_cycle_id),
                                principal_minor=amount_minor - (amount_minor // 2),
                                fee_minor=0,
                            ),
                        ]
                    )
                await session.commit()
        finally:
            await engine.dispose()

    asyncio.run(add())


def test_p33_schedule_preview_commit_replay_and_archive_boundary() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth)
        category = _category(client, auth)
        purchase = _purchase(client, auth, str(account["id"]), str(category["id"]))
        before_preview = _revision()
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_preview_payload(account),
        )
        assert preview.status_code == 200, preview.text
        preview_body = preview.json()
        assert _revision() == before_preview
        assert preview_body["preview_token"]
        assert preview_body["current_account_version"] == account["version"]
        assert preview_body["expected_account_version"] == account["version"]
        assert preview_body["affected_cycles"][0]["current_version"] == 1
        assert preview_body["affected_cycles"][0]["new_due_date"] == "2026-09-25"
        assert preview_body["available_actions"] == ["commit_schedule_change"]

        password = f"p33-{uuid4().hex}"
        archive = client.post("/api/v1/archives/export", headers=auth, json={"password": password})
        assert archive.status_code == 200, archive.text
        _, archive_payload = ArchiveService.open(archive.content, password=password)
        assert "credit_schedule_change_previews" not in archive_payload["entities"]
        assert "credit_schedule_change_operations" not in archive_payload["entities"]

        payload = {**_preview_payload(account), "preview_token": preview_body["preview_token"]}
        key = str(uuid4())
        committed = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": key},
            json=payload,
        )
        assert committed.status_code == 200, committed.text
        receipt = committed.json()
        assert receipt["data_revision"] == before_preview + 1
        assert committed.headers["X-Fiscal-Data-Revision"] == str(before_preview + 1)
        assert _revision() == before_preview + 1
        assert receipt["current_account_version"] == account["version"] + 1
        moved = client.get(f"/api/v1/transactions/{purchase['id']}", headers=auth)
        assert moved.status_code == 200
        cycle = client.get(f"/api/v1/credit-cycles/{moved.json()['credit_cycle_id']}", headers=auth)
        assert cycle.status_code == 200
        assert (cycle.json()["statement_date"], cycle.json()["due_date"]) == (
            "2026-09-05",
            "2026-09-25",
        )

        # A response lost after the server commit is safe to replay verbatim.
        replay = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": key},
            json=payload,
        )
        assert replay.status_code == 200, replay.text
        assert replay.json() == receipt
        assert _revision() == before_preview + 1
        collision = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": key},
            json={**payload, "due_day": 26},
        )
        assert collision.status_code == 409
        assert collision.json()["error"]["code"] == "idempotency_key_reused"


def test_p33_due_day_only_updates_existing_cycle_and_future_event() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth)
        category = _category(client, auth)
        purchase = _purchase(client, auth, str(account["id"]), str(category["id"]))
        prior_cycle_id = purchase["credit_cycle_id"]
        prior_cycle = client.get(f"/api/v1/credit-cycles/{prior_cycle_id}", headers=auth)
        assert prior_cycle.status_code == 200
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_due_only_payload(account),
        )
        assert preview.status_code == 200, preview.text
        assert preview.json()["affected_cycles"] == [
            {
                "cycle_id": prior_cycle_id,
                "current_version": 1,
                "expected_version": 1,
                "old_statement_date": "2026-09-01",
                "old_due_date": "2026-09-20",
                "new_statement_date": "2026-09-01",
                "new_due_date": "2026-09-25",
                "remaining_minor": 12_345,
                "old_is_overdue": False,
                "new_is_overdue": False,
                "preserved_checkpoint_count": 0,
            }
        ]
        receipt = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**_due_only_payload(account), "preview_token": preview.json()["preview_token"]},
        )
        assert receipt.status_code == 200, receipt.text
        assert (
            receipt.json()["old_statement_day"],
            receipt.json()["old_due_day"],
            receipt.json()["statement_day"],
            receipt.json()["due_day"],
        ) == (1, 20, 1, 25)
        cycle = client.get(f"/api/v1/credit-cycles/{prior_cycle_id}", headers=auth)
        assert cycle.status_code == 200
        assert (
            cycle.json()["statement_date"],
            cycle.json()["due_date"],
            cycle.json()["version"],
        ) == (
            "2026-09-01",
            "2026-09-25",
            1,
        )
        assert datetime.fromisoformat(cycle.json()["updated_at"]) > datetime.fromisoformat(
            prior_cycle.json()["updated_at"]
        )
        future = client.get(
            "/api/v1/reports/future-events",
            headers=auth,
            params={"window_days": 90, "account_id": account["id"]},
        )
        assert future.status_code == 200, future.text
        credit_events = [
            item for item in future.json()["items"] if item["source_type"] == "credit_cycle"
        ]
        assert [
            (item["source_id"], item["date"], item["amount_minor"]) for item in credit_events
        ] == [(prior_cycle_id, "2026-09-25", 12_345)]


def test_p33_stable_dependency_order_allows_reloaded_multisource_commit() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth)
        category = _category(client, auth)
        first = _purchase(client, auth, str(account["id"]), str(category["id"]), amount=1_000)
        second = _purchase(
            client,
            auth,
            str(account["id"]),
            str(category["id"]),
            amount=2_000,
            occurred_at="2026-08-11T10:00:00+08:00",
        )
        assert first["credit_cycle_id"] == second["credit_cycle_id"]
        next_purchase = _purchase(
            client,
            auth,
            str(account["id"]),
            str(category["id"]),
            amount=3_000,
            occurred_at="2026-09-02T10:00:00+08:00",
        )
        _add_installment_cycle_references(
            account_id=str(account["id"]),
            cycle_id=str(first["credit_cycle_id"]),
            next_cycle_id=str(next_purchase["credit_cycle_id"]),
            purchase_entries=[(str(second["id"]), 2_000), (str(first["id"]), 1_000)],
        )
        payload = {
            "expected_version": account["version"],
            "cycle_mode": "statement_day_cutoff",
            "statement_day": 28,
            "due_day": 20,
        }
        # Preview and commit run in separate request sessions.  The plan has two
        # transactions, two plans and four periods inserted in reverse source order.
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=payload,
        )
        assert preview.status_code == 200, preview.text
        committed = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**payload, "preview_token": preview.json()["preview_token"]},
        )
        assert committed.status_code == 200, committed.text
        assert committed.json()["affected_cycles"] == preview.json()["affected_cycles"]


def test_p33_checkpointed_old_cycle_is_preserved_without_future_ghost() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth)
        category = _category(client, auth)
        purchase = _purchase(client, auth, str(account["id"]), str(category["id"]))
        checkpoint = client.post(
            "/api/v1/reconciliation/checkpoints",
            headers=auth,
            json={
                "target_kind": "credit_cycle",
                "credit_cycle_id": purchase["credit_cycle_id"],
                "as_of": "2026-08-11T10:00:00+08:00",
                "actual_balance_minor": 12_345,
            },
        )
        assert checkpoint.status_code == 201, checkpoint.text
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_preview_payload(account),
        )
        assert preview.status_code == 200, preview.text
        assert preview.json()["affected_cycles"][0]["preserved_checkpoint_count"] == 1
        committed = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**_preview_payload(account), "preview_token": preview.json()["preview_token"]},
        )
        assert committed.status_code == 200, committed.text
        moved = client.get(f"/api/v1/transactions/{purchase['id']}", headers=auth)
        assert moved.status_code == 200
        assert moved.json()["credit_cycle_id"] != purchase["credit_cycle_id"]
        old_cycle = client.get(f"/api/v1/credit-cycles/{purchase['credit_cycle_id']}", headers=auth)
        assert old_cycle.status_code == 200
        checkpoints = client.get(
            "/api/v1/reconciliation/checkpoints",
            headers=auth,
            params={"credit_cycle_id": purchase["credit_cycle_id"]},
        )
        assert checkpoints.status_code == 200
        assert [item["id"] for item in checkpoints.json()] == [checkpoint.json()["id"]]
        future = client.get(
            "/api/v1/reports/future-events",
            headers=auth,
            params={"window_days": 90, "account_id": account["id"]},
        )
        assert future.status_code == 200, future.text
        credit_events = [
            item for item in future.json()["items"] if item["source_type"] == "credit_cycle"
        ]
        assert [item["source_id"] for item in credit_events] == [moved.json()["credit_cycle_id"]]


def test_p33_checkpoint_created_after_preview_makes_commit_stale_without_write() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth)
        category = _category(client, auth)
        purchase = _purchase(client, auth, str(account["id"]), str(category["id"]))
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_preview_payload(account),
        )
        assert preview.status_code == 200, preview.text
        checkpoint = client.post(
            "/api/v1/reconciliation/checkpoints",
            headers=auth,
            json={
                "target_kind": "credit_cycle",
                "credit_cycle_id": purchase["credit_cycle_id"],
                "as_of": "2026-08-11T10:00:00+08:00",
                "actual_balance_minor": 12_345,
            },
        )
        assert checkpoint.status_code == 201, checkpoint.text
        before_commit = _revision()
        stale = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**_preview_payload(account), "preview_token": preview.json()["preview_token"]},
        )
        assert stale.status_code == 409, stale.text
        assert stale.json()["error"]["code"] == "credit_schedule_preview_stale"
        assert _revision() == before_commit
        unchanged = client.get(f"/api/v1/accounts/{account['id']}", headers=auth)
        assert (unchanged.json()["statement_day"], unchanged.json()["due_day"]) == (1, 20)


def test_p33_cutoff_remap_uses_purchase_business_date_in_preview_commit_and_future_events() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth)
        category = _category(client, auth)
        purchase = _purchase(client, auth, str(account["id"]), str(category["id"]))
        payload = {
            "expected_version": account["version"],
            "cycle_mode": "statement_day_cutoff",
            "statement_day": 28,
            "due_day": 20,
        }
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=payload,
        )
        assert preview.status_code == 200, preview.text
        affected = preview.json()["affected_cycles"]
        assert [(item["new_statement_date"], item["new_due_date"]) for item in affected] == [
            ("2026-08-28", "2026-09-20")
        ]
        committed = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**payload, "preview_token": preview.json()["preview_token"]},
        )
        assert committed.status_code == 200, committed.text
        assert committed.json()["affected_cycles"] == affected
        moved = client.get(f"/api/v1/transactions/{purchase['id']}", headers=auth)
        assert moved.status_code == 200
        cycle = client.get(f"/api/v1/credit-cycles/{moved.json()['credit_cycle_id']}", headers=auth)
        assert (cycle.json()["statement_date"], cycle.json()["due_date"]) == (
            "2026-08-28",
            "2026-09-20",
        )
        future = client.get(
            "/api/v1/reports/future-events",
            headers=auth,
            params={"window_days": 90, "account_id": account["id"]},
        )
        assert future.status_code == 200, future.text
        assert [
            (item["source_id"], item["date"], item["amount_minor"])
            for item in future.json()["items"]
            if item["source_type"] == "credit_cycle"
        ] == [(moved.json()["credit_cycle_id"], "2026-09-20", 12_345)]


def test_p33_split_purchase_remap_preserves_each_target_cycle() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth, statement_day=28, due_day=10)
        category = _category(client, auth)
        first = _purchase(
            client,
            auth,
            str(account["id"]),
            str(category["id"]),
            amount=1_000,
            occurred_at="2026-08-29T10:00:00+08:00",
        )
        second = _purchase(
            client,
            auth,
            str(account["id"]),
            str(category["id"]),
            amount=2_000,
            occurred_at="2026-09-27T10:00:00+08:00",
        )
        payload = {
            "expected_version": account["version"],
            "cycle_mode": "statement_day_cutoff",
            "statement_day": 1,
            "due_day": 10,
        }
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=payload,
        )
        assert preview.status_code == 200, preview.text
        assert preview.json()["warnings"] == []
        assert [
            (item["new_statement_date"], item["new_due_date"], item["remaining_minor"])
            for item in preview.json()["affected_cycles"]
        ] == [
            ("2026-09-01", "2026-09-10", 1_000),
            ("2026-10-01", "2026-10-10", 2_000),
        ]
        committed = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**payload, "preview_token": preview.json()["preview_token"]},
        )
        assert committed.status_code == 200, committed.text
        assert committed.json()["affected_cycles"] == preview.json()["affected_cycles"]
        first_moved = client.get(f"/api/v1/transactions/{first['id']}", headers=auth).json()
        second_moved = client.get(f"/api/v1/transactions/{second['id']}", headers=auth).json()
        assert first_moved["credit_cycle_id"] != second_moved["credit_cycle_id"]
        future = client.get(
            "/api/v1/reports/future-events",
            headers=auth,
            params={"window_days": 90, "account_id": account["id"]},
        )
        assert future.status_code == 200, future.text
        assert [
            (item["source_id"], item["date"], item["amount_minor"])
            for item in future.json()["items"]
            if item["source_type"] == "credit_cycle"
        ] == [
            (first_moved["credit_cycle_id"], "2026-09-10", 1_000),
            (second_moved["credit_cycle_id"], "2026-10-10", 2_000),
        ]


def test_p33_split_purchase_remap_blocks_repayment_without_partial_write() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth, statement_day=28, due_day=10)
        category = _category(client, auth)
        payment = _debit_account(client, auth)
        first = _purchase(
            client,
            auth,
            str(account["id"]),
            str(category["id"]),
            amount=1_000,
            occurred_at="2026-08-29T10:00:00+08:00",
        )
        _purchase(
            client,
            auth,
            str(account["id"]),
            str(category["id"]),
            amount=2_000,
            occurred_at="2026-09-27T10:00:00+08:00",
        )
        repayment = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "repayment",
                "amount_minor": 100,
                "occurred_at": "2026-09-28T10:00:00+08:00",
                "title": "P33 split remap repayment",
                "account_id": payment["id"],
                "destination_account_id": account["id"],
                "credit_cycle_id": first["credit_cycle_id"],
            },
        )
        assert repayment.status_code == 201, repayment.text
        payload = {
            "expected_version": account["version"],
            "cycle_mode": "statement_day_cutoff",
            "statement_day": 1,
            "due_day": 10,
        }
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=payload,
        )
        assert preview.status_code == 200, preview.text
        assert preview.json()["warnings"] == ["credit_schedule_ambiguous_remap"]
        assert [
            (item["new_statement_date"], item["new_due_date"])
            for item in preview.json()["affected_cycles"]
        ] == [
            ("2026-09-01", "2026-09-10"),
            ("2026-10-01", "2026-10-10"),
        ]
        before_commit = _revision()
        blocked = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**payload, "preview_token": preview.json()["preview_token"]},
        )
        assert blocked.status_code == 409, blocked.text
        assert blocked.json()["error"]["code"] == "credit_schedule_ambiguous_remap"
        assert _revision() == before_commit
        unchanged = client.get(f"/api/v1/transactions/{first['id']}", headers=auth)
        assert unchanged.json()["credit_cycle_id"] == first["credit_cycle_id"]


def test_p33_split_purchase_remap_blocks_existing_checkpoint_without_write() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth, statement_day=28, due_day=10)
        category = _category(client, auth)
        first = _purchase(
            client,
            auth,
            str(account["id"]),
            str(category["id"]),
            occurred_at="2026-08-29T10:00:00+08:00",
        )
        _purchase(
            client,
            auth,
            str(account["id"]),
            str(category["id"]),
            occurred_at="2026-09-27T10:00:00+08:00",
        )
        checkpoint = client.post(
            "/api/v1/reconciliation/checkpoints",
            headers=auth,
            json={
                "target_kind": "credit_cycle",
                "credit_cycle_id": first["credit_cycle_id"],
                "as_of": "2026-08-13T10:00:00+08:00",
                "actual_balance_minor": 12_345,
            },
        )
        assert checkpoint.status_code == 201, checkpoint.text
        payload = {
            "expected_version": account["version"],
            "cycle_mode": "statement_day_cutoff",
            "statement_day": 1,
            "due_day": 10,
        }
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=payload,
        )
        assert preview.status_code == 200, preview.text
        assert preview.json()["warnings"] == ["credit_schedule_ambiguous_remap"]
        before_commit = _revision()
        blocked = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**payload, "preview_token": preview.json()["preview_token"]},
        )
        assert blocked.status_code == 409, blocked.text
        assert blocked.json()["error"]["code"] == "credit_schedule_ambiguous_remap"
        assert _revision() == before_commit
        assert (
            client.get(f"/api/v1/transactions/{first['id']}", headers=auth).json()[
                "credit_cycle_id"
            ]
            == first["credit_cycle_id"]
        )


def test_p33_ai_cycle_reference_preserves_old_cycle_and_new_reference_stales_preview() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth)
        category = _category(client, auth)
        purchase = _purchase(client, auth, str(account["id"]), str(category["id"]))
        _add_ai_cycle_reference(str(purchase["credit_cycle_id"]))
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_preview_payload(account),
        )
        assert preview.status_code == 200, preview.text
        committed = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**_preview_payload(account), "preview_token": preview.json()["preview_token"]},
        )
        assert committed.status_code == 200, committed.text
        moved = client.get(f"/api/v1/transactions/{purchase['id']}", headers=auth)
        assert moved.status_code == 200
        assert moved.json()["credit_cycle_id"] != purchase["credit_cycle_id"]
        assert (
            client.get(
                f"/api/v1/credit-cycles/{purchase['credit_cycle_id']}", headers=auth
            ).status_code
            == 200
        )
        future = client.get(
            "/api/v1/reports/future-events",
            headers=auth,
            params={"window_days": 90, "account_id": account["id"]},
        )
        assert [
            item["source_id"]
            for item in future.json()["items"]
            if item["source_type"] == "credit_cycle"
        ] == [moved.json()["credit_cycle_id"]]

        refreshed = client.get(f"/api/v1/accounts/{account['id']}", headers=auth).json()
        next_preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_due_only_payload(refreshed, due_day=26),
        )
        assert next_preview.status_code == 200, next_preview.text
        _add_ai_cycle_reference(moved.json()["credit_cycle_id"])
        before_commit = _revision()
        stale = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                **_due_only_payload(refreshed, due_day=26),
                "preview_token": next_preview.json()["preview_token"],
            },
        )
        assert stale.status_code == 409, stale.text
        assert stale.json()["error"]["code"] == "credit_schedule_preview_stale"
        assert _revision() == before_commit


def test_p33_statement_cycle_candidate_preserves_old_cycle_and_stales_preview() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth)
        category = _category(client, auth)
        purchase = _purchase(client, auth, str(account["id"]), str(category["id"]))
        _add_statement_cycle_candidate(str(purchase["credit_cycle_id"]))
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_preview_payload(account),
        )
        assert preview.status_code == 200, preview.text
        committed = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**_preview_payload(account), "preview_token": preview.json()["preview_token"]},
        )
        assert committed.status_code == 200, committed.text
        moved = client.get(f"/api/v1/transactions/{purchase['id']}", headers=auth)
        assert moved.json()["credit_cycle_id"] != purchase["credit_cycle_id"]
        assert (
            client.get(
                f"/api/v1/credit-cycles/{purchase['credit_cycle_id']}", headers=auth
            ).status_code
            == 200
        )
        future = client.get(
            "/api/v1/reports/future-events",
            headers=auth,
            params={"window_days": 90, "account_id": account["id"]},
        )
        assert [
            item["source_id"]
            for item in future.json()["items"]
            if item["source_type"] == "credit_cycle"
        ] == [moved.json()["credit_cycle_id"]]

        refreshed = client.get(f"/api/v1/accounts/{account['id']}", headers=auth).json()
        next_preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_due_only_payload(refreshed, due_day=26),
        )
        assert next_preview.status_code == 200, next_preview.text
        _add_statement_cycle_candidate(moved.json()["credit_cycle_id"])
        before_commit = _revision()
        stale = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                **_due_only_payload(refreshed, due_day=26),
                "preview_token": next_preview.json()["preview_token"],
            },
        )
        assert stale.status_code == 409, stale.text
        assert stale.json()["error"]["code"] == "credit_schedule_preview_stale"
        assert _revision() == before_commit


def test_p33_schedule_commit_and_checkpoint_create_serialize_without_fk_failure() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth)
        category = _category(client, auth)
        purchase = _purchase(client, auth, str(account["id"]), str(category["id"]))
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_preview_payload(account),
        )
        assert preview.status_code == 200, preview.text
        schedule_payload = {
            **_preview_payload(account),
            "preview_token": preview.json()["preview_token"],
        }
        start = Barrier(2)

        def commit() -> tuple[int, dict[str, object]]:
            isolated_app, _ = _app()
            with TestClient(isolated_app) as isolated:
                start.wait(timeout=5)
                response = isolated.post(
                    f"/api/v1/credit-accounts/{account['id']}/schedule-change",
                    headers={**auth, "Idempotency-Key": str(uuid4())},
                    json=schedule_payload,
                )
                return response.status_code, response.json()

        def checkpoint() -> tuple[int, dict[str, object]]:
            isolated_app, _ = _app()
            with TestClient(isolated_app) as isolated:
                start.wait(timeout=5)
                response = isolated.post(
                    "/api/v1/reconciliation/checkpoints",
                    headers=auth,
                    json={
                        "target_kind": "credit_cycle",
                        "credit_cycle_id": purchase["credit_cycle_id"],
                        "as_of": "2026-08-11T10:00:00+08:00",
                        "actual_balance_minor": 12_345,
                    },
                )
                return response.status_code, response.json()

        with ThreadPoolExecutor(max_workers=2) as executor:
            committed_future = executor.submit(commit)
            checkpointed_future = executor.submit(checkpoint)
            committed = committed_future.result()
            checkpointed = checkpointed_future.result()
        statuses = {committed[0], checkpointed[0]}
        assert statuses in ({200, 404}, {409, 201})
        for status, body in (committed, checkpointed):
            if status >= 400:
                assert body["error"]["code"] in {
                    "credit_schedule_preview_stale",
                    "credit_cycle_not_found",
                }
        if committed[0] == 200:
            moved = client.get(f"/api/v1/transactions/{purchase['id']}", headers=auth)
            assert moved.status_code == 200
            current_checkpoint = client.post(
                "/api/v1/reconciliation/checkpoints",
                headers=auth,
                json={
                    "target_kind": "credit_cycle",
                    "credit_cycle_id": moved.json()["credit_cycle_id"],
                    "as_of": "2026-08-11T10:00:00+08:00",
                    "actual_balance_minor": 12_345,
                },
            )
            assert current_checkpoint.status_code == 201, current_checkpoint.text


def test_p33_schedule_commit_stale_is_zero_write_and_patch_cannot_bypass() -> None:
    app, auth = _app()
    with TestClient(app) as client:
        account = _credit_account(client, auth)
        category = _category(client, auth)
        _purchase(client, auth, str(account["id"]), str(category["id"]))
        preview = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_preview_payload(account),
        )
        assert preview.status_code == 200, preview.text
        _purchase(client, auth, str(account["id"]), str(category["id"]), amount=456)
        before_commit = _revision()
        stale = client.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**_preview_payload(account), "preview_token": preview.json()["preview_token"]},
        )
        assert stale.status_code == 409, stale.text
        assert stale.json()["error"]["code"] == "credit_schedule_preview_stale"
        assert stale.json()["error"]["details"]["available_actions"] == [
            "reload_credit_account",
            "preview_schedule_change",
        ]
        assert _revision() == before_commit
        unchanged = client.get(f"/api/v1/accounts/{account['id']}", headers=auth)
        assert unchanged.json()["statement_day"] == 1
        bypass = client.patch(
            f"/api/v1/accounts/{account['id']}",
            headers=auth,
            json={"expected_version": account["version"], "statement_day": 5},
        )
        assert bypass.status_code == 409
        assert bypass.json()["error"]["code"] == "credit_schedule_preview_required"


def test_p33_schedule_two_sessions_repayment_settled_cycle_and_calendar_edges() -> None:
    app, auth = _app()
    with TestClient(app) as first:
        account = _credit_account(first, auth)
        category = _category(first, auth)
        payment = _debit_account(first, auth)
        purchase = _purchase(first, auth, str(account["id"]), str(category["id"]), amount=1_000)
        repayment = first.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "repayment",
                "amount_minor": 1_000,
                "occurred_at": "2026-08-11T10:00:00+08:00",
                "title": "P33 全额还款",
                "account_id": payment["id"],
                "destination_account_id": account["id"],
                "credit_cycle_id": purchase["credit_cycle_id"],
            },
        )
        assert repayment.status_code == 201, repayment.text
        first_preview = first.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_preview_payload(account),
        )
        # Each request receives a fresh database session; using one TestClient
        # keeps asyncpg on one event loop while still exercising two snapshots.
        second_preview = first.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change-preview",
            headers=auth,
            json=_preview_payload(account),
        )
        assert first_preview.status_code == second_preview.status_code == 200
        # A settled cycle remains historical evidence and is deliberately not remapped.
        assert first_preview.json()["affected_cycle_count"] == 0
        committed = first.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                **_preview_payload(account),
                "preview_token": first_preview.json()["preview_token"],
            },
        )
        assert committed.status_code == 200, committed.text
        stale = first.post(
            f"/api/v1/credit-accounts/{account['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                **_preview_payload(account),
                "preview_token": second_preview.json()["preview_token"],
            },
        )
        assert stale.status_code == 409
        assert stale.json()["error"]["code"] == "credit_schedule_preview_stale"
        unchanged_purchase = first.get(f"/api/v1/transactions/{purchase['id']}", headers=auth)
        assert unchanged_purchase.json()["credit_cycle_id"] == purchase["credit_cycle_id"]

    # Every date calculation is business-date based and preserves short-month / year boundaries.
    assert credit_schedule(date(2027, 2, 28), 28, 1).due_date == date(2027, 3, 1)
    assert credit_schedule(date(2026, 12, 31), 28, 28).statement_date == date(2027, 1, 28)
    assert schedule_for_statement(
        date(2027, 2, 28), 28, 28, CreditCycleMode.PREVIOUS_CALENDAR_MONTH
    ).due_date == date(2027, 3, 28)
