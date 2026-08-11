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
from fastapi.testclient import TestClient
from sqlalchemy import text

from fiscal_api.cli import archive_export
from fiscal_api.core.config import Settings
from fiscal_api.db.base import Base
from fiscal_api.db.models.ai import AIProposal
from fiscal_api.db.session import create_engine
from fiscal_api.main import create_app
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


def test_p22_archive_crypto_contract_runs_without_postgres() -> None:
    entities = {
        table.name: []
        for table in Base.metadata.sorted_tables
        if table.name not in {"access_credential", "access_keys", "data_revision"}
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
