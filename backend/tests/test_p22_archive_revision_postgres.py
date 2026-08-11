import asyncio
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

from fiscal_api.core.config import Settings
from fiscal_api.db.base import Base
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
                await connection.execute(text(f"TRUNCATE TABLE {', '.join(tables)} CASCADE"))
                assert await connection.scalar(text("SELECT count(*) FROM accounts")) == 0
                await ArchiveService.restore_empty_target(
                    connection, manifest=manifest, payload=payload
                )
                assert await connection.scalar(text("SELECT count(*) FROM transactions")) == 1
                assert await connection.scalar(text("SELECT count(*) FROM postings")) == 1
        finally:
            await engine.dispose()

    asyncio.run(restore())
