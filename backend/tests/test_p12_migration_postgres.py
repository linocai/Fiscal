import asyncio
from os import environ
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError, IntegrityError
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import get_settings

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
BACKEND_ROOT = Path(__file__).resolve().parents[1]


def _config() -> Config:
    result = Config(str(BACKEND_ROOT / "alembic.ini"))
    result.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return result


async def _clear_p12_rows() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE migration_object_links, migration_runs, transaction_revisions, "
                "postings, transactions, categories, accounts CASCADE"
            )
        )
    await engine.dispose()


async def _insert_legacy_transaction_and_provenance() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "INSERT INTO accounts(id,name,kind,opening_balance_minor,usage_count,sort_order,"
                "version,created_at,updated_at) VALUES "
                "('00000000-0000-0000-0000-000000012001','P12 卡','debit',0,1,0,1,now(),now())"
            )
        )
        await connection.execute(
            text(
                "INSERT INTO transactions(id,kind,occurred_at,title,source,idempotency_key,"
                "request_hash,version,created_at,updated_at) VALUES "
                "('00000000-0000-0000-0000-000000012002','expense',now(),'旧账导入',"
                "'legacy_import','00000000-0000-0000-0000-000000012003',repeat('a',64),"
                "1,now(),now())"
            )
        )
        await connection.execute(
            text(
                "INSERT INTO postings(id,transaction_id,account_id,role,amount_minor,position) "
                "VALUES ('00000000-0000-0000-0000-000000012004',"
                "'00000000-0000-0000-0000-000000012002',"
                "'00000000-0000-0000-0000-000000012001','account',-100,0)"
            )
        )
        await connection.execute(
            text(
                "INSERT INTO migration_runs(id,mode,status,source_system,"
                "source_database_fingerprint,source_manifest_hash,source_manifest,"
                "selection_scope,code_revision,started_at,completed_at,created_at) VALUES "
                "('00000000-0000-0000-0000-000000012005','shadow','succeeded','linofinance',"
                "repeat('b',64),repeat('c',64),'{}'::jsonb,'{}'::jsonb,'abc123',"
                "now(),now(),now())"
            )
        )
        await connection.execute(
            text(
                "INSERT INTO migration_object_links(id,migration_run_id,"
                "source_database_fingerprint,source_object_type,source_object_id,"
                "source_content_hash,target_object_type,target_object_id,created_at) VALUES "
                "('00000000-0000-0000-0000-000000012006',"
                "'00000000-0000-0000-0000-000000012005',repeat('b',64),"
                "'financial_entry','legacy-42',repeat('d',64),'transaction',"
                "'00000000-0000-0000-0000-000000012002',now())"
            )
        )
    await engine.dispose()


async def _assert_provenance_and_duplicate_guard() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.connect() as connection:
        source = await connection.scalar(
            text("SELECT source FROM transactions WHERE id='00000000-0000-0000-0000-000000012002'")
        )
        source_id = await connection.scalar(
            text(
                "SELECT source_object_id FROM migration_object_links "
                "WHERE target_object_id='00000000-0000-0000-0000-000000012002'"
            )
        )
        assert source == "legacy_import"
        assert source_id == "legacy-42"

    with pytest.raises(IntegrityError, match="uq_migration_object_links_source_identity"):
        async with engine.begin() as connection:
            await connection.execute(
                text(
                    "INSERT INTO migration_object_links(id,migration_run_id,"
                    "source_database_fingerprint,source_object_type,source_object_id,"
                    "source_content_hash,target_object_type,target_object_id,created_at) VALUES "
                    "('00000000-0000-0000-0000-000000012007',"
                    "'00000000-0000-0000-0000-000000012005',repeat('b',64),"
                    "'financial_entry','legacy-42',repeat('e',64),'transaction',"
                    "'00000000-0000-0000-0000-000000012099',now())"
                )
            )
    await engine.dispose()


def test_p12_provenance_migration_legacy_source_and_guarded_downgrade(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    command.upgrade(_config(), "head")
    asyncio.run(_clear_p12_rows())
    asyncio.run(_insert_legacy_transaction_and_provenance())
    asyncio.run(_assert_provenance_and_duplicate_guard())

    with pytest.raises(DBAPIError, match="P12 downgrade blocked"):
        command.downgrade(_config(), "20260716_0010")

    asyncio.run(_clear_p12_rows())
    command.downgrade(_config(), "20260716_0010")
    command.upgrade(_config(), "head")
    get_settings.cache_clear()
