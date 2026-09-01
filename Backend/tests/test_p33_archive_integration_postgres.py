from __future__ import annotations

import asyncio
from os import environ
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import Settings, get_settings
from fiscal_api.db.models import AIProposal, StatementImport, StatementImportRow
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.main import create_app
from fiscal_api.services.archive import ArchiveService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


async def _ready() -> None:
    return None


def _app() -> tuple[object, dict[str, str]]:
    assert TEST_DATABASE_URL is not None
    return (
        create_app(
            settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
            readiness_check=_ready,
        ),
        {"Authorization": "Bearer p33-archive-integration-token"},
    )


def _alembic_config() -> Config:
    return Config(str(Path(__file__).parents[1] / "alembic.ini"))


def _fresh_database_url(name: str) -> str:
    assert TEST_DATABASE_URL is not None
    return make_url(TEST_DATABASE_URL).set(database=name).render_as_string(hide_password=False)


async def _create_database(name: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(
        make_url(TEST_DATABASE_URL).set(database="postgres").render_as_string(hide_password=False),
        isolation_level="AUTOCOMMIT",
    )
    try:
        async with engine.connect() as connection:
            await connection.execute(text(f'CREATE DATABASE "{name}"'))
    finally:
        await engine.dispose()


async def _drop_database(name: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(
        make_url(TEST_DATABASE_URL).set(database="postgres").render_as_string(hide_password=False),
        isolation_level="AUTOCOMMIT",
    )
    try:
        async with engine.connect() as connection:
            await connection.execute(text(f'DROP DATABASE IF EXISTS "{name}"'))
    finally:
        await engine.dispose()


async def _add_ai_and_import_references(cycle_id: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_engine(TEST_DATABASE_URL)
    try:
        async with create_session_factory(engine)() as session:
            session.add(
                AIProposal(
                    source="text",
                    raw_input="P33 archive credit-cycle reference",
                    content_fingerprint="a" * 64,
                    create_idempotency_key=uuid4(),
                    create_request_hash="b" * 64,
                    target="transaction",
                    status="pending",
                    credit_cycle_id=UUID(cycle_id),
                )
            )
            statement = StatementImport(
                document_sha256=(uuid4().hex * 2)[:64],
                byte_size=1,
                page_count=1,
                mime_type="application/pdf",
                display_name="statement.pdf",
                status="created",
            )
            session.add(statement)
            await session.flush()
            session.add(
                StatementImportRow(
                    statement_import_id=statement.id,
                    row_number=1,
                    credit_cycle_id_candidate=UUID(cycle_id),
                )
            )
            await session.commit()
    finally:
        await engine.dispose()


async def _source_fingerprint() -> dict[str, object]:
    assert TEST_DATABASE_URL is not None
    engine = create_engine(TEST_DATABASE_URL)
    try:
        async with engine.connect() as connection:
            return {
                "data_revision": await connection.scalar(
                    text("SELECT revision FROM data_revision WHERE id = 1")
                ),
                "posting_balance": await connection.scalar(
                    text("SELECT coalesce(sum(amount_minor), 0) FROM postings")
                ),
                "posting_absolute": await connection.scalar(
                    text("SELECT coalesce(sum(abs(amount_minor)), 0) FROM postings")
                ),
                "transactions": await connection.scalar(
                    text(
                        "SELECT coalesce(string_agg(id::text || ':' || version::text, ',' "
                        "ORDER BY id), '') FROM transactions"
                    )
                ),
                "plans": await connection.scalar(
                    text(
                        "SELECT coalesce(string_agg(id::text || ':' || lifecycle || ':' || "
                        "version::text, ',' ORDER BY id), '') FROM installment_plans"
                    )
                ),
                "receipts": await connection.scalar(
                    text(
                        "SELECT coalesce(string_agg(id::text || ':' || version::text, ',' "
                        "ORDER BY id), '') FROM reimbursement_receipts"
                    )
                ),
                # Archive deliberately clears the short-lived preview FK from a
                # permanent reimbursement receipt. Compare only portable formal
                # identity here; the source preview linkage is asserted below.
                "operations": await connection.scalar(
                    text(
                        "SELECT coalesce(string_agg("
                        "id::text || ':' || claim_id::text || ':' || "
                        "coalesce(receipt_id::text, '') || ':', ',' "
                        "ORDER BY id), '') FROM reimbursement_operations"
                    )
                ),
                "operation_preview_count": await connection.scalar(
                    text(
                        "SELECT count(*) FROM reimbursement_operations WHERE preview_id IS NOT NULL"
                    )
                ),
                "references": await connection.scalar(
                    text(
                        "SELECT coalesce(string_agg("
                        "kind || ':' || cycle_id, ',' ORDER BY kind), '') "
                        "FROM ("
                        " SELECT 'ai' AS kind, credit_cycle_id::text AS cycle_id "
                        " FROM ai_proposals "
                        " WHERE credit_cycle_id IS NOT NULL"
                        " UNION ALL SELECT 'import', credit_cycle_id_candidate::text "
                        " FROM statement_import_rows WHERE credit_cycle_id_candidate IS NOT NULL"
                        ") refs"
                    )
                ),
            }
    finally:
        await engine.dispose()


def _post(
    client: TestClient, path: str, auth: dict[str, str], payload: dict[str, object]
) -> dict[str, object]:
    response = client.post(path, headers=auth, json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def test_p33_archive_round_trip_preserves_formal_facts_and_excludes_operational_tokens(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Exercise P33 records together in one encrypted archive/fresh-target restore."""
    app, auth = _app()
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        debit = _post(
            client,
            "/api/v1/accounts",
            auth,
            {
                "name": f"P33 archive debit {suffix}",
                "kind": "debit",
                "opening_balance_minor": 500_000,
            },
        )
        category = _post(
            client,
            "/api/v1/categories",
            auth,
            {
                "name": f"P33 archive category {suffix}",
                "direction": "expense",
                "icon": "tag",
                "color_hex": "#123456",
            },
        )
        schedule_card = _post(
            client,
            "/api/v1/accounts",
            auth,
            {
                "name": f"P33 schedule card {suffix}",
                "kind": "credit",
                "opening_balance_minor": 0,
                "credit_limit_minor": 500_000,
                "statement_day": 1,
                "due_day": 20,
            },
        )
        schedule_purchase = _post(
            client,
            "/api/v1/transactions",
            {**auth, "Idempotency-Key": str(uuid4())},
            {
                "kind": "credit_purchase",
                "amount_minor": 12_345,
                "occurred_at": "2026-08-10T10:00:00+08:00",
                "title": "P33 archive schedule purchase",
                "account_id": schedule_card["id"],
                "category_id": category["id"],
            },
        )
        schedule_request = {
            "expected_version": schedule_card["version"],
            "cycle_mode": "previous_calendar_month",
            "statement_day": 5,
            "due_day": 25,
        }
        schedule_preview = client.post(
            f"/api/v1/credit-accounts/{schedule_card['id']}/schedule-change-preview",
            headers=auth,
            json=schedule_request,
        )
        assert schedule_preview.status_code == 200, schedule_preview.text
        schedule_commit = client.post(
            f"/api/v1/credit-accounts/{schedule_card['id']}/schedule-change",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**schedule_request, "preview_token": schedule_preview.json()["preview_token"]},
        )
        assert schedule_commit.status_code == 200, schedule_commit.text

        installment_card = _post(
            client,
            "/api/v1/accounts",
            auth,
            {
                "name": f"P33 installment card {suffix}",
                "kind": "credit",
                "opening_balance_minor": 0,
                "credit_limit_minor": 500_000,
                "statement_day": 10,
                "due_day": 20,
            },
        )
        installment = _post(
            client,
            "/api/v1/installment-purchases",
            {**auth, "Idempotency-Key": str(uuid4())},
            {
                "purchase": {
                    "kind": "credit_purchase",
                    "amount_minor": 4_000,
                    "occurred_at": "2026-07-15T10:00:00+08:00",
                    "title": "P33 completed installment",
                    "account_id": installment_card["id"],
                    "category_id": category["id"],
                },
                "installment_count": 2,
                "total_fee_minor": 0,
                "start_statement_date": "2026-08-10",
            },
        )["plan"]
        assert isinstance(installment, dict)
        for period in installment["periods"]:
            assert isinstance(period, dict)
            repayment = client.post(
                "/api/v1/transactions",
                headers={**auth, "Idempotency-Key": str(uuid4())},
                json={
                    "kind": "repayment",
                    "amount_minor": period["amount_due_minor"],
                    "occurred_at": "2027-03-01T01:00:00+08:00",
                    "title": f"P33 archive repayment {period['sequence']}",
                    "account_id": debit["id"],
                    "destination_account_id": installment_card["id"],
                    "credit_cycle_id": period["effective_cycle_id"],
                },
            )
            assert repayment.status_code == 201, repayment.text
        completed = client.get(f"/api/v1/installment-plans/{installment['id']}", headers=auth)
        assert completed.status_code == 200, completed.text
        assert completed.json()["status"] == "completed"

        expense = _post(
            client,
            "/api/v1/transactions",
            {**auth, "Idempotency-Key": str(uuid4())},
            {
                "kind": "expense",
                "amount_minor": 30_000,
                "occurred_at": "2026-07-15T08:00:00+08:00",
                "title": "P33 archive reimbursable expense",
                "account_id": debit["id"],
                "category_id": category["id"],
            },
        )
        claim = _post(
            client,
            "/api/v1/reimbursement-claims",
            {**auth, "Idempotency-Key": str(uuid4())},
            {
                "title": "P33 archive reimbursement",
                "parties": [
                    {
                        "name": "P33 employer",
                        "allocations": [{"transaction_id": expense["id"], "amount_minor": 20_000}],
                    }
                ],
            },
        )
        receipt_draft = {
            "expected_claim_version": claim["version"],
            "party_id": claim["parties"][0]["id"],
            "amount_minor": 12_000,
            "received_at": "2026-08-13T12:00:00+08:00",
            "destination_account_id": debit["id"],
            "title": "P33 archive reimbursement receipt",
        }
        receipt_preview = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/receipt-preview",
            headers=auth,
            json=receipt_draft,
        )
        assert receipt_preview.status_code == 200, receipt_preview.text
        receipt = client.post(
            f"/api/v1/reimbursement-claims/{claim['id']}/receipts",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={**receipt_draft, "preview_token": receipt_preview.json()["preview_token"]},
        )
        assert receipt.status_code == 201, receipt.text

        cycle_id = installment["periods"][0]["effective_cycle_id"]
        asyncio.run(_add_ai_and_import_references(str(cycle_id)))

        password = uuid4().hex + uuid4().hex
        exported = client.post(
            "/api/v1/archives/export",
            headers=auth,
            json={"password": password, "include_ai_raw": False},
        )
        assert exported.status_code == 200, exported.text

    source_fingerprint = asyncio.run(_source_fingerprint())
    manifest, payload = ArchiveService.open(exported.content, password=password)
    assert "credit_schedule_change_previews" not in payload["entities"]
    assert "credit_schedule_change_operations" not in payload["entities"]
    assert "reimbursement_previews" not in payload["entities"]
    assert source_fingerprint["operation_preview_count"] == 1
    assert len(payload["entities"]["reimbursement_operations"]) == 1
    assert payload["entities"]["reimbursement_operations"][0]["preview_id"] is None

    target_name = f"fiscal_p33_archive_restore_{uuid4().hex}"
    target_url = _fresh_database_url(target_name)
    asyncio.run(_create_database(target_name))
    try:
        monkeypatch.setenv("FISCAL_DATABASE_URL", target_url)
        get_settings.cache_clear()
        command.upgrade(_alembic_config(), "head")

        async def restore_and_compare() -> None:
            engine = create_engine(target_url)
            try:
                async with engine.begin() as connection:
                    await ArchiveService.restore_empty_target(
                        connection, manifest=manifest, payload=payload
                    )
                async with engine.connect() as connection:
                    assert (
                        await connection.scalar(
                            text("SELECT count(*) FROM credit_schedule_change_previews")
                        )
                        == 0
                    )
                    assert (
                        await connection.scalar(
                            text("SELECT count(*) FROM credit_schedule_change_operations")
                        )
                        == 0
                    )
                    assert (
                        await connection.scalar(text("SELECT count(*) FROM reimbursement_previews"))
                        == 0
                    )
                    assert (
                        await connection.scalar(
                            text("SELECT revision FROM data_revision WHERE id = 1")
                        )
                        == source_fingerprint["data_revision"]
                    )
                    assert (
                        await connection.scalar(
                            text("SELECT coalesce(sum(amount_minor), 0) FROM postings")
                        )
                        == source_fingerprint["posting_balance"]
                    )
                    assert (
                        await connection.scalar(
                            text("SELECT coalesce(sum(abs(amount_minor)), 0) FROM postings")
                        )
                        == source_fingerprint["posting_absolute"]
                    )
                    assert (
                        await connection.scalar(
                            text(
                                "SELECT coalesce(string_agg(id::text || ':' || version::text, ',' "
                                "ORDER BY id), '') FROM transactions"
                            )
                        )
                        == source_fingerprint["transactions"]
                    )
                    assert (
                        await connection.scalar(
                            text(
                                "SELECT coalesce(string_agg(id::text || ':' || lifecycle || ':' || "
                                "version::text, ',' ORDER BY id), '') FROM installment_plans"
                            )
                        )
                        == source_fingerprint["plans"]
                    )
                    assert (
                        await connection.scalar(
                            text(
                                "SELECT coalesce(string_agg(id::text || ':' || version::text, ',' "
                                "ORDER BY id), '') FROM reimbursement_receipts"
                            )
                        )
                        == source_fingerprint["receipts"]
                    )
                    assert (
                        await connection.scalar(
                            text(
                                "SELECT coalesce(string_agg("
                                "id::text || ':' || claim_id::text || ':' || "
                                "coalesce(receipt_id::text, '') || ':' || "
                                "coalesce(preview_id::text, ''), ',' "
                                "ORDER BY id), '') FROM reimbursement_operations"
                            )
                        )
                        == source_fingerprint["operations"]
                    )
                    assert (
                        await connection.scalar(
                            text(
                                "SELECT coalesce(string_agg("
                                "kind || ':' || cycle_id, ',' ORDER BY kind), '') "
                                "FROM ("
                                " SELECT 'ai' AS kind, credit_cycle_id::text AS cycle_id "
                                " FROM ai_proposals "
                                " WHERE credit_cycle_id IS NOT NULL"
                                " UNION ALL SELECT 'import', credit_cycle_id_candidate::text "
                                " FROM statement_import_rows "
                                " WHERE credit_cycle_id_candidate IS NOT NULL"
                                ") refs"
                            )
                        )
                        == source_fingerprint["references"]
                    )
            finally:
                await engine.dispose()

        asyncio.run(restore_and_compare())
    finally:
        asyncio.run(_drop_database(target_name))
        monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
        get_settings.cache_clear()
    assert schedule_purchase["id"]
    assert receipt.json()["id"]
