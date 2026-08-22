import asyncio
from os import environ
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import get_settings

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
BACKEND_ROOT = Path(__file__).resolve().parents[1]


def config() -> Config:
    result = Config(str(BACKEND_ROOT / "alembic.ini"))
    result.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return result


async def seed_frozen_reimbursement_override() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(text("TRUNCATE cash_flow_system_overrides CASCADE"))
        await connection.execute(
            text(
                "INSERT INTO cash_flow_system_overrides("
                "id,system_kind,system_reference_id,title,direction,planned_amount_minor,"
                "expected_date,status,version,created_at,updated_at) VALUES ("
                "'00000000-0000-0000-0000-000000013401','reimbursement',"
                "'00000000-0000-0000-0000-000000013402','旧报销覆盖','inflow',12345,"
                "'2026-08-20','confirmed',2,now(),now())"
            )
        )
    await engine.dispose()


async def migrated_amount_and_nullable() -> tuple[int | None, str]:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.connect() as connection:
        amount = await connection.scalar(
            text(
                "SELECT planned_amount_minor FROM cash_flow_system_overrides "
                "WHERE system_kind='reimbursement'"
            )
        )
        nullable = await connection.scalar(
            text(
                "SELECT is_nullable FROM information_schema.columns "
                "WHERE table_name='cash_flow_system_overrides' "
                "AND column_name='planned_amount_minor'"
            )
        )
    await engine.dispose()
    return amount, str(nullable)


def test_d5_upgrade_clears_frozen_amount_and_makes_override_column_nullable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    command.upgrade(config(), "head")
    command.downgrade(config(), "20260814_0033")
    asyncio.run(seed_frozen_reimbursement_override())
    command.upgrade(config(), "head")
    assert asyncio.run(migrated_amount_and_nullable()) == (None, "YES")
    get_settings.cache_clear()
