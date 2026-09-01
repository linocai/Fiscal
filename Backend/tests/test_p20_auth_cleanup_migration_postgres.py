import asyncio
from os import environ
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import create_async_engine

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
BACKEND_ROOT = Path(__file__).resolve().parents[1]


def _config() -> Config:
    result = Config(str(BACKEND_ROOT / "alembic.ini"))
    result.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return result


async def _insert_legacy_device_marker() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    try:
        async with engine.begin() as connection:
            await connection.execute(
                text(
                    "INSERT INTO device_tokens "
                    "(id,label,role,status,token_digest,fingerprint,pepper_version,version,"
                    "issued_by_id,replaces_id,pending_expires_at,expires_at,activated_at,"
                    "last_used_at,revoked_at,created_at,updated_at) VALUES "
                    "('00000000-0000-0000-0000-000000020001','legacy fixture','device',"
                    "'active',decode(repeat('ab', 32), 'hex'),'0123456789ab',1,1,NULL,NULL,"
                    "NULL,NULL,now(),NULL,NULL,now(),now())"
                )
            )
    finally:
        await engine.dispose()


async def _clear_legacy_device_marker() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    try:
        async with engine.begin() as connection:
            await connection.execute(text("DELETE FROM device_tokens"))
    finally:
        await engine.dispose()


async def _device_tokens_table() -> str | None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    try:
        async with engine.connect() as connection:
            result = await connection.scalar(text("SELECT to_regclass('public.device_tokens')"))
            return str(result) if result is not None else None
    finally:
        await engine.dispose()


def test_p20_auth_cleanup_requires_credential_and_blocks_downgrade() -> None:
    # The migration fixture deliberately starts this test at 0019, where the
    # old table still exists. A populated bridge without the singleton
    # passphrase credential must abort before any destructive DDL is attempted.
    asyncio.run(_insert_legacy_device_marker())
    with pytest.raises(
        DBAPIError, match="P20 authentication cleanup requires exactly one access credential"
    ):
        command.upgrade(_config(), "20260830_0037")
    assert asyncio.run(_device_tokens_table()) == "device_tokens"

    asyncio.run(_clear_legacy_device_marker())
    command.upgrade(_config(), "20260830_0037")
    assert asyncio.run(_device_tokens_table()) is None
    with pytest.raises(DBAPIError, match="P20 downgrade blocked"):
        command.downgrade(_config(), "20260811_0019")
