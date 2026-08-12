from __future__ import annotations

import asyncio
from os import environ
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import func, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import Settings, get_settings
from fiscal_api.db.models.ledger import LedgerTransaction, Posting
from fiscal_api.db.models.statement_import import StatementImportOperation
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.main import create_app
from fiscal_api.services.archive import ArchiveService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


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


def _alembic_config() -> Config:
    return Config(str(Path(__file__).parents[1] / "alembic.ini"))


def _document_payload(*, digest: str | None = None) -> dict[str, object]:
    return {
        "document_sha256": digest or ("a" * 64),
        "byte_size": 1234,
        "page_count": 2,
        "mime_type": "application/pdf",
        "display_name": "sensitive-holder-1234567890123456.pdf",
    }


async def _ledger_counts() -> tuple[int, int]:
    assert TEST_DATABASE_URL is not None
    engine = create_engine(TEST_DATABASE_URL)
    try:
        async with engine.connect() as connection:
            return (
                int(
                    await connection.scalar(select(func.count()).select_from(LedgerTransaction))
                    or 0
                ),
                int(await connection.scalar(select(func.count()).select_from(Posting)) or 0),
            )
    finally:
        await engine.dispose()


def test_p24_register_duplicate_failure_retry_abandon_is_ledger_isolated(
    capsys: pytest.CaptureFixture[str],
) -> None:
    auth = {"Authorization": "Bearer p24-token"}
    assert asyncio.run(_ledger_counts()) == (0, 0)
    with _client() as client:
        baseline = client.get("/api/v1/data-revision", headers=auth).json()["revision"]
        created = client.post("/api/v1/statement-imports", headers=auth, json=_document_payload())
        assert created.status_code == 201, created.text
        assert created.json()["duplicate"] is False
        assert created.headers["X-Fiscal-Data-Revision"] == str(baseline + 1)
        assert created.headers["X-Fiscal-Affected-Scopes"] == "statement_imports"
        batch = created.json()

        duplicate = client.post("/api/v1/statement-imports", headers=auth, json=_document_payload())
        assert duplicate.status_code == 200, duplicate.text
        assert duplicate.json()["id"] == batch["id"]
        assert duplicate.json()["duplicate"] is True
        assert "X-Fiscal-Data-Revision" not in duplicate.headers

        started = client.post(
            f"/api/v1/statement-imports/{batch['id']}/attempts",
            headers=auth,
            json={"expected_version": batch["version"]},
        )
        assert started.status_code == 200, started.text
        assert started.json()["attempt_number"] == 1
        assert started.json()["kind"] == "local_extraction"
        active_version = int(started.headers["X-Fiscal-Statement-Import-Version"])

        failed = client.post(
            f"/api/v1/statement-imports/{batch['id']}/fail",
            headers=auth,
            json={"expected_version": active_version, "error_code": "document_invalid"},
        )
        assert failed.status_code == 200, failed.text
        assert failed.json()["status"] == "failed"

        retry = client.post(
            f"/api/v1/statement-imports/{batch['id']}/attempts",
            headers=auth,
            json={"expected_version": failed.json()["version"]},
        )
        assert retry.status_code == 200, retry.text
        assert retry.json()["attempt_number"] == 2
        retry_version = int(retry.headers["X-Fiscal-Statement-Import-Version"])

        abandoned = client.post(
            f"/api/v1/statement-imports/{batch['id']}/abandon",
            headers=auth,
            json={"expected_version": retry_version},
        )
        assert abandoned.status_code == 200, abandoned.text
        assert abandoned.json()["status"] == "abandoned"
        assert abandoned.json()["abandoned_at"] is not None

    assert asyncio.run(_ledger_counts()) == (0, 0)
    captured = capsys.readouterr().out
    assert "sensitive-holder-1234567890123456.pdf" not in captured
    assert "1234567890123456" not in captured


def test_p24_archive_round_trip_preserves_import_relationships_without_pdf_bytes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    auth = {"Authorization": "Bearer p24-token"}
    with _client() as client:
        created = client.post("/api/v1/statement-imports", headers=auth, json=_document_payload())
        assert created.status_code == 201, created.text
        batch = created.json()
        started = client.post(
            f"/api/v1/statement-imports/{batch['id']}/attempts",
            headers=auth,
            json={"expected_version": batch["version"]},
        )
        assert started.status_code == 200, started.text
        failed = client.post(
            f"/api/v1/statement-imports/{batch['id']}/fail",
            headers=auth,
            json={
                "expected_version": int(started.headers["X-Fiscal-Statement-Import-Version"]),
                "error_code": "document_invalid",
            },
        )
        assert failed.status_code == 200, failed.text

    async def export_open() -> tuple[dict[str, object], dict[str, object]]:
        password = "p24-test-password-" + uuid4().hex
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                archive, _ = await ArchiveService(session).export(
                    password=password, include_ai_raw=False
                )
                return ArchiveService.open(archive, password=password)
        finally:
            await engine.dispose()

    manifest, payload = asyncio.run(export_open())
    assert manifest["entity_counts"]["statement_imports"] == 1
    assert manifest["entity_counts"]["statement_import_attempts"] == 1
    assert manifest["entity_counts"]["statement_import_operations"] == 3
    import_fields = set(payload["entities"]["statement_imports"][0])
    assert not {"pdf_bytes", "raw_pdf", "document_bytes"} & import_fields
    assert ArchiveService.dry_run_report(manifest, payload)["relationship_errors"] == 0

    async def assert_operation_log() -> None:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                operations = list(
                    (
                        await session.scalars(
                            select(StatementImportOperation).order_by(
                                StatementImportOperation.occurred_at
                            )
                        )
                    ).all()
                )
                assert len(operations) == 3
                assert all("sensitive-holder" not in str(item.details) for item in operations)
                assert all("1234567890123456" not in str(item.details) for item in operations)
        finally:
            await engine.dispose()

    asyncio.run(assert_operation_log())

    database_name = f"fiscal_p24_restore_{uuid4().hex}"
    postgres_url = (
        make_url(TEST_DATABASE_URL).set(database="postgres").render_as_string(hide_password=False)
    )
    fresh_url = (
        make_url(TEST_DATABASE_URL)
        .set(database=database_name)
        .render_as_string(hide_password=False)
    )

    async def create_database() -> None:
        engine = create_async_engine(postgres_url, isolation_level="AUTOCOMMIT")
        try:
            async with engine.connect() as connection:
                await connection.execute(text(f'CREATE DATABASE "{database_name}"'))
        finally:
            await engine.dispose()

    async def drop_database() -> None:
        engine = create_async_engine(postgres_url, isolation_level="AUTOCOMMIT")
        try:
            async with engine.connect() as connection:
                await connection.execute(text(f'DROP DATABASE IF EXISTS "{database_name}"'))
        finally:
            await engine.dispose()

    asyncio.run(create_database())
    try:
        monkeypatch.setenv("FISCAL_DATABASE_URL", fresh_url)
        get_settings.cache_clear()
        command.upgrade(_alembic_config(), "head")
        target_engine = create_engine(fresh_url)
        try:

            async def restore_and_assert() -> None:
                async with target_engine.begin() as connection:
                    await ArchiveService.restore_empty_target(
                        connection, manifest=manifest, payload=payload
                    )
                    assert (
                        await connection.scalar(text("SELECT count(*) FROM statement_imports")) == 1
                    )
                    assert (
                        await connection.scalar(
                            text("SELECT count(*) FROM statement_import_attempts")
                        )
                        == 1
                    )
                    assert (
                        await connection.scalar(
                            text("SELECT count(*) FROM statement_import_operations")
                        )
                        == 3
                    )
                    assert await connection.scalar(text("SELECT count(*) FROM transactions")) == 0
                    assert await connection.scalar(text("SELECT count(*) FROM postings")) == 0

            asyncio.run(restore_and_assert())
        finally:
            asyncio.run(target_engine.dispose())
    finally:
        asyncio.run(drop_database())
        monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
        get_settings.cache_clear()


def test_p24_fresh_upgrade_downgrade_reupgrade(monkeypatch: pytest.MonkeyPatch) -> None:
    assert TEST_DATABASE_URL is not None
    database_name = f"fiscal_p24_migration_{uuid4().hex}"
    postgres_url = (
        make_url(TEST_DATABASE_URL).set(database="postgres").render_as_string(hide_password=False)
    )
    fresh_url = (
        make_url(TEST_DATABASE_URL)
        .set(database=database_name)
        .render_as_string(hide_password=False)
    )

    async def create_database() -> None:
        engine = create_async_engine(postgres_url, isolation_level="AUTOCOMMIT")
        try:
            async with engine.connect() as connection:
                await connection.execute(text(f'CREATE DATABASE "{database_name}"'))
        finally:
            await engine.dispose()

    async def drop_database() -> None:
        engine = create_async_engine(postgres_url, isolation_level="AUTOCOMMIT")
        try:
            async with engine.connect() as connection:
                await connection.execute(text(f'DROP DATABASE IF EXISTS "{database_name}"'))
        finally:
            await engine.dispose()

    asyncio.run(create_database())
    try:
        monkeypatch.setenv("FISCAL_DATABASE_URL", fresh_url)
        get_settings.cache_clear()
        config = _alembic_config()
        command.upgrade(config, "head")
        command.downgrade(config, "20260811_0023")
        command.upgrade(config, "head")
        engine = create_engine(fresh_url)
        try:

            async def assert_schema() -> None:
                async with engine.connect() as connection:
                    assert (
                        await connection.scalar(
                            text("SELECT to_regclass('public.statement_imports')")
                        )
                        == "statement_imports"
                    )
                    assert await connection.scalar(text("SELECT count(*) FROM transactions")) == 0
                    assert await connection.scalar(text("SELECT count(*) FROM postings")) == 0

            asyncio.run(assert_schema())
        finally:
            asyncio.run(engine.dispose())
    finally:
        asyncio.run(drop_database())
        monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
        get_settings.cache_clear()
