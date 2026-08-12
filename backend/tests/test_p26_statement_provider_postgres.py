from __future__ import annotations

import asyncio
from os import environ
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import func, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.api.dependencies import get_statement_import_provider
from fiscal_api.api.p26_schemas import StatementProviderCandidate, StatementProviderResult
from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.errors import APIError
from fiscal_api.db.models.ledger import LedgerTransaction, Posting
from fiscal_api.db.models.statement_import import (
    StatementImportAttempt,
    StatementImportProviderAttemptSnapshot,
)
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.main import create_app
from fiscal_api.services.archive import ArchiveService
from fiscal_api.services.statement_import_provider import StatementImportProvider

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


class RecordingProvider:
    provider_id = "synthetic_statement"
    model_id = "synthetic-statement-v1"
    prompt_version = "statement-p26-v1"
    schema_version = "statement-provider-v1"

    def __init__(self, result: StatementProviderResult | Exception) -> None:
        self.result = result
        self.requests: list[dict[str, object]] = []

    async def parse(self, request: object) -> StatementProviderResult:
        payload = request.model_dump(mode="json")  # type: ignore[union-attr]
        self.requests.append(payload)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


async def _ready() -> None:
    return None


def _client(provider: StatementImportProvider) -> TestClient:
    assert TEST_DATABASE_URL is not None
    app = create_app(
        settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
        readiness_check=_ready,
    )
    app.dependency_overrides[get_statement_import_provider] = lambda: provider
    return TestClient(app)


def _document() -> dict[str, object]:
    return {
        "document_sha256": "c" * 64,
        "byte_size": 1234,
        "page_count": 2,
        "mime_type": "application/pdf",
        "display_name": "synthetic.pdf",
    }


def _alembic_config() -> Config:
    return Config(str(Path(__file__).parents[1] / "alembic.ini"))


def _evidence(attempt_id: str, version: int) -> dict[str, object]:
    return {
        "attempt_id": attempt_id,
        "expected_version": version,
        "pages": [
            {
                "page_number": 1,
                "source_kind": "text",
                "evidence_text_masked": ("2026-08-12 Synthetic market 18.50 [REDACTED]"),
                "bounding_boxes": [{"x": 0.1, "y": 0.1, "width": 0.3, "height": 0.1}],
            },
            {"page_number": 2, "source_kind": "unsupported", "bounding_boxes": []},
        ],
        "rows": [
            {
                "row_number": 1,
                "page_number": 1,
                "evidence_text_masked": ("2026-08-12 Synthetic market 18.50 [REDACTED]"),
                "bounding_box": {"x": 0.1, "y": 0.1, "width": 0.3, "height": 0.1},
            }
        ],
    }


def _authorization(evidence_sha256: str) -> dict[str, object]:
    return {
        "confirmed": True,
        "provider": "synthetic_statement",
        "provider_model": "synthetic-statement-v1",
        "prompt_version": "statement-p26-v1",
        "schema_version": "statement-provider-v1",
        "evidence_sha256": evidence_sha256,
        "page_numbers": [1, 2],
        "row_count": 1,
        "redaction_version": "statement-redaction-v1",
        "redaction_count": 1,
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


async def _provider_attempt_state() -> tuple[str | None, int]:
    assert TEST_DATABASE_URL is not None
    engine = create_engine(TEST_DATABASE_URL)
    try:
        async with create_session_factory(engine)() as session:
            error_code = await session.scalar(
                select(StatementImportAttempt.error_code)
                .where(StatementImportAttempt.kind == "provider_parse")
                .order_by(StatementImportAttempt.attempt_number.desc())
                .limit(1)
            )
            snapshots = await session.scalar(
                select(func.count()).select_from(StatementImportProviderAttemptSnapshot)
            )
            return error_code, int(snapshots or 0)
    finally:
        await engine.dispose()


def _prepared_batch(client: TestClient) -> tuple[dict[str, object], dict[str, object]]:
    auth = {"Authorization": "Bearer p26-token"}
    created = client.post("/api/v1/statement-imports", headers=auth, json=_document())
    assert created.status_code == 201, created.text
    batch = created.json()
    local = client.post(
        f"/api/v1/statement-imports/{batch['id']}/attempts",
        headers=auth,
        json={"expected_version": batch["version"]},
    )
    assert local.status_code == 200, local.text
    evidence = client.post(
        f"/api/v1/statement-imports/{batch['id']}/evidence",
        headers=auth,
        json=_evidence(local.json()["id"], int(local.headers["X-Fiscal-Statement-Import-Version"])),
    )
    assert evidence.status_code == 200, evidence.text
    return evidence.json(), auth


def test_p26_synthetic_outbound_snapshots_idempotency_and_archive(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    provider = RecordingProvider(
        StatementProviderResult(
            document={"status": "synthetic"},
            candidates=[
                StatementProviderCandidate(
                    source_row_numbers=[1],
                    transaction_date="2026-08-12",
                    raw_amount="18.50",
                    direction="outflow",
                    transaction_kind="expense",
                    summary_evidence="Synthetic market",
                )
            ],
        )
    )
    with _client(provider) as client:
        batch, auth = _prepared_batch(client)
        request = {
            "expected_version": batch["version"],
            "evidence_sha256": batch["evidence_sha256"],
            "authorization": _authorization(batch["evidence_sha256"]),
        }
        key = str(uuid4())
        accepted = client.post(
            f"/api/v1/statement-imports/{batch['id']}/provider-attempts",
            headers={**auth, "Idempotency-Key": key},
            json=request,
        )
        assert accepted.status_code == 201, accepted.text
        assert accepted.json()["provider_status"] == "succeeded"
        assert accepted.headers["X-Fiscal-Affected-Scopes"] == "statement_imports"
        outbound = provider.requests[0]
        assert set(outbound) == {"schema_version", "currency", "pages", "rows"}
        assert all(
            forbidden not in str(outbound).lower()
            for forbidden in ("pdf", "image", "hash", "display_name", "document")
        )
        assert "Synthetic market" in str(outbound)
        assert "[REDACTED]" in str(outbound)
        assert "1234567890123456" not in str(outbound)

        replay = client.post(
            f"/api/v1/statement-imports/{batch['id']}/provider-attempts",
            headers={**auth, "Idempotency-Key": key},
            json=request,
        )
        assert replay.status_code == 200 and replay.json()["replay"] is True
        assert len(provider.requests) == 1
        reused = client.post(
            f"/api/v1/statement-imports/{batch['id']}/provider-attempts",
            headers={**auth, "Idempotency-Key": key},
            json={**request, "expected_version": batch["version"] + 1},
        )
        assert reused.status_code == 409

    assert asyncio.run(_ledger_counts()) == (0, 0)

    async def archive_payload() -> tuple[dict[str, object], dict[str, object]]:
        assert TEST_DATABASE_URL is not None
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                password = "p26-" + uuid4().hex
                archive, _ = await ArchiveService(session).export(
                    password=password, include_ai_raw=False
                )
                return ArchiveService.open(archive, password=password)
        finally:
            await engine.dispose()

    manifest, payload = asyncio.run(archive_payload())
    entities = payload["entities"]
    assert len(entities["statement_import_provider_attempts"]) == 1  # type: ignore[index]
    assert len(entities["statement_import_provider_attempt_snapshots"]) == 3  # type: ignore[index]
    assert len(entities["statement_import_provider_snapshot_source_refs"]) == 1  # type: ignore[index]
    provider_snapshot_text = str(entities["statement_import_provider_attempt_snapshots"]).lower()  # type: ignore[index]
    assert "pdf" not in provider_snapshot_text and "image" not in provider_snapshot_text
    assert ArchiveService.dry_run_report(manifest, payload)["relationship_errors"] == 0

    database_name = f"fiscal_p26_restore_{uuid4().hex}"
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
                        await connection.scalar(
                            text("SELECT count(*) FROM statement_import_provider_attempts")
                        )
                        == 1
                    )
                    assert (
                        await connection.scalar(
                            text("SELECT count(*) FROM statement_import_provider_attempt_snapshots")
                        )
                        == 3
                    )
                    assert (
                        await connection.scalar(
                            text(
                                "SELECT count(*) FROM "
                                "statement_import_provider_snapshot_source_refs"
                            )
                        )
                        == 1
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


def test_p26_provider_failure_is_retryable_and_ledger_isolated() -> None:
    provider = RecordingProvider(
        APIError(status_code=429, code="untrusted_throttle", message="hidden upstream")
    )
    with _client(provider) as client:
        batch, auth = _prepared_batch(client)
        response = client.post(
            f"/api/v1/statement-imports/{batch['id']}/provider-attempts",
            headers={**auth, "Idempotency-Key": str(UUID(int=42))},
            json={
                "expected_version": batch["version"],
                "evidence_sha256": batch["evidence_sha256"],
                "authorization": _authorization(batch["evidence_sha256"]),
            },
        )
        assert response.status_code == 201, response.text
        assert response.json()["status"] == "failed"
        assert response.json()["provider_status"] == "failed"
        assert "hidden upstream" not in response.text
        assert asyncio.run(_provider_attempt_state()) == ("statement_provider_unavailable", 2)
        retry_provider = RecordingProvider(
            StatementProviderResult(document={"status": "synthetic"})
        )
        client.app.dependency_overrides[get_statement_import_provider] = lambda: retry_provider
        retry = client.post(
            f"/api/v1/statement-imports/{batch['id']}/provider-attempts",
            headers={**auth, "Idempotency-Key": str(UUID(int=43))},
            json={
                "expected_version": response.json()["version"],
                "evidence_sha256": batch["evidence_sha256"],
                "authorization": _authorization(batch["evidence_sha256"]),
            },
        )
        assert retry.status_code == 201, retry.text
        assert retry.json()["provider_status"] == "succeeded"
    assert asyncio.run(_ledger_counts()) == (0, 0)


def test_p26_invalid_provider_schema_creates_no_candidate_snapshot() -> None:
    provider = RecordingProvider(StatementProviderResult(document={"status": "synthetic"}))
    provider.result = {"schema_version": "untrusted", "document": {}, "candidates": []}  # type: ignore[assignment]
    with _client(provider) as client:
        batch, auth = _prepared_batch(client)
        response = client.post(
            f"/api/v1/statement-imports/{batch['id']}/provider-attempts",
            headers={**auth, "Idempotency-Key": str(UUID(int=44))},
            json={
                "expected_version": batch["version"],
                "evidence_sha256": batch["evidence_sha256"],
                "authorization": _authorization(batch["evidence_sha256"]),
            },
        )
        assert response.status_code == 201, response.text
        assert response.json()["status"] == "failed"
        assert response.json()["provider_status"] == "failed"
        assert asyncio.run(_provider_attempt_state()) == ("statement_provider_invalid_result", 2)
    assert asyncio.run(_ledger_counts()) == (0, 0)
