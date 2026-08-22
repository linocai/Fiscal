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
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.api.dependencies import get_statement_import_provider
from fiscal_api.api.p26_schemas import StatementProviderCandidate, StatementProviderResult
from fiscal_api.core.config import Settings, get_settings
from fiscal_api.db.models.ledger import LedgerTransaction, Posting
from fiscal_api.db.models.statement_import import (
    StatementImportProviderAttempt,
    StatementImportProviderAttemptSnapshot,
    StatementImportRow,
)
from fiscal_api.db.models.statement_import_confirmation import (
    StatementImportConfirmationOperation,
    StatementImportTransactionProvenance,
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


def _alembic_config() -> Config:
    return Config(str(Path(__file__).parents[1] / "alembic.ini"))


def _seed(client: TestClient, *, row_count: int = 1) -> tuple[dict[str, object], dict[str, str]]:
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
                    "row_number": row_number,
                    "page_number": 1,
                    "evidence_text_masked": f"2026-08-12 Synthetic market {row_number} 18.50",
                    "bounding_box": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1},
                }
                for row_number in range(1, row_count + 1)
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
                "row_count": row_count,
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


async def _row_ids(batch_id: UUID) -> list[UUID]:
    assert TEST_DATABASE_URL is not None
    engine = create_engine(TEST_DATABASE_URL)
    try:
        async with create_session_factory(engine)() as session:
            return list(
                (
                    await session.scalars(
                        select(StatementImportRow.id)
                        .where(StatementImportRow.statement_import_id == batch_id)
                        .order_by(StatementImportRow.row_number)
                    )
                ).all()
            )
    finally:
        await engine.dispose()


def test_p27_validation_review_drafts_replay_and_zero_ledger(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
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

    async def archive_payload() -> tuple[dict[str, object], dict[str, object]]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                password = "p27-" + uuid4().hex
                archive, _ = await ArchiveService(session).export(
                    password=password, include_ai_raw=False
                )
                return ArchiveService.open(archive, password=password)
        finally:
            await engine.dispose()

    manifest, payload = asyncio.run(archive_payload())
    entities = payload["entities"]
    assert len(entities["statement_import_validation_runs"]) == 1  # type: ignore[index]
    assert len(entities["statement_import_validation_checks"]) == 5  # type: ignore[index]
    assert len(entities["statement_import_review_candidates"]) == 1  # type: ignore[index]
    assert len(entities["statement_import_draft_resolutions"]) == 1  # type: ignore[index]
    assert "pdf" not in str(entities["statement_import_validation_runs"]).lower()  # type: ignore[index]
    assert ArchiveService.dry_run_report(manifest, payload)["relationship_errors"] == 0

    database_name = f"fiscal_p27_restore_{uuid4().hex}"
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
                    for query, count in (
                        (text("SELECT count(*) FROM statement_import_validation_runs"), 1),
                        (text("SELECT count(*) FROM statement_import_validation_checks"), 5),
                        (text("SELECT count(*) FROM statement_import_review_candidates"), 1),
                        (text("SELECT count(*) FROM statement_import_draft_resolutions"), 1),
                    ):
                        assert await connection.scalar(query) == count
                    assert (
                        await connection.scalar(
                            text(
                                "SELECT count(*) FROM statement_import_validation_runs run "
                                "JOIN statement_import_provider_attempt_snapshots snapshot "
                                "ON snapshot.id = run.provider_snapshot_id "
                                "JOIN statement_import_provider_snapshot_source_refs source_ref "
                                "ON source_ref.provider_attempt_snapshot_id = snapshot.id"
                            )
                        )
                        == 1
                    )
                    assert (
                        await connection.scalar(
                            text(
                                "SELECT count(*) FROM statement_import_draft_resolutions draft "
                                "JOIN statement_import_validation_runs run "
                                "ON run.id = draft.validation_run_id "
                                "JOIN statement_import_rows row "
                                "ON row.id = draft.statement_import_row_id"
                            )
                        )
                        == 1
                    )
                    assert (
                        await connection.scalar(text("SELECT version FROM statement_imports"))
                        == entities["statement_imports"][0]["version"]
                    )  # type: ignore[index]
                    assert (
                        await connection.scalar(
                            text("SELECT version FROM statement_import_draft_resolutions")
                        )
                        == entities["statement_import_draft_resolutions"][0]["version"]
                    )  # type: ignore[index]
                    assert await connection.scalar(text("SELECT count(*) FROM transactions")) == 0
                    assert await connection.scalar(text("SELECT count(*) FROM postings")) == 0

            asyncio.run(restore_and_assert())
        finally:
            asyncio.run(target_engine.dispose())
    finally:
        asyncio.run(drop_database())
        monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
        get_settings.cache_clear()


def test_p27_confirm_create_new_uses_saved_final_draft(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    with _client() as client:
        batch, auth = _seed(client)
        account = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={"name": "P27 cash", "kind": "cash", "opening_balance_minor": 0},
        )
        assert account.status_code == 201
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
        ).json()
        final = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/final-create-draft",
            headers=auth,
            json={
                "expected_version": 0,
                "transaction": {
                    "kind": "expense",
                    "amount_minor": 1850,
                    "occurred_at": "2026-08-12T12:00:00+08:00",
                    "title": "Synthetic market",
                    "account_id": account.json()["id"],
                },
            },
        )
        assert final.status_code == 200, final.text
        key = str(uuid4())
        payload = {
            "expected_batch_version": resolution["batch_version"],
            "rows": [
                {
                    "row_id": row_id,
                    "expected_row_version": 1,
                    "expected_draft_version": 1,
                    "expected_final_create_draft_version": 1,
                }
            ],
        }
        confirmed = client.post(
            f"/api/v1/statement-imports/{batch['id']}/confirm",
            headers={**auth, "Idempotency-Key": key},
            json=payload,
        )
        assert confirmed.status_code == 200, confirmed.text
        assert confirmed.json()["confirmed_row_ids"] == [row_id]
        assert confirmed.json()["result_detail_status"] == "complete"
        assert confirmed.json()["created_count"] == 1
        assert confirmed.json()["matched_count"] == 0
        assert confirmed.json()["skipped_count"] == 0
        assert confirmed.json()["row_results"][0]["row_id"] == row_id
        assert confirmed.json()["row_results"][0]["resolution"] == "create_new"
        assert confirmed.json()["row_results"][0]["outcome"] == "applied"
        assert confirmed.json()["row_results"][0]["transaction_id"] is not None
        replay = client.post(
            f"/api/v1/statement-imports/{batch['id']}/confirm",
            headers={**auth, "Idempotency-Key": key},
            json=payload,
        )
        assert replay.status_code == 200 and replay.json()["replay"]
        conflict_response = client.post(
            f"/api/v1/statement-imports/{batch['id']}/confirm",
            headers={**auth, "Idempotency-Key": key},
            json={**payload, "expected_batch_version": payload["expected_batch_version"] + 1},
        )
        assert conflict_response.status_code == 409

    async def counts() -> tuple[int, int, int, int]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                counts = []
                for model in (
                    LedgerTransaction,
                    Posting,
                    StatementImportTransactionProvenance,
                    StatementImportConfirmationOperation,
                ):
                    counts.append(
                        int(await session.scalar(select(func.count()).select_from(model)) or 0)
                    )
                return tuple(counts)  # type: ignore[return-value]
        finally:
            await engine.dispose()

    assert asyncio.run(counts()) == (1, 1, 1, 1)

    async def rejected_system_only_kind() -> None:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with engine.begin() as connection:
                transaction_id = await connection.scalar(
                    select(LedgerTransaction.id).where(
                        LedgerTransaction.source == "statement_import"
                    )
                )
                assert transaction_id is not None
                await connection.execute(
                    text("UPDATE transactions SET kind = 'installment_fee' WHERE id = :id"),
                    {"id": transaction_id},
                )
        finally:
            await engine.dispose()

    # The adapter's only added sources cannot be repurposed for a system-only
    # kind; the retained deferred trigger rejects it at commit.
    with pytest.raises(DBAPIError, match="invalid installment posting shape"):
        asyncio.run(rejected_system_only_kind())

    async def archive_payload() -> tuple[dict[str, object], dict[str, object]]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                password = "p27-confirm-" + uuid4().hex
                archive, _ = await ArchiveService(session).export(
                    password=password, include_ai_raw=False
                )
                return ArchiveService.open(archive, password=password)
        finally:
            await engine.dispose()

    manifest, archive_payload_data = asyncio.run(archive_payload())
    entities = archive_payload_data["entities"]
    assert len(entities["statement_import_confirmation_operations"]) == 1  # type: ignore[index]
    assert len(entities["statement_import_transaction_provenance"]) == 1  # type: ignore[index]
    assert len(entities["statement_import_final_create_drafts"]) == 1  # type: ignore[index]

    database_name = f"fiscal_p27_confirm_restore_{uuid4().hex}"
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
                await connection.execute(
                    text(
                        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                        "WHERE datname = :database_name AND pid <> pg_backend_pid()"
                    ),
                    {"database_name": database_name},
                )
                await connection.execute(text(f'DROP DATABASE IF EXISTS "{database_name}"'))
        finally:
            await engine.dispose()

    asyncio.run(create_database())
    try:
        monkeypatch.setenv("FISCAL_DATABASE_URL", fresh_url)
        get_settings.cache_clear()
        command.upgrade(_alembic_config(), "head")

        async def restore_and_count() -> tuple[int, int, int, int]:
            target_engine = create_engine(fresh_url)
            try:
                async with target_engine.begin() as connection:
                    await ArchiveService.restore_empty_target(
                        connection, manifest=manifest, payload=archive_payload_data
                    )
                    values: list[int] = []
                    for query in (
                        text("SELECT count(*) FROM transactions"),
                        text("SELECT count(*) FROM postings"),
                        text("SELECT count(*) FROM statement_import_transaction_provenance"),
                        text("SELECT count(*) FROM statement_import_confirmation_operations"),
                    ):
                        values.append(int(await connection.scalar(query) or 0))
                    return tuple(values)  # type: ignore[return-value]
            finally:
                await target_engine.dispose()

        assert asyncio.run(restore_and_count()) == (1, 1, 1, 1)
        replay_app = create_app(
            settings=Settings(environment="test", database_url=fresh_url), readiness_check=_ready
        )
        replay_app.dependency_overrides[get_statement_import_provider] = Provider
        with TestClient(replay_app) as replay_client:
            replay = replay_client.post(
                f"/api/v1/statement-imports/{batch['id']}/confirm",
                headers={**auth, "Idempotency-Key": key},
                json=payload,
            )
            assert replay.status_code == 200, replay.text
            assert replay.json()["replay"] is True

        async def counts_after_replay() -> tuple[int, int]:
            target_engine = create_engine(fresh_url)
            try:
                async with target_engine.connect() as connection:
                    return (
                        int(await connection.scalar(text("SELECT count(*) FROM postings")) or 0),
                        int(
                            await connection.scalar(
                                text("SELECT count(*) FROM statement_import_transaction_provenance")
                            )
                            or 0
                        ),
                    )
            finally:
                await target_engine.dispose()

        assert asyncio.run(counts_after_replay()) == (1, 1)
    finally:
        asyncio.run(drop_database())
        monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
        get_settings.cache_clear()


def test_p27_confirm_ignore_is_partial_then_freezes_row() -> None:
    with _client() as client:
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
        draft = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/draft-resolution",
            headers=auth,
            json={
                "expected_batch_version": review["batch_version"],
                "expected_row_version": 1,
                "expected_resolution_version": 0,
                "resolution": "ignore_non_transaction",
            },
        ).json()
        response = client.post(
            f"/api/v1/statement-imports/{batch['id']}/confirm",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "expected_batch_version": draft["batch_version"],
                "rows": [
                    {"row_id": row_id, "expected_row_version": 1, "expected_draft_version": 1}
                ],
            },
        )
        assert response.status_code == 200, response.text
        assert response.json()["status"] == "confirmed"
        frozen = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/draft-resolution",
            headers=auth,
            json={
                "expected_batch_version": response.json()["batch_version"],
                "expected_row_version": 2,
                "expected_resolution_version": 1,
                "resolution": "ignore_intentional",
                "ignored_reason": "late",
            },
        )
        assert frozen.status_code == 409

    async def ledger() -> tuple[int, int]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                return (
                    int(
                        await session.scalar(select(func.count()).select_from(LedgerTransaction))
                        or 0
                    ),
                    int(await session.scalar(select(func.count()).select_from(Posting)) or 0),
                )
        finally:
            await engine.dispose()

    assert asyncio.run(ledger()) == (0, 0)


def test_p27_confirm_match_existing_only_writes_provenance() -> None:
    with _client() as client:
        batch, auth = _seed(client)
        account = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={"name": "P27 matching cash", "kind": "cash", "opening_balance_minor": 0},
        )
        assert account.status_code == 201, account.text
        existing = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "expense",
                "amount_minor": 1850,
                "occurred_at": "2026-08-12T12:00:00+08:00",
                "title": "Existing synthetic market",
                "account_id": account.json()["id"],
            },
        )
        assert existing.status_code == 201, existing.text
        existing_id = existing.json()["id"]
        existing_version = existing.json()["version"]
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
        draft = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/draft-resolution",
            headers=auth,
            json={
                "expected_batch_version": review["batch_version"],
                "expected_row_version": 1,
                "expected_resolution_version": 0,
                "resolution": "match_existing",
                "matched_transaction_id": existing_id,
            },
        )
        assert draft.status_code == 200, draft.text
        confirmed = client.post(
            f"/api/v1/statement-imports/{batch['id']}/confirm",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "expected_batch_version": draft.json()["batch_version"],
                "rows": [
                    {"row_id": row_id, "expected_row_version": 1, "expected_draft_version": 1}
                ],
            },
        )
        assert confirmed.status_code == 200, confirmed.text
        unchanged = client.get(f"/api/v1/transactions/{existing_id}", headers=auth)
        assert unchanged.status_code == 200
        assert unchanged.json()["version"] == existing_version

    async def counts() -> tuple[int, int, int]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                return (
                    int(
                        await session.scalar(select(func.count()).select_from(LedgerTransaction))
                        or 0
                    ),
                    int(await session.scalar(select(func.count()).select_from(Posting)) or 0),
                    int(
                        await session.scalar(
                            select(func.count()).select_from(StatementImportTransactionProvenance)
                        )
                        or 0
                    ),
                )
        finally:
            await engine.dispose()

    assert asyncio.run(counts()) == (1, 1, 1)


@pytest.mark.parametrize(
    ("resolution", "reason"),
    [("ignore_non_transaction", None), ("ignore_intentional", "synthetic intentional")],
)
def test_p27_confirm_each_ignore_kind_has_zero_postings(
    resolution: str, reason: str | None
) -> None:
    with _client() as client:
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
        body: dict[str, object] = {
            "expected_batch_version": review["batch_version"],
            "expected_row_version": 1,
            "expected_resolution_version": 0,
            "resolution": resolution,
        }
        if reason is not None:
            body["ignored_reason"] = reason
        draft = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/draft-resolution",
            headers=auth,
            json=body,
        )
        assert draft.status_code == 200, draft.text
        confirmed = client.post(
            f"/api/v1/statement-imports/{batch['id']}/confirm",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "expected_batch_version": draft.json()["batch_version"],
                "rows": [
                    {"row_id": row_id, "expected_row_version": 1, "expected_draft_version": 1}
                ],
            },
        )
        assert confirmed.status_code == 200, confirmed.text

    async def counts() -> tuple[int, int]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                return (
                    int(
                        await session.scalar(select(func.count()).select_from(LedgerTransaction))
                        or 0
                    ),
                    int(await session.scalar(select(func.count()).select_from(Posting)) or 0),
                )
        finally:
            await engine.dispose()

    assert asyncio.run(counts()) == (0, 0)


def test_p27_confirm_preflight_rolls_back_and_chunks_freeze_rows() -> None:
    with _client() as client:
        batch, auth = _seed(client, row_count=2)
        snapshot = asyncio.run(_snapshot(UUID(batch["id"])))
        review = client.post(
            f"/api/v1/statement-imports/{batch['id']}/validation-runs",
            headers=auth,
            json={
                "expected_batch_version": batch["version"],
                "provider_snapshot_id": str(snapshot),
            },
        )
        assert review.status_code == 201, review.text
        row_one, row_two = [str(value) for value in asyncio.run(_row_ids(UUID(batch["id"])))]
        version = review.json()["batch_version"]
        for row_id, resolution, reason in (
            (row_one, "ignore_non_transaction", None),
            (row_two, "ignore_intentional", "synthetic second row"),
        ):
            body: dict[str, object] = {
                "expected_batch_version": version,
                "expected_row_version": 1,
                "expected_resolution_version": 0,
                "resolution": resolution,
            }
            if reason is not None:
                body["ignored_reason"] = reason
            saved = client.put(
                f"/api/v1/statement-imports/{batch['id']}/rows/{row_id}/draft-resolution",
                headers=auth,
                json=body,
            )
            assert saved.status_code == 200, saved.text
            version = saved.json()["batch_version"]

        # A stale second member makes the whole selected set invalid: no first
        # row confirmation operation may escape this request.
        rejected = client.post(
            f"/api/v1/statement-imports/{batch['id']}/confirm",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "expected_batch_version": version,
                "rows": [
                    {"row_id": row_one, "expected_row_version": 1, "expected_draft_version": 1},
                    {"row_id": row_two, "expected_row_version": 1, "expected_draft_version": 2},
                ],
            },
        )
        assert rejected.status_code == 409, rejected.text
        first = client.post(
            f"/api/v1/statement-imports/{batch['id']}/confirm",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "expected_batch_version": version,
                "rows": [
                    {"row_id": row_one, "expected_row_version": 1, "expected_draft_version": 1}
                ],
            },
        )
        assert first.status_code == 200, first.text
        assert first.json()["status"] == "partially_confirmed"
        frozen = client.put(
            f"/api/v1/statement-imports/{batch['id']}/rows/{row_one}/draft-resolution",
            headers=auth,
            json={
                "expected_batch_version": first.json()["batch_version"],
                "expected_row_version": 2,
                "expected_resolution_version": 1,
                "resolution": "ignore_intentional",
                "ignored_reason": "too late",
            },
        )
        assert frozen.status_code == 409
        later_failure = client.post(
            f"/api/v1/statement-imports/{batch['id']}/confirm",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "expected_batch_version": first.json()["batch_version"],
                "rows": [
                    {"row_id": row_two, "expected_row_version": 1, "expected_draft_version": 2}
                ],
            },
        )
        assert later_failure.status_code == 409
        second = client.post(
            f"/api/v1/statement-imports/{batch['id']}/confirm",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "expected_batch_version": first.json()["batch_version"],
                "rows": [
                    {"row_id": row_two, "expected_row_version": 1, "expected_draft_version": 1}
                ],
            },
        )
        assert second.status_code == 200, second.text
        assert second.json()["status"] == "confirmed"

    async def counts() -> tuple[int, int, int, int]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                return (
                    int(
                        await session.scalar(select(func.count()).select_from(LedgerTransaction))
                        or 0
                    ),
                    int(await session.scalar(select(func.count()).select_from(Posting)) or 0),
                    int(
                        await session.scalar(
                            select(func.count()).select_from(StatementImportConfirmationOperation)
                        )
                        or 0
                    ),
                    int(
                        await session.scalar(
                            select(func.count())
                            .select_from(StatementImportRow)
                            .where(StatementImportRow.confirmed_at.is_not(None))
                        )
                        or 0
                    ),
                )
        finally:
            await engine.dispose()

    assert asyncio.run(counts()) == (0, 0, 2, 2)
