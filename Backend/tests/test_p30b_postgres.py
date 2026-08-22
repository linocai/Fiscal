from collections.abc import AsyncIterator
from datetime import UTC, datetime
from os import environ

import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.db.models import MigrationRun, MigrationRunMode, MigrationRunStatus
from fiscal_api.services.migrations import MigrationRunService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(
    TEST_DATABASE_URL is None,
    reason="requires a migrated disposable PostgreSQL database",
)


@pytest_asyncio.fixture
async def session() -> AsyncIterator[AsyncSession]:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


async def test_migration_run_deep_link_read_is_privacy_safe(session: AsyncSession) -> None:
    run = MigrationRun(
        mode=MigrationRunMode.SHADOW.value,
        status=MigrationRunStatus.FAILED.value,
        source_system="p30b-test",
        source_database_fingerprint="0" * 64,
        source_manifest_hash="1" * 64,
        source_manifest={"private": "not exposed"},
        selection_scope={"private": "not exposed"},
        code_revision="p30b-test",
        started_at=datetime(2026, 8, 13, tzinfo=UTC),
        completed_at=datetime(2026, 8, 13, 1, tzinfo=UTC),
    )
    session.add(run)
    await session.commit()

    response = await MigrationRunService(session).get(run.id)

    assert response.id == run.id
    assert response.deep_link == f"fiscal://settings/migrations/{run.id}"
    assert "source_manifest" not in response.model_dump()
    assert "selection_scope" not in response.model_dump()
