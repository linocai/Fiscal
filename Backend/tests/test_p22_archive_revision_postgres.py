from __future__ import annotations

import argparse
import asyncio
import copy
import hashlib
import io
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from os import environ
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.cli import archive_export
from fiscal_api.core.config import Settings, get_settings
from fiscal_api.db.base import Base
from fiscal_api.db.models.ai import AIProposal, AISettings
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.main import create_app
from fiscal_api.services.access import AccessService
from fiscal_api.services.archive import ArchiveError, ArchiveService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")


async def _ready() -> None:
    return None


def _client() -> TestClient:
    assert TEST_DATABASE_URL is not None
    return TestClient(
        create_app(
            settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
            readiness_check=_ready,
        )
    )


def _account_payload() -> dict[str, object]:
    return {
        "name": f"P22 account {uuid4().hex[:8]}",
        "kind": "debit",
        "opening_balance_minor": 10_000,
    }


def _category_payload() -> dict[str, object]:
    return {
        "name": f"P22 category {uuid4().hex[:8]}",
        "direction": "expense",
        "icon": "tag",
        "color_hex": "#123456",
    }


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


def test_p22_archive_crypto_contract_runs_without_postgres() -> None:
    entities = {
        table.name: []
        for table in Base.metadata.sorted_tables
        if table.name
        not in {
            "access_credential",
            "access_keys",
            "data_revision",
            "category_transform_previews",
            "category_transform_operations",
            "credit_schedule_change_previews",
            "credit_schedule_change_operations",
            "reimbursement_previews",
        }
    }
    payload = {"entities": entities, "data_revision": 0}
    canonical = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()
    manifest = {
        "archive_schema": "fiscal-archive-v1",
        "api_schema": "fiscal-api-v1",
        "exported_at": "2026-08-11T00:00:00+00:00",
        "business_timezone": "Asia/Shanghai",
        "currency": "CNY",
        "database_revision": "20260811_0022",
        "data_revision": 0,
        "entity_counts": {name: 0 for name in entities},
        "payload_sha256": hashlib.sha256(canonical).hexdigest(),
        "includes_ai_raw": False,
    }
    password = uuid4().hex + uuid4().hex
    archive = ArchiveService._seal(password=password, manifest=manifest, payload=canonical)
    assert ArchiveService.open(archive, password=password)[0] == manifest
    with pytest.raises(ArchiveError):
        ArchiveService.open(archive, password=uuid4().hex + uuid4().hex)
    with pytest.raises(ArchiveError):
        ArchiveService.open(archive[:-1] + bytes([archive[-1] ^ 1]), password=password)
    malformed = json.loads(canonical)
    malformed["entities"]["postings"] = [{"id": "duplicate"}]
    malformed["entities"]["transactions"] = [{"id": "duplicate"}]
    with pytest.raises(ArchiveError):
        ArchiveService.dry_run_report(manifest, malformed)


def test_p22_public_archive_schema_is_fail_closed_for_ai_raw() -> None:
    from pydantic import ValidationError

    from fiscal_api.api.p22_schemas import ArchiveExportRequest

    password = uuid4().hex + uuid4().hex
    assert ArchiveExportRequest(password=password).include_ai_raw is False
    with pytest.raises(ValidationError):
        ArchiveExportRequest(password=password, include_ai_raw=True)
    raw_schema = ArchiveExportRequest.model_json_schema()["properties"]["include_ai_raw"]
    assert raw_schema.get("const") is False or raw_schema.get("enum") == [False]


def test_p22_archive_export_cli_requires_password_on_stdin(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    output = tmp_path / "archive.far"
    monkeypatch.setattr(sys, "argv", ["archive_export.py", str(output)])
    monkeypatch.setattr(sys, "stdin", io.StringIO("too-short\n"))
    with pytest.raises(SystemExit, match="standard input"):
        archive_export.main()
    assert not output.exists()


class _FakeExportEngine:
    async def dispose(self) -> None:
        return None


class _FakeExportSession:
    async def __aenter__(self) -> _FakeExportSession:
        return self

    async def __aexit__(self, *_: object) -> None:
        return None


def _stub_cli_export_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(archive_export, "create_engine", lambda _: _FakeExportEngine())
    monkeypatch.setattr(
        archive_export,
        "create_session_factory",
        lambda _: lambda: _FakeExportSession(),
    )


def test_p22_archive_export_cli_removes_only_its_failed_reservation(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    password = uuid4().hex + uuid4().hex
    _stub_cli_export_environment(monkeypatch)

    async def failed_export(
        self: ArchiveService, *, password: str, include_ai_raw: bool
    ) -> tuple[bytes, dict[str, object]]:
        raise RuntimeError("simulated archive export failure")

    monkeypatch.setattr(ArchiveService, "export", failed_export)
    export_failure = tmp_path / "export-failure.far"
    with pytest.raises(RuntimeError, match="simulated archive export failure"):
        asyncio.run(
            archive_export._run(
                argparse.Namespace(output=export_failure, include_ai_raw=False), password
            )
        )
    assert not export_failure.exists()

    async def successful_export(
        self: ArchiveService, *, password: str, include_ai_raw: bool
    ) -> tuple[bytes, dict[str, object]]:
        return b"would-be-archive", {}

    monkeypatch.setattr(ArchiveService, "export", successful_export)
    real_open = Path.open

    class PartialWriteFailure:
        def __init__(self, output: object) -> None:
            self.output = output

        def __enter__(self) -> PartialWriteFailure:
            return self

        def __exit__(self, *args: object) -> object:
            return self.output.__exit__(*args)  # type: ignore[union-attr,no-any-return]

        def write(self, value: bytes) -> int:
            self.output.write(value[:4])  # type: ignore[union-attr,no-any-return]
            raise OSError("simulated partial write failure")

        def flush(self) -> None:
            self.output.flush()  # type: ignore[union-attr]

        def fileno(self) -> int:
            return self.output.fileno()  # type: ignore[union-attr,no-any-return]

    monkeypatch.setattr(
        Path,
        "open",
        lambda path, *args, **kwargs: PartialWriteFailure(real_open(path, *args, **kwargs)),
    )
    write_failure = tmp_path / "write-failure.far"
    with pytest.raises(OSError, match="simulated partial write failure"):
        asyncio.run(
            archive_export._run(
                argparse.Namespace(output=write_failure, include_ai_raw=False), password
            )
        )
    assert not write_failure.exists()


def test_p22_archive_export_cli_rejects_existing_before_export(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    output = tmp_path / "existing.far"
    output.write_bytes(b"do-not-overwrite")
    called = False

    async def must_not_export(
        self: ArchiveService, *, password: str, include_ai_raw: bool
    ) -> tuple[bytes, dict[str, object]]:
        nonlocal called
        called = True
        return b"unexpected", {}

    monkeypatch.setattr(ArchiveService, "export", must_not_export)
    with pytest.raises(FileExistsError):
        asyncio.run(
            archive_export._run(
                argparse.Namespace(output=output, include_ai_raw=False), uuid4().hex + uuid4().hex
            )
        )
    assert called is False
    assert output.read_bytes() == b"do-not-overwrite"


@pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
def test_p22_archive_restore_allows_only_fresh_migration_seed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    password = uuid4().hex + uuid4().hex

    async def source_archive() -> tuple[dict[str, object], dict[str, object]]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                session.add(
                    AISettings(
                        id=1,
                        auto_execute_enabled=False,
                        ocr_source_enabled=False,
                        shortcut_text_source_enabled=False,
                        auto_execute_limit_minor=100_000,
                        minimum_confidence_bps=9_000,
                        provider_kind=None,
                        provider_base_url=None,
                        provider_model=None,
                        provider_api_key_ciphertext=None,
                        provider_key_version=None,
                        version=1,
                    )
                )
                await session.commit()
                archive, _ = await ArchiveService(session).export(
                    password=password, include_ai_raw=False
                )
                return ArchiveService.open(archive, password=password)
        finally:
            await engine.dispose()

    manifest, payload = asyncio.run(source_archive())

    def migrate_fresh(database_url: str) -> None:
        monkeypatch.setenv("FISCAL_DATABASE_URL", database_url)
        get_settings.cache_clear()
        command.upgrade(_alembic_config(), "head")

    async def run_case(case: str, database_url: str) -> None:
        engine = create_engine(database_url)
        try:
            async with engine.begin() as connection:
                assert await connection.scalar(text("SELECT count(*) FROM ai_settings")) == 1
                assert (
                    await connection.scalar(text("SELECT revision FROM data_revision WHERE id = 1"))
                    == 0
                )
                if case == "changed_seed":
                    await connection.execute(text("UPDATE ai_settings SET version = 2"))
                    with pytest.raises(ArchiveError, match="noncanonical ai_settings"):
                        await ArchiveService.restore_empty_target(
                            connection, manifest=manifest, payload=payload
                        )
                    assert await connection.scalar(text("SELECT version FROM ai_settings")) == 2
                elif case == "data_revision":
                    await connection.execute(text("UPDATE data_revision SET revision = 1"))
                    with pytest.raises(ArchiveError, match="data revision is not pristine"):
                        await ArchiveService.restore_empty_target(
                            connection, manifest=manifest, payload=payload
                        )
                    assert await connection.scalar(text("SELECT revision FROM data_revision")) == 1
                elif case == "other_data":
                    await connection.execute(
                        Base.metadata.tables["categories"]
                        .insert()
                        .values(
                            name=f"P22 nonempty {uuid4().hex}",
                            direction="expense",
                            icon="tag",
                            color_hex="#123456",
                        )
                    )
                    with pytest.raises(
                        ArchiveError, match=r"restore target is not empty \(categories\)"
                    ):
                        await ArchiveService.restore_empty_target(
                            connection, manifest=manifest, payload=payload
                        )
                    assert await connection.scalar(text("SELECT count(*) FROM categories")) == 1
                else:
                    await ArchiveService.restore_empty_target(
                        connection, manifest=manifest, payload=payload
                    )
                    assert await connection.scalar(text("SELECT count(*) FROM ai_settings")) == 1
                    assert await connection.scalar(text("SELECT revision FROM data_revision")) == 0
                assert await connection.scalar(text("SELECT count(*) FROM accounts")) == 0
        finally:
            await engine.dispose()

    try:
        for case in ("success", "changed_seed", "data_revision", "other_data"):
            name = f"fiscal_p22_seed_{uuid4().hex}"
            fresh_url = _fresh_database_url(name)
            asyncio.run(_create_database(name))
            try:
                migrate_fresh(fresh_url)
                asyncio.run(run_case(case, fresh_url))
            finally:
                asyncio.run(_drop_database(name))
    finally:
        monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
        get_settings.cache_clear()


@pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
def test_p22_revision_receipts_are_formal_once_and_concurrent() -> None:
    auth = {"Authorization": "Bearer p22-token"}
    with _client() as client:
        initial = client.get("/api/v1/data-revision", headers=auth)
        assert initial.status_code == 200
        baseline = initial.json()["revision"]
        account = client.post("/api/v1/accounts", headers=auth, json=_account_payload())
        assert account.status_code == 201, account.text
        assert account.headers["X-Fiscal-Data-Revision"] == str(baseline + 1)
        assert account.headers["X-Fiscal-Affected-Scopes"].split(",")[0] == "accounts"

        preview = client.post(
            f"/api/v1/credit-accounts/{account.json()['id']}/schedule-change-preview",
            headers=auth,
            json={"expected_version": account.json()["version"], "statement_day": 5, "due_day": 15},
        )
        assert preview.status_code in {200, 422}
        assert "X-Fiscal-Data-Revision" not in preview.headers

        category = client.post("/api/v1/categories", headers=auth, json=_category_payload()).json()
        key = str(uuid4())
        transaction_payload = {
            "kind": "expense",
            "amount_minor": 100,
            "occurred_at": "2026-08-11T12:00:00+08:00",
            "title": "P22 idempotent receipt",
            "account_id": account.json()["id"],
            "category_id": category["id"],
        }
        created = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": key},
            json=transaction_payload,
        )
        assert created.status_code == 201, created.text
        replay = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": key},
            json=transaction_payload,
        )
        assert replay.status_code == 201, replay.text
        assert "X-Fiscal-Data-Revision" not in replay.headers

        start = client.get("/api/v1/data-revision", headers=auth).json()["revision"]

        def create_category(_: int) -> int:
            response = client.post("/api/v1/categories", headers=auth, json=_category_payload())
            assert response.status_code == 201, response.text
            return int(response.headers["X-Fiscal-Data-Revision"])

        with ThreadPoolExecutor(max_workers=4) as pool:
            receipts = list(pool.map(create_category, range(4)))
        assert sorted(receipts) == list(range(start + 1, start + 5))
        assert client.get("/api/v1/data-revision", headers=auth).json()["revision"] == start + 4


@pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
def test_p22_real_auth_dependency_sees_formal_scopes_at_commit() -> None:
    assert TEST_DATABASE_URL is not None
    token_pepper = f"p22-real-auth-{uuid4().hex}"
    settings = Settings(
        environment="local",
        database_url=TEST_DATABASE_URL,
        token_pepper=token_pepper,
    )

    async def mint_access_key() -> str:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            factory = create_session_factory(engine)
            async with factory() as session:
                return (
                    await AccessService(session, settings).initialize("p22-test-passphrase")
                ).raw_key
        finally:
            await engine.dispose()

    access_key = asyncio.run(mint_access_key())
    app = create_app(settings=settings, readiness_check=_ready)
    auth = {"Authorization": f"Bearer {access_key}"}
    with TestClient(app) as client:
        baseline = client.get("/api/v1/data-revision", headers=auth)
        assert baseline.status_code == 200
        assert baseline.json()["revision"] == 0

        category = client.post("/api/v1/categories", headers=auth, json=_category_payload())
        assert category.status_code == 201, category.text
        assert category.headers["X-Fiscal-Data-Revision"] == "1"
        assert set(category.headers["X-Fiscal-Affected-Scopes"].split(",")) == {
            "ledger",
            "accounts",
            "credit",
            "reimbursements",
            "cash_flow",
            "reconciliation",
            "attention",
            "reports",
            "ai",
        }

        deleted = client.delete(
            f"/api/v1/categories/{category.json()['id']}?expected_version=1", headers=auth
        )
        assert deleted.status_code == 204, deleted.text
        assert deleted.headers["X-Fiscal-Data-Revision"] == "2"
        assert client.get("/api/v1/data-revision", headers=auth).json()["revision"] == 2


@pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
def test_p22_credit_get_projection_is_read_only_and_transaction_materializes_once() -> None:
    auth = {"Authorization": "Bearer p22-token"}

    async def cycle_ids() -> list[str]:
        assert TEST_DATABASE_URL is not None
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with engine.connect() as connection:
                return list(
                    (
                        await connection.scalars(
                            text("SELECT id::text FROM credit_cycles ORDER BY id")
                        )
                    ).all()
                )
        finally:
            await engine.dispose()

    with _client() as client:
        debit = client.post("/api/v1/accounts", headers=auth, json=_account_payload())
        assert debit.status_code == 201, debit.text
        credit = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"P22 credit {uuid4().hex[:8]}",
                "kind": "credit",
                "opening_balance_minor": 0,
                "credit_limit_minor": 100_000,
                "statement_day": 10,
                "due_day": 22,
            },
        )
        assert credit.status_code == 201, credit.text
        category = client.post("/api/v1/categories", headers=auth, json=_category_payload())
        assert category.status_code == 201, category.text
        baseline = client.get("/api/v1/data-revision", headers=auth).json()["revision"]
        before_cycles = asyncio.run(cycle_ids())

        summary = client.get(f"/api/v1/credit-accounts/{credit.json()['id']}", headers=auth)
        assert summary.status_code == 200, summary.text
        assert "X-Fiscal-Data-Revision" not in summary.headers
        projected_id = summary.json()["current_cycle"]["id"]
        repeated = client.get(f"/api/v1/credit-accounts/{credit.json()['id']}", headers=auth)
        assert repeated.status_code == 200
        assert repeated.json()["current_cycle"]["id"] == projected_id
        cycle = client.get(f"/api/v1/credit-cycles/{projected_id}", headers=auth)
        assert cycle.status_code == 200, cycle.text
        assert cycle.json()["id"] == projected_id
        assert asyncio.run(cycle_ids()) == before_cycles
        assert client.get("/api/v1/data-revision", headers=auth).json()["revision"] == baseline

        created = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "credit_purchase",
                "amount_minor": 100,
                "occurred_at": "2026-08-11T12:00:00+08:00",
                "title": "P22 projected credit cycle",
                "account_id": credit.json()["id"],
                "category_id": category.json()["id"],
            },
        )
        assert created.status_code == 201, created.text
        assert created.json()["credit_cycle_id"] == projected_id
        assert created.headers["X-Fiscal-Data-Revision"] == str(baseline + 1)
        assert asyncio.run(cycle_ids()) == sorted([*before_cycles, projected_id])
        assert client.get("/api/v1/data-revision", headers=auth).json()["revision"] == baseline + 1


@pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
def test_p22_public_archive_rejects_ai_raw_before_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    called = False

    async def must_not_export(
        self: ArchiveService, *, password: str, include_ai_raw: bool
    ) -> tuple[bytes, dict[str, object]]:
        nonlocal called
        called = True
        raise AssertionError("invalid public Archive request must not call service")

    monkeypatch.setattr(ArchiveService, "export", must_not_export)
    with _client() as client:
        rejected = client.post(
            "/api/v1/archives/export",
            headers={"Authorization": "Bearer p22-raw-ai-rejected"},
            json={"password": uuid4().hex + uuid4().hex, "include_ai_raw": True},
        )
        assert rejected.status_code == 422, rejected.text
        assert called is False
        document = client.get("/openapi.json").json()
    request_schema = document["components"]["schemas"]["ArchiveExportRequest"]
    raw_schema = request_schema["properties"]["include_ai_raw"]
    assert raw_schema.get("const") is False or raw_schema.get("enum") == [False]


@pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
def test_p22_public_archive_export_artifact_is_fixed_redacted() -> None:
    password = uuid4().hex + uuid4().hex
    with _client() as client:
        exported = client.post(
            "/api/v1/archives/export",
            headers={"Authorization": "Bearer p22-fixed-redaction"},
            json={"password": password, "include_ai_raw": False},
        )
        assert exported.status_code == 200, exported.text
    manifest, _payload = ArchiveService.open(exported.content, password=password)
    assert manifest["includes_ai_raw"] is False


@pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
def test_p22_archive_round_trip_rejects_tampering_and_secrets() -> None:
    assert TEST_DATABASE_URL is not None
    auth = {"Authorization": "Bearer p22-token"}
    password = uuid4().hex + uuid4().hex
    with _client() as client:
        account = client.post("/api/v1/accounts", headers=auth, json=_account_payload()).json()
        second_account = client.post(
            "/api/v1/accounts", headers=auth, json=_account_payload()
        ).json()
        assert second_account["id"] != account["id"]
        category = client.post("/api/v1/categories", headers=auth, json=_category_payload()).json()
        tx = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "expense",
                "amount_minor": 123,
                "occurred_at": "2026-08-11T12:00:00+08:00",
                "title": "P22 archive roundtrip",
                "account_id": account["id"],
                "category_id": category["id"],
            },
        )
        assert tx.status_code == 201, tx.text
        exported = client.post(
            "/api/v1/archives/export",
            headers=auth,
            json={"password": password, "include_ai_raw": False},
        )
        assert exported.status_code == 200, exported.text
        archive = exported.content
    assert b"access_credential" not in archive
    assert b"provider_api_key_ciphertext" not in archive
    manifest, payload = ArchiveService.open(archive, password=password)
    assert manifest["business_timezone"] == "Asia/Shanghai"
    assert manifest["currency"] == "CNY"
    assert manifest["entity_counts"]["transactions"] == 1
    assert manifest["includes_ai_raw"] is False
    with pytest.raises(ArchiveError):
        ArchiveService.open(archive, password=uuid4().hex + uuid4().hex)
    with pytest.raises(ArchiveError):
        ArchiveService.open(archive[:-1] + bytes([archive[-1] ^ 1]), password=password)

    # Mutate a real exported payload so these checks reach relationship
    # preflight rather than failing earlier on an incomplete synthetic row.
    duplicate_primary_key = copy.deepcopy(payload)
    duplicate_primary_key["entities"]["accounts"][1]["id"] = duplicate_primary_key["entities"][
        "accounts"
    ][0]["id"]
    with pytest.raises(ArchiveError, match="duplicate primary keys"):
        ArchiveService.dry_run_report(manifest, duplicate_primary_key)

    orphan_posting = copy.deepcopy(payload)
    orphan_posting["entities"]["postings"][0]["transaction_id"] = str(uuid4())
    with pytest.raises(ArchiveError, match="orphan foreign key"):
        ArchiveService.dry_run_report(manifest, orphan_posting)

    async def restore() -> None:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with engine.begin() as connection:
                tables = list(
                    (
                        await connection.scalars(
                            text(
                                "SELECT quote_ident(tablename) FROM pg_tables "
                                "WHERE schemaname = 'public' AND tablename <> 'alembic_version' "
                                "ORDER BY tablename"
                            )
                        )
                    ).all()
                )
                balance_fingerprint_sql = text(
                    "SELECT string_agg(id::text || ':' || current_balance::text, ',' ORDER BY id) "
                    "FROM ("
                    "  SELECT a.id, a.opening_balance_minor + "
                    "    CASE WHEN a.kind = 'credit' THEN "
                    "      -coalesce(sum(p.amount_minor) FILTER (WHERE t.id IS NOT NULL), 0) "
                    "    ELSE coalesce(sum(p.amount_minor) FILTER (WHERE t.id IS NOT NULL), 0) END "
                    "    AS current_balance "
                    "  FROM accounts a "
                    "  LEFT JOIN postings p ON p.account_id = a.id "
                    "  LEFT JOIN transactions t ON t.id = p.transaction_id AND t.voided_at IS NULL "
                    "  GROUP BY a.id, a.opening_balance_minor, a.kind"
                    ") balances"
                )
                report_fingerprint_sql = text(
                    "SELECT string_agg("
                    "id::text || ':' || kind || ':' || occurred_at::text || ':' || title, ',' "
                    "ORDER BY id"
                    ") FROM transactions"
                )
                expected_balance_fingerprint = await connection.scalar(balance_fingerprint_sql)
                expected_report_fingerprint = await connection.scalar(report_fingerprint_sql)
                expected_posting_totals = (
                    await connection.execute(
                        text(
                            "SELECT coalesce(sum(amount_minor), 0), "
                            "coalesce(sum(abs(amount_minor)), 0) FROM postings"
                        )
                    )
                ).one()
                await connection.execute(text(f"TRUNCATE TABLE {', '.join(tables)} CASCADE"))
                assert await connection.scalar(text("SELECT count(*) FROM accounts")) == 0
                await connection.execute(
                    AISettings.__table__.insert().values(
                        id=1,
                        auto_execute_enabled=False,
                        ocr_source_enabled=False,
                        shortcut_text_source_enabled=False,
                        auto_execute_limit_minor=100_000,
                        minimum_confidence_bps=9_000,
                        provider_kind=None,
                        provider_base_url=None,
                        provider_model=None,
                        provider_api_key_ciphertext=None,
                        provider_key_version=None,
                        version=1,
                    )
                )
                await connection.execute(
                    text("INSERT INTO data_revision (id, revision) VALUES (1, 0)")
                )
                with pytest.raises(ArchiveError, match="duplicate primary keys"):
                    await ArchiveService.restore_empty_target(
                        connection, manifest=manifest, payload=duplicate_primary_key
                    )
                assert await connection.scalar(text("SELECT count(*) FROM accounts")) == 0
                with pytest.raises(ArchiveError, match="orphan foreign key"):
                    await ArchiveService.restore_empty_target(
                        connection, manifest=manifest, payload=orphan_posting
                    )
                assert await connection.scalar(text("SELECT count(*) FROM postings")) == 0

                await ArchiveService.restore_empty_target(
                    connection, manifest=manifest, payload=payload
                )
                assert await connection.scalar(text("SELECT count(*) FROM transactions")) == 1
                assert await connection.scalar(text("SELECT count(*) FROM postings")) == 1
                assert (
                    await connection.scalar(
                        text(
                            "SELECT count(*) FROM postings p "
                            "LEFT JOIN transactions t ON t.id = p.transaction_id "
                            "WHERE t.id IS NULL"
                        )
                    )
                    == 0
                )
                restored_posting_totals = (
                    await connection.execute(
                        text(
                            "SELECT coalesce(sum(amount_minor), 0), "
                            "coalesce(sum(abs(amount_minor)), 0) FROM postings"
                        )
                    )
                ).one()
                assert restored_posting_totals == expected_posting_totals
                assert (
                    await connection.scalar(balance_fingerprint_sql) == expected_balance_fingerprint
                )
                assert (
                    await connection.scalar(report_fingerprint_sql) == expected_report_fingerprint
                )
        finally:
            await engine.dispose()

    asyncio.run(restore())


@pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
def test_p22_archive_export_cli_is_stdin_only_and_never_overwrites(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    assert TEST_DATABASE_URL is not None
    password = uuid4().hex + uuid4().hex
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)

    def invoke(*args: str) -> None:
        monkeypatch.setattr(sys, "argv", ["archive_export.py", *args])
        monkeypatch.setattr(sys, "stdin", io.StringIO(password + "\n"))
        archive_export.main()

    raw_ai_input = f"P22 AI raw input {uuid4().hex}"

    async def seed_ai_proposal() -> None:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            from fiscal_api.db.session import create_session_factory

            async with create_session_factory(engine)() as session:
                session.add(
                    AIProposal(
                        source="text",
                        raw_input=raw_ai_input,
                        content_fingerprint=hashlib.sha256(raw_ai_input.encode()).hexdigest(),
                        create_idempotency_key=uuid4(),
                        create_request_hash=hashlib.sha256(
                            f"request:{raw_ai_input}".encode()
                        ).hexdigest(),
                        field_confidences={},
                        missing_fields=[],
                        reason_codes=[],
                        status="failed",
                        error_code="archive_test",
                    )
                )
                await session.commit()
        finally:
            await engine.dispose()

    asyncio.run(seed_ai_proposal())
    default_archive = tmp_path / "default.far"
    invoke(str(default_archive))
    default_manifest, default_payload = ArchiveService.open(
        default_archive.read_bytes(), password=password
    )
    assert default_manifest["includes_ai_raw"] is False
    default_proposal = next(
        row
        for row in default_payload["entities"]["ai_proposals"]
        if row["raw_input"] == "[AI raw input excluded from Fiscal Archive]"
    )
    assert default_proposal["raw_input"] != raw_ai_input

    raw_archive = tmp_path / "raw.far"
    invoke("--include-ai-raw", str(raw_archive))
    raw_manifest, raw_payload = ArchiveService.open(raw_archive.read_bytes(), password=password)
    assert raw_manifest["includes_ai_raw"] is True
    assert any(row["raw_input"] == raw_ai_input for row in raw_payload["entities"]["ai_proposals"])

    existing = tmp_path / "existing.far"
    existing.write_bytes(b"do-not-overwrite")
    with pytest.raises(SystemExit, match="File exists"):
        invoke(str(existing))
    assert existing.read_bytes() == b"do-not-overwrite"

    missing_parent = tmp_path / "missing" / "partial.far"
    with pytest.raises(SystemExit, match="No such file"):
        invoke(str(missing_parent))
    assert not missing_parent.exists()
