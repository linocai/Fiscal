from __future__ import annotations

import asyncio
from os import environ
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from fiscal_api.api.dependencies import get_statement_import_provider
from fiscal_api.api.p26_schemas import StatementProviderCandidate, StatementProviderResult
from fiscal_api.core.config import Settings
from fiscal_api.db.models.ledger import LedgerTransaction, Posting
from fiscal_api.db.models.statement_import import (
    StatementImportProviderAttempt,
    StatementImportProviderAttemptSnapshot,
)
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.main import create_app
from fiscal_api.services.archive import ArchiveService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


class Provider:
    provider_id = "synthetic_statement"
    model_id = "synthetic-statement-v1"
    prompt_version = "statement-p26-v1"
    schema_version = "statement-provider-v1"

    async def parse(self, _: object) -> StatementProviderResult:
        return StatementProviderResult(
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


async def _ready() -> None:
    pass


def _client() -> TestClient:
    assert TEST_DATABASE_URL is not None
    app = create_app(
        settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
        readiness_check=_ready,
    )
    app.dependency_overrides[get_statement_import_provider] = Provider
    return TestClient(app)


def _seed(client: TestClient) -> tuple[dict[str, object], dict[str, str]]:
    auth = {"Authorization": "Bearer p27-token"}
    created = client.post(
        "/api/v1/statement-imports",
        headers=auth,
        json={
            "document_sha256": uuid4().hex * 2,
            "byte_size": 100,
            "page_count": 1,
            "mime_type": "application/pdf",
            "display_name": "synthetic.pdf",
        },
    )
    batch = created.json()
    local = client.post(
        f"/api/v1/statement-imports/{batch['id']}/attempts",
        headers=auth,
        json={"expected_version": batch["version"]},
    )
    evidence = client.post(
        f"/api/v1/statement-imports/{batch['id']}/evidence",
        headers=auth,
        json={
            "attempt_id": local.json()["id"],
            "expected_version": int(local.headers["X-Fiscal-Statement-Import-Version"]),
            "pages": [
                {
                    "page_number": 1,
                    "source_kind": "text",
                    "evidence_text_masked": "2026-08-12 Synthetic market 18.50",
                    "bounding_boxes": [],
                }
            ],
            "rows": [
                {
                    "row_number": 1,
                    "page_number": 1,
                    "evidence_text_masked": "2026-08-12 Synthetic market 18.50",
                    "bounding_box": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1},
                }
            ],
        },
    )
    provider = client.post(
        f"/api/v1/statement-imports/{batch['id']}/provider-attempts",
        headers={**auth, "Idempotency-Key": str(uuid4())},
        json={
            "expected_version": evidence.json()["version"],
            "evidence_sha256": evidence.json()["evidence_sha256"],
            "authorization": {
                "confirmed": True,
                "provider": "synthetic_statement",
                "provider_model": "synthetic-statement-v1",
                "prompt_version": "statement-p26-v1",
                "schema_version": "statement-provider-v1",
                "evidence_sha256": evidence.json()["evidence_sha256"],
                "page_numbers": [1],
                "row_count": 1,
                "redaction_version": "statement-redaction-v1",
                "redaction_count": 0,
            },
        },
    )
    assert provider.status_code == 201, provider.text
    return provider.json(), auth


async def _snapshot(batch_id: UUID) -> UUID:
    assert TEST_DATABASE_URL is not None
    engine = create_engine(TEST_DATABASE_URL)
    try:
        async with create_session_factory(engine)() as session:
            snapshot = await session.scalar(
                select(StatementImportProviderAttemptSnapshot.id)
                .join_from(
                    StatementImportProviderAttemptSnapshot,
                    StatementImportProviderAttempt,
                )
                .where(
                    StatementImportProviderAttempt.statement_import_id == batch_id,
                    StatementImportProviderAttemptSnapshot.snapshot_kind == "validated_result",
                )
            )
            assert snapshot is not None
            return snapshot
    finally:
        await engine.dispose()


def test_p27_validation_review_drafts_replay_and_zero_ledger() -> None:
    with _client() as client:
        batch, auth = _seed(client)
        snapshot = asyncio.run(_snapshot(UUID(batch["id"])))
        run = client.post(
            f"/api/v1/statement-imports/{batch['id']}/validation-runs",
            headers=auth,
            json={
                "expected_batch_version": batch["version"],
                "provider_snapshot_id": str(snapshot),
            },
        )
        assert run.status_code == 201, run.text
        assert run.json()["status"] == "review_required"
        assert {item["status"] for item in run.json()["checks"]} >= {"passed", "unavailable"}
        replay = client.post(
            f"/api/v1/statement-imports/{batch['id']}/validation-runs",
            headers=auth,
            json={
                "expected_batch_version": run.json()["batch_version"],
                "provider_snapshot_id": str(snapshot),
            },
        )
        assert replay.status_code == 200 and replay.json()["replay"]
        row_id = run.json()["candidates"][0]["statement_import_row_id"]
        draft = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/draft-resolution",
            headers=auth,
            json={
                "expected_batch_version": run.json()["batch_version"],
                "expected_row_version": 1,
                "expected_resolution_version": 0,
                "resolution": "create_new",
            },
        )
        assert draft.status_code == 200, draft.text
        assert draft.json()["status"] == "review_required"
        repeated = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/draft-resolution",
            headers=auth,
            json={
                "expected_batch_version": draft.json()["batch_version"],
                "expected_row_version": 1,
                "expected_resolution_version": 1,
                "resolution": "create_new",
            },
        )
        assert repeated.status_code == 200 and repeated.json()["replay"]
        version = repeated.json()["batch_version"]
        for index, resolution in enumerate(
            ["ignore_non_transaction", "ignore_intentional", "unresolved", "create_new"]
        ):
            body: dict[str, object] = {
                "expected_batch_version": version,
                "expected_row_version": 1,
                "expected_resolution_version": index + 1,
                "resolution": resolution,
            }
            if resolution == "ignore_intentional":
                body["ignored_reason"] = "synthetic non-ledger item"
            changed = client.put(
                f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/draft-resolution",
                headers=auth,
                json=body,
            )
            assert changed.status_code == 200, changed.text
            version = changed.json()["batch_version"]
        stale = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/draft-resolution",
            headers=auth,
            json={
                "expected_batch_version": version - 1,
                "expected_row_version": 1,
                "expected_resolution_version": 5,
                "resolution": "create_new",
            },
        )
        assert stale.status_code == 409

    async def counts() -> tuple[int, int]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                return int(
                    await session.scalar(select(func.count()).select_from(LedgerTransaction)) or 0
                ), int(await session.scalar(select(func.count()).select_from(Posting)) or 0)
        finally:
            await engine.dispose()

    assert asyncio.run(counts()) == (0, 0)

    async def archive_counts() -> dict[str, object]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                password = "p27-" + uuid4().hex
                archive, _ = await ArchiveService(session).export(
                    password=password, include_ai_raw=False
                )
                return ArchiveService.open(archive, password=password)[1]
        finally:
            await engine.dispose()

    payload = asyncio.run(archive_counts())
    entities = payload["entities"]
    assert len(entities["statement_import_validation_runs"]) == 1  # type: ignore[index]
    assert len(entities["statement_import_validation_checks"]) == 5  # type: ignore[index]
    assert len(entities["statement_import_review_candidates"]) == 1  # type: ignore[index]
    assert len(entities["statement_import_draft_resolutions"]) == 1  # type: ignore[index]
    assert "pdf" not in str(entities["statement_import_validation_runs"]).lower()  # type: ignore[index]
