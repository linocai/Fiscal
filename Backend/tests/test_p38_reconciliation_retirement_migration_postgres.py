import asyncio
from os import environ
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import get_settings

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
BACKEND_ROOT = Path(__file__).resolve().parents[1]
LAST_REVERSIBLE_REVISION = "20260830_0037"
RETIREMENT_REVISION = "20260831_0038"


def _config() -> Config:
    result = Config(str(BACKEND_ROOT / "alembic.ini"))
    result.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return result


def test_p38_populated_0037_upgrade_only_removes_retired_reconciliation_tables(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """0038 must retire only reconciliation evidence, never accounting facts."""

    assert TEST_DATABASE_URL is not None
    database_name = f"fiscal_p38_retirement_{uuid4().hex}"
    postgres_url = (
        make_url(TEST_DATABASE_URL).set(database="postgres").render_as_string(hide_password=False)
    )
    target_url = (
        make_url(TEST_DATABASE_URL)
        .set(database=database_name)
        .render_as_string(hide_password=False)
    )

    async def create_database() -> None:
        engine = create_async_engine(postgres_url, isolation_level="AUTOCOMMIT")
        try:
            async with engine.connect() as connection:
                await connection.execute(text(f'CREATE DATABASE "{database_name}"'))
        finally:
            await engine.dispose()

    async def drop_database() -> None:
        engine = create_async_engine(postgres_url, isolation_level="AUTOCOMMIT")
        try:
            async with engine.connect() as connection:
                await connection.execute(text(f'DROP DATABASE IF EXISTS "{database_name}"'))
        finally:
            await engine.dispose()

    async def seed_and_snapshot() -> tuple[int, int, int, int, str, str, str, str]:
        account_id, category_id, cycle_id, transaction_id, import_id = (uuid4() for _ in range(5))
        checkpoint_id, dismissal_id = uuid4(), uuid4()
        engine = create_async_engine(target_url)
        try:
            async with engine.begin() as connection:
                await connection.execute(
                    text(
                        """
                        INSERT INTO accounts
                        (id, name, kind, opening_balance_minor, credit_limit_minor,
                         statement_day, due_day, cycle_mode, sort_order, usage_count,
                         version, created_at, updated_at)
                        VALUES (:id, 'P38 信用账户', 'credit', 0, 100000, 1, 20,
                                'statement_day_cutoff', 0, 1, 1, now(), now())
                        """
                    ),
                    {"id": str(account_id)},
                )
                await connection.execute(
                    text(
                        """
                        INSERT INTO categories
                        (id, name, direction, icon, color_hex, aliases, examples,
                         usage_count, sort_order, version, created_at, updated_at)
                        VALUES (:id, 'P38 分类', 'expense', 'tag', '#336699', '[]'::json,
                                '[]'::json, 1, 0, 1, now(), now())
                        """
                    ),
                    {"id": str(category_id)},
                )
                await connection.execute(
                    text(
                        """
                        INSERT INTO credit_cycles
                        (id, account_id, period_start, period_end, statement_date, due_date,
                         is_opening_cycle, version, created_at, updated_at)
                        VALUES (:id, :account_id, '2026-08-01', '2026-08-31', '2026-09-01',
                                '2026-09-20', false, 1, now(), now())
                        """
                    ),
                    {"id": str(cycle_id), "account_id": str(account_id)},
                )
                await connection.execute(
                    text(
                        """
                        INSERT INTO transactions
                        (id, kind, occurred_at, title, category_id, credit_cycle_id, source,
                         idempotency_key, request_hash, version, created_at, updated_at)
                        VALUES (:id, 'credit_purchase', '2026-08-10T02:00:00Z',
                                'P38 保留账目', :category_id, :cycle_id, 'manual',
                                :idempotency_key, :request_hash, 1, now(), now())
                        """
                    ),
                    {
                        "id": str(transaction_id),
                        "category_id": str(category_id),
                        "cycle_id": str(cycle_id),
                        "idempotency_key": str(uuid4()),
                        "request_hash": "a" * 64,
                    },
                )
                await connection.execute(
                    text(
                        """
                        INSERT INTO postings
                        (id, transaction_id, account_id, role, amount_minor, position)
                        VALUES (:id, :transaction_id, :account_id, 'account', -12345, 0)
                        """
                    ),
                    {
                        "id": str(uuid4()),
                        "transaction_id": str(transaction_id),
                        "account_id": str(account_id),
                    },
                )
                await connection.execute(
                    text(
                        """
                        INSERT INTO statement_imports
                        (id, document_sha256, byte_size, page_count, mime_type, display_name,
                         currency, status, version, created_at, updated_at)
                        VALUES (:id, :digest, 64, 1, 'application/pdf', 'statement.pdf',
                                'CNY', 'review_required', 1, now(), now())
                        """
                    ),
                    {"id": str(import_id), "digest": "b" * 64},
                )
                await connection.execute(
                    text(
                        """
                        INSERT INTO reconciliation_checkpoints
                        (id, target_kind, account_id, as_of, actual_balance_minor, note, created_at)
                        VALUES (:id, 'account', :account_id, now(), 87655,
                                'P38 retired evidence', now())
                        """
                    ),
                    {"id": str(checkpoint_id), "account_id": str(account_id)},
                )
                await connection.execute(
                    text(
                        """
                        INSERT INTO attention_dismissals
                        (id, source_type, source_id, expires_at, created_at)
                        VALUES (:id, 'reconciliation_checkpoint', :source_id,
                                now() + interval '1 day', now())
                        """
                    ),
                    {"id": str(dismissal_id), "source_id": str(checkpoint_id)},
                )
                values = await connection.execute(
                    text(
                        """
                        SELECT
                          (SELECT count(*) FROM accounts),
                          (SELECT count(*) FROM transactions),
                          (SELECT count(*) FROM credit_cycles),
                          (SELECT count(*) FROM statement_imports),
                          (SELECT name FROM accounts WHERE id = :account_id),
                          (SELECT title FROM transactions WHERE id = :transaction_id),
                          (SELECT due_date::text FROM credit_cycles WHERE id = :cycle_id),
                          (SELECT status FROM statement_imports WHERE id = :import_id)
                        """
                    ),
                    {
                        "account_id": str(account_id),
                        "transaction_id": str(transaction_id),
                        "cycle_id": str(cycle_id),
                        "import_id": str(import_id),
                    },
                )
                assert (
                    await connection.scalar(text("SELECT count(*) FROM reconciliation_checkpoints"))
                    == 1
                )
                assert (
                    await connection.scalar(text("SELECT count(*) FROM attention_dismissals")) == 1
                )
                return tuple(values.one())
        finally:
            await engine.dispose()

    async def assert_retirement(snapshot: tuple[int, int, int, int, str, str, str, str]) -> None:
        engine = create_async_engine(target_url)
        try:
            async with engine.connect() as connection:
                assert (
                    await connection.scalar(
                        text("SELECT to_regclass('public.reconciliation_checkpoints')")
                    )
                    is None
                )
                assert (
                    await connection.scalar(
                        text("SELECT to_regclass('public.attention_dismissals')")
                    )
                    is None
                )
                values = (
                    await connection.execute(
                        text(
                            """
                            SELECT
                              (SELECT count(*) FROM accounts),
                              (SELECT count(*) FROM transactions),
                              (SELECT count(*) FROM credit_cycles),
                              (SELECT count(*) FROM statement_imports),
                              (SELECT name FROM accounts),
                              (SELECT title FROM transactions),
                              (SELECT due_date::text FROM credit_cycles),
                              (SELECT status FROM statement_imports)
                            """
                        )
                    )
                ).one()
                values = tuple(values)
                assert values == snapshot
                assert (
                    await connection.scalar(text("SELECT version_num FROM alembic_version"))
                    == RETIREMENT_REVISION
                )
        finally:
            await engine.dispose()

    asyncio.run(create_database())
    try:
        monkeypatch.setenv("FISCAL_DATABASE_URL", target_url)
        get_settings.cache_clear()
        command.upgrade(_config(), LAST_REVERSIBLE_REVISION)
        snapshot = asyncio.run(seed_and_snapshot())
        command.upgrade(_config(), RETIREMENT_REVISION)
        asyncio.run(assert_retirement(snapshot))
        with pytest.raises(RuntimeError, match="intentionally irreversible"):
            command.downgrade(_config(), LAST_REVERSIBLE_REVISION)
    finally:
        asyncio.run(drop_database())
        monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
        get_settings.cache_clear()
