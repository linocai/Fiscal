import asyncio
from os import environ
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import get_settings

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
BACKEND_ROOT = Path(__file__).resolve().parents[1]


def config() -> Config:
    result = Config(str(BACKEND_ROOT / "alembic.ini"))
    result.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return result


async def clear_ledger() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE transaction_revisions, postings, transactions, "
                "categories, accounts CASCADE"
            )
        )
    await engine.dispose()


async def insert_uncategorized() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    try:
        async with engine.begin() as connection:
            await connection.execute(
                text(
                    "INSERT INTO accounts(id,name,kind,opening_balance_minor,usage_count,"
                    "sort_order,version,created_at,updated_at) VALUES "
                    "('00000000-0000-0000-0000-000000010001','P10 卡','debit',0,1,0,1,now(),now())"
                )
            )
            await connection.execute(
                text(
                    "INSERT INTO transactions(id,kind,occurred_at,title,source,idempotency_key,"
                    "request_hash,version,created_at,updated_at) VALUES "
                    "('00000000-0000-0000-0000-000000010002','expense',now(),'待归类','manual',"
                    "'00000000-0000-0000-0000-000000010003',repeat('a',64),1,now(),now())"
                )
            )
            await connection.execute(
                text(
                    "INSERT INTO postings(id,transaction_id,account_id,role,amount_minor,position) "
                    "VALUES ('00000000-0000-0000-0000-000000010004',"
                    "'00000000-0000-0000-0000-000000010002',"
                    "'00000000-0000-0000-0000-000000010001','account',-100,0)"
                )
            )
    finally:
        await engine.dispose()


def test_p10_uncategorized_upgrade_and_guarded_downgrade(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    command.upgrade(config(), "head")
    asyncio.run(clear_ledger())
    asyncio.run(insert_uncategorized())
    with pytest.raises(DBAPIError, match="P10 downgrade blocked"):
        command.downgrade(config(), "20260716_0008")

    asyncio.run(clear_ledger())
    command.downgrade(config(), "20260716_0008")
    with pytest.raises(DBAPIError, match="invalid income/expense posting shape"):
        asyncio.run(insert_uncategorized())
    command.upgrade(config(), "head")
    get_settings.cache_clear()
