from __future__ import annotations

import asyncio
from os import environ
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import text

from fiscal_api.core.config import Settings
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.main import create_app
from fiscal_api.services.archive import ArchiveService
from test_v230_core_postgres import AUTH, borrow, payoff, request, setup, summary

URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(URL is None, reason="requires isolated PostgreSQL")


def test_native_0040_payoff_archive_restore_replays_without_preview(monkeypatch):
    async def ready():
        return None

    app = create_app(settings=Settings(environment="test", database_url=URL), readiness_check=ready)
    with TestClient(app) as api:
        cash, credit = setup(api)
        borrow(api, cash, credit)
        _, receipt, commit, key = payoff(api, credit, request(cash))
    password = uuid4().hex

    async def export():
        engine = create_engine(URL)
        try:
            async with create_session_factory(engine)() as session:
                archive, _ = await ArchiveService(session).export(
                    password=password, include_ai_raw=False
                )
                return ArchiveService.open(archive, password=password)
        finally:
            await engine.dispose()

    manifest, payload = asyncio.run(export())
    assert len(payload["entities"]["credit_payoff_operations"]) == 1
    assert len(payload["entities"]["credit_payoff_links"]) == 1
    assert "action_preview_sessions" not in payload["entities"]

    async def reset():
        engine = create_engine(URL)
        try:
            async with engine.begin() as connection:
                await connection.execute(text("DROP SCHEMA public CASCADE"))
                await connection.execute(text("CREATE SCHEMA public"))
        finally:
            await engine.dispose()

    asyncio.run(reset())
    monkeypatch.setenv("FISCAL_DATABASE_URL", URL)
    command.upgrade(Config(str(Path(__file__).parents[1] / "alembic.ini")), "head")

    async def restore():
        engine = create_engine(URL)
        try:
            async with engine.begin() as connection:
                await ArchiveService.restore_empty_target(
                    connection, manifest=manifest, payload=payload
                )
        finally:
            await engine.dispose()

    asyncio.run(restore())
    with TestClient(app) as api:
        result = api.post(
            f"/api/v1/credit-accounts/{credit['id']}/payoff",
            headers={**AUTH, "Idempotency-Key": str(key)},
            json=commit,
        )
        assert result.status_code == 200, result.text
        assert result.json() == receipt
        assert summary(api, credit)["current_debt_minor"] == 0
        reverse = api.post(
            f"/api/v1/credit-payoffs/{receipt['operation_id']}/reverse-preview", headers=AUTH
        )
        assert reverse.status_code == 200, reverse.text
