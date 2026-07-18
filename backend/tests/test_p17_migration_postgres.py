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


async def seed_v14() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE cash_flow_system_overrides, transaction_revisions, postings, "
                "transactions, credit_cycles, categories, accounts CASCADE"
            )
        )
        await connection.execute(
            text(
                "INSERT INTO accounts(id,name,kind,opening_balance_minor,credit_limit_minor,"
                "statement_day,due_day,sort_order,usage_count,version,created_at,updated_at) "
                "VALUES ('00000000-0000-0000-0000-000000017001','花呗','credit',0,1000000,"
                "1,8,0,0,1,now(),now())"
            )
        )
        await connection.execute(
            text(
                "INSERT INTO cash_flow_system_overrides(id,system_kind,system_reference_id,"
                "title,direction,planned_amount_minor,expected_date,status,version,created_at,"
                "updated_at) VALUES "
                "('00000000-0000-0000-0000-000000017011','credit_cycle',"
                "'00000000-0000-0000-0000-000000017021','旧信用完成标记','outflow',10000,"
                "'2026-08-08','completed',2,now(),now()),"
                "('00000000-0000-0000-0000-000000017012','reimbursement',"
                "'00000000-0000-0000-0000-000000017022','报销覆盖','inflow',20000,"
                "'2026-08-09','confirmed',1,now(),now())"
            )
        )
    await engine.dispose()


async def upgraded_values() -> tuple[str, int, int]:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.connect() as connection:
        cycle_mode = await connection.scalar(
            text("SELECT cycle_mode FROM accounts WHERE name='花呗'")
        )
        credit_count = await connection.scalar(
            text("SELECT count(*) FROM cash_flow_system_overrides WHERE system_kind='credit_cycle'")
        )
        reimbursement_count = await connection.scalar(
            text(
                "SELECT count(*) FROM cash_flow_system_overrides WHERE system_kind='reimbursement'"
            )
        )
    await engine.dispose()
    return str(cycle_mode), int(credit_count or 0), int(reimbursement_count or 0)


def test_p17_upgrade_defaults_old_mode_and_only_clears_credit_overrides(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    command.upgrade(config(), "head")
    command.downgrade(config(), "20260717_0014")
    asyncio.run(seed_v14())
    command.upgrade(config(), "head")
    assert asyncio.run(upgraded_values()) == ("statement_day_cutoff", 0, 1)
    get_settings.cache_clear()
