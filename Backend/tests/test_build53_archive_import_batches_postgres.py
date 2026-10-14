import asyncio
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.config import Settings
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.main import create_app
from fiscal_api.services.archive import (
    _AI_REDACTED_RAW_INPUT,
    CURRENT_DATABASE_REVISION,
    ArchiveService,
)

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_archive_exports_import_batches_with_source_text_redacted() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer build53-token"}
    idempotency_key = f"build53-archive-{uuid4().hex}"
    with TestClient(app) as client:
        created = client.post(
            "/api/v1/import-batches",
            headers=auth,
            json={
                "source": "text",
                "original_content_sha256": "a" * 64,
                "idempotency_key": idempotency_key,
                "candidates": [
                    {
                        "client_id": "row-1",
                        "kind": "expense",
                        "amount_minor": 3250,
                        "occurred_at": "2026-10-14T12:00:00+08:00",
                        "title": "B53 午饭",
                        "source_text": "10/14 午饭 32.5 私密原文",
                    }
                ],
            },
        )
        assert created.status_code == 201, created.text
        batch_id = created.json()["id"]

    async def export(include_ai_raw: bool) -> dict[str, object]:
        engine = create_engine(TEST_DATABASE_URL)
        try:
            async with create_session_factory(engine)() as session:
                password = uuid4().hex
                archive, _ = await ArchiveService(session).export(
                    password=password, include_ai_raw=include_ai_raw
                )
        finally:
            await engine.dispose()
        manifest, payload = ArchiveService.open(archive, password=password)
        assert manifest["database_revision"] == CURRENT_DATABASE_REVISION
        ArchiveService.adapt_to_current(manifest, payload)
        entities = payload["entities"]
        assert isinstance(entities, dict)
        return next(row for row in entities["import_batches"] if row["id"] == batch_id)

    redacted = asyncio.run(export(include_ai_raw=False))
    assert redacted["idempotency_key"] == idempotency_key
    assert redacted["candidates"][0]["title"] == "B53 午饭"
    assert redacted["candidates"][0]["source_text"] == _AI_REDACTED_RAW_INPUT
    raw = asyncio.run(export(include_ai_raw=True))
    assert raw["candidates"][0]["source_text"] == "10/14 午饭 32.5 私密原文"
