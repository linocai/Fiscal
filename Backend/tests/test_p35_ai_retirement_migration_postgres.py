import asyncio
import hashlib
import json
from os import environ
from pathlib import Path
from typing import cast
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import get_settings
from fiscal_api.db.models.ai import AISettings
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.services.archive import ArchiveService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
BACKEND_ROOT = Path(__file__).resolve().parents[1]


def config() -> Config:
    result = Config(str(BACKEND_ROOT / "alembic.ini"))
    result.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return result


async def seed_legacy_true_rows() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(text("UPDATE ai_settings SET auto_execute_enabled = true"))
        await connection.execute(text("DELETE FROM ai_execution_policies"))
        await connection.execute(
            text(
                "INSERT INTO ai_execution_policies("
                "id,version,effective_at,source,transaction_kind,auto_execute_enabled,"
                "auto_execute_limit_minor,minimum_confidence_bps,minimum_sample_size,"
                "change_reason,changed_automatically,created_at) VALUES("
                "'00000000-0000-0000-0000-000000035001',1,now(),NULL,NULL,true,"
                "100000,9000,30,'legacy enabled row',false,now())"
            )
        )
    await engine.dispose()


async def retired_rows_and_guards() -> tuple[bool, list[bool], int]:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.connect() as connection:
        setting = bool(
            await connection.scalar(text("SELECT auto_execute_enabled FROM ai_settings"))
        )
        policies = [
            bool(value)
            for value in (
                await connection.scalars(
                    text("SELECT auto_execute_enabled FROM ai_execution_policies")
                )
            ).all()
        ]
        guards = int(
            await connection.scalar(
                text(
                    "SELECT count(*) FROM pg_constraint WHERE conname IN ("
                    "'ck_ai_settings_auto_execute_retired',"
                    "'ck_ai_execution_policies_auto_execute_retired')"
                )
            )
            or 0
        )
    await engine.dispose()
    return setting, policies, guards


async def direct_true_is_rejected() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    with pytest.raises(IntegrityError):
        async with engine.begin() as connection:
            await connection.execute(text("UPDATE ai_settings SET auto_execute_enabled = true"))
    await engine.dispose()


def test_d3_migration_cleans_legacy_true_adds_guards_and_downgrade_stays_false(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    command.upgrade(config(), "20260830_0037")
    command.downgrade(config(), "20260816_0034")
    asyncio.run(seed_legacy_true_rows())

    command.upgrade(config(), "20260830_0037")
    assert asyncio.run(retired_rows_and_guards()) == (False, [False], 2)
    asyncio.run(direct_true_is_rejected())

    command.downgrade(config(), "20260816_0034")
    assert asyncio.run(retired_rows_and_guards()) == (False, [False], 0)
    command.upgrade(config(), "20260830_0037")
    get_settings.cache_clear()


async def restore_legacy_enabled_archive() -> tuple[bool, list[bool]]:
    assert TEST_DATABASE_URL is not None
    engine = create_engine(TEST_DATABASE_URL)
    password = uuid4().hex + uuid4().hex
    try:
        async with engine.begin() as connection:
            await connection.execute(
                text(
                    "INSERT INTO ai_execution_policies("
                    "id,version,effective_at,source,transaction_kind,auto_execute_enabled,"
                    "auto_execute_limit_minor,minimum_confidence_bps,minimum_sample_size,"
                    "change_reason,changed_automatically,created_at) VALUES("
                    ":id,1,now(),NULL,NULL,false,100000,9000,30,"
                    "'archive retirement fixture',false,now())"
                ),
                {"id": uuid4()},
            )

        async with create_session_factory(engine)() as session:
            archive, _ = await ArchiveService(session).export(
                password=password, include_ai_raw=False
            )
        manifest, payload = ArchiveService.open(archive, password=password)
        entities = cast(dict[str, list[dict[str, object]]], payload["entities"])
        entities["ai_settings"][0]["auto_execute_enabled"] = True
        entities["ai_execution_policies"][0]["auto_execute_enabled"] = True
        payload_bytes = json.dumps(
            payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode()
        manifest["payload_sha256"] = hashlib.sha256(payload_bytes).hexdigest()
        legacy_archive = ArchiveService._seal(
            password=password, manifest=manifest, payload=payload_bytes
        )
        manifest, payload = ArchiveService.open(legacy_archive, password=password)

        async with engine.begin() as connection:
            tables = list(
                (
                    await connection.scalars(
                        text(
                            "SELECT quote_ident(tablename) FROM pg_tables "
                            "WHERE schemaname = 'public' AND tablename <> 'alembic_version' "
                            "ORDER BY tablename"
                        )
                    )
                ).all()
            )
            await connection.execute(text(f"TRUNCATE TABLE {', '.join(tables)} CASCADE"))
            await connection.execute(
                AISettings.__table__.insert().values(
                    id=1,
                    auto_execute_enabled=False,
                    ocr_source_enabled=False,
                    shortcut_text_source_enabled=False,
                    auto_execute_limit_minor=100_000,
                    minimum_confidence_bps=9_000,
                    provider_kind=None,
                    provider_base_url=None,
                    provider_model=None,
                    provider_api_key_ciphertext=None,
                    provider_key_version=None,
                    version=1,
                )
            )
            await connection.execute(text("INSERT INTO data_revision (id, revision) VALUES (1, 0)"))
            await ArchiveService.restore_empty_target(
                connection, manifest=manifest, payload=payload
            )
            setting = bool(
                await connection.scalar(
                    text("SELECT auto_execute_enabled FROM ai_settings WHERE id = 1")
                )
            )
            policies = [
                bool(value)
                for value in (
                    await connection.scalars(
                        text("SELECT auto_execute_enabled FROM ai_execution_policies")
                    )
                ).all()
            ]
            return setting, policies
    finally:
        await engine.dispose()


def test_d3_restore_of_legacy_enabled_archive_cannot_resurrect_auto_execute(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    command.upgrade(config(), "20260830_0037")
    assert asyncio.run(restore_legacy_enabled_archive()) == (False, [False])
    get_settings.cache_clear()
