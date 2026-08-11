import asyncio
from collections.abc import Iterator
from datetime import UTC, datetime
from os import environ
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from pydantic import SecretStr
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import Settings, get_settings
from fiscal_api.main import create_app


async def ready_database() -> None:
    return None


def _alembic_config() -> Config:
    return Config(str(Path(__file__).parents[1] / "alembic.ini"))


async def _truncate_disposable_postgres(database_url: str) -> None:
    engine = create_async_engine(database_url)
    try:
        async with engine.begin() as connection:
            tables = list(
                (
                    await connection.scalars(
                        text(
                            "SELECT format('%I.%I', schemaname, tablename) "
                            "FROM pg_tables WHERE schemaname = 'public' "
                            "AND tablename <> 'alembic_version' ORDER BY tablename"
                        )
                    )
                ).all()
            )
            if tables:
                await connection.execute(
                    text(f"TRUNCATE TABLE {', '.join(tables)} RESTART IDENTITY CASCADE")
                )
    finally:
        await engine.dispose()


@pytest.fixture(autouse=True)
def reset_disposable_postgres_before_each_test(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Run every PostgreSQL test against a head schema with no leaked data.

    Migration tests intentionally finish in older revisions or after protected
    downgrade failures. Re-upgrading and truncating the explicitly supplied
    disposable database at the next test boundary prevents that state from
    corrupting unrelated API/service tests.
    """
    test_database_url = environ.get("FISCAL_TEST_DATABASE_URL")
    if test_database_url is None:
        yield
        return
    monkeypatch.setenv("FISCAL_DATABASE_URL", test_database_url)
    get_settings.cache_clear()
    command.upgrade(_alembic_config(), "head")
    asyncio.run(_truncate_disposable_postgres(test_database_url))
    # P5/P17 fixtures deliberately describe a July 2026 statement calendar.
    # Their eligibility rules are business-date dependent, so pin that single
    # clock in the disposable PostgreSQL suite instead of allowing the wall
    # clock to silently turn a still-open fixture cycle into historical data.
    monkeypatch.setattr(
        "fiscal_api.services.installments.utc_now",
        lambda: datetime(2026, 7, 15, 15, tzinfo=UTC),
    )
    monkeypatch.setattr(
        "fiscal_api.services.reporting.utc_now",
        lambda: datetime(2026, 7, 15, 15, tzinfo=UTC),
    )
    yield


@pytest.fixture
def settings() -> Settings:
    return Settings(
        environment="test",
        database_url="postgresql+asyncpg://unused:unused@localhost/unused",
        device_token=SecretStr("test-device-token"),
    )


@pytest.fixture
def client(settings: Settings) -> Iterator[TestClient]:
    app = create_app(settings=settings, readiness_check=ready_database)
    with TestClient(app) as test_client:
        yield test_client
