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


async def clear_p8_data() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(text("TRUNCATE ai_proposals CASCADE"))
        await connection.execute(text("DELETE FROM transactions WHERE source='ai_text'"))
    await engine.dispose()


async def validator_definitions() -> tuple[str, str, int]:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.connect() as connection:
        transaction_shape = await connection.scalar(
            text(
                "SELECT pg_get_functiondef('fiscal_validate_transaction_shape(uuid)'::regprocedure)"
            )
        )
        installment = await connection.scalar(
            text(
                "SELECT pg_get_functiondef('fiscal_validate_installment_plan(uuid)'::regprocedure)"
            )
        )
        settings_count = await connection.scalar(text("SELECT count(*) FROM ai_settings"))
    await engine.dispose()
    assert isinstance(transaction_shape, str)
    assert isinstance(installment, str)
    return transaction_shape, installment, int(settings_count or 0)


async def restored_validator_definitions() -> tuple[str, str]:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.connect() as connection:
        transaction_shape = await connection.scalar(
            text(
                "SELECT pg_get_functiondef('fiscal_validate_transaction_shape(uuid)'::regprocedure)"
            )
        )
        installment = await connection.scalar(
            text(
                "SELECT pg_get_functiondef('fiscal_validate_installment_plan(uuid)'::regprocedure)"
            )
        )
    await engine.dispose()
    assert isinstance(transaction_shape, str)
    assert isinstance(installment, str)
    return transaction_shape, installment


def test_p8_upgrade_downgrade_restores_complete_validators(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()

    # This upgrade exercises asyncpg: each CREATE FUNCTION must be a separate statement.
    command.upgrade(config(), "head")
    asyncio.run(clear_p8_data())
    upgraded_shape, upgraded_installment, settings_count = asyncio.run(validator_definitions())
    assert "ai_text" in upgraded_shape
    assert "ai_text" in upgraded_installment
    assert "ocr" in upgraded_shape
    assert "ocr" in upgraded_installment
    assert settings_count == 1

    command.downgrade(config(), "20260715_0006")
    restored_shape, restored_installment = asyncio.run(restored_validator_definitions())
    assert "ai_text" not in restored_shape
    assert "ai_text" not in restored_installment

    command.upgrade(config(), "head")
    roundtrip_shape, roundtrip_installment, settings_count = asyncio.run(validator_definitions())
    assert "ai_text" in roundtrip_shape
    assert "ai_text" in roundtrip_installment
    assert "ocr" in roundtrip_shape
    assert "ocr" in roundtrip_installment
    assert settings_count == 1
    get_settings.cache_clear()


async def insert_p9_proposal() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "INSERT INTO ai_proposals "
                "(id,source,raw_input,content_fingerprint,create_idempotency_key,"
                "create_request_hash,field_confidences,missing_fields,reason_codes,status,"
                "version,created_at,updated_at) VALUES "
                "('00000000-0000-0000-0000-000000009001','ocr','fixture',"
                ":fingerprint,'00000000-0000-0000-0000-000000009002',:request_hash,"
                "'{}'::jsonb,'[]'::jsonb,'[]'::jsonb,'failed',1,now(),now())"
            ),
            {"fingerprint": "f" * 64, "request_hash": "h" * 64},
        )
    await engine.dispose()


def test_p9_downgrade_blocks_non_text_proposals(monkeypatch: pytest.MonkeyPatch) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    command.upgrade(config(), "head")
    asyncio.run(clear_p8_data())
    asyncio.run(insert_p9_proposal())
    with pytest.raises(Exception, match="P9 downgrade blocked"):
        command.downgrade(config(), "20260716_0007")
    asyncio.run(clear_p8_data())
    get_settings.cache_clear()
