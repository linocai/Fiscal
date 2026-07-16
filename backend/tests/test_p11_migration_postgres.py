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


def _config() -> Config:
    result = Config(str(BACKEND_ROOT / "alembic.ini"))
    result.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return result


async def _insert_token() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "INSERT INTO device_tokens("
                "id,label,role,status,token_digest,fingerprint,pepper_version,version,"
                "activated_at,created_at,updated_at) VALUES ("
                "'00000000-0000-0000-0000-000000011000','operator','operator','active',"
                "decode(repeat('ab',32),'hex'),'abcdef123456',1,1,now(),now(),now())"
            )
        )
    await engine.dispose()


async def _clear_tokens() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(text("TRUNCATE device_tokens CASCADE"))
    await engine.dispose()


def test_p11_device_token_migration_and_guarded_downgrade(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    command.upgrade(_config(), "head")
    asyncio.run(_clear_tokens())
    asyncio.run(_insert_token())
    with pytest.raises(DBAPIError, match="P11 downgrade blocked"):
        command.downgrade(_config(), "20260716_0009")
    asyncio.run(_clear_tokens())
    command.downgrade(_config(), "20260716_0009")
    command.upgrade(_config(), "head")
    get_settings.cache_clear()
