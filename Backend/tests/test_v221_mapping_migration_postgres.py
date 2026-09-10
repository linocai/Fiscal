import asyncio
from os import environ
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_0039_backfills_deleted_and_current_mapping_history():
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    command.upgrade(config, "20260831_0038")
    current_id, deleted_id, merchant_id = uuid4(), uuid4(), uuid4()
    account_id, category_id = uuid4(), uuid4()

    async def seed():
        assert TEST_DATABASE_URL is not None
        engine = create_async_engine(TEST_DATABASE_URL)
        try:
            async with engine.begin() as connection:
                await connection.execute(
                    text("""
                    INSERT INTO accounts
                    (id, name, kind, opening_balance_minor, sort_order, usage_count,
                     version, created_at, updated_at)
                    VALUES (:id, 'migration debit', 'debit', 0, 0, 2, 1, now(), now())
                """),
                    {"id": account_id},
                )
                await connection.execute(
                    text("""
                    INSERT INTO categories
                    (id, name, direction, icon, color_hex, aliases, examples,
                     sort_order, usage_count, version, created_at, updated_at)
                    VALUES (:id, 'migration income', 'income', 'banknote', '#3366FF',
                            '[]', '[]', 0, 2, 1, now(), now())
                """),
                    {"id": category_id},
                )
                for transaction_id in [current_id, deleted_id]:
                    await connection.execute(
                        text("""
                        INSERT INTO transactions
                        (id, kind, occurred_at, title, source, idempotency_key, request_hash,
                         category_id, version, created_at, updated_at)
                        VALUES (:id, 'income', now(), 'migration fixture', 'manual', :key,
                                :hash, :category, 1, now(), now())
                    """),
                        {
                            "id": transaction_id,
                            "key": uuid4(),
                            "hash": "a" * 64,
                            "category": category_id,
                        },
                    )
                    await connection.execute(
                        text("""
                        INSERT INTO postings
                        (id, transaction_id, account_id, role, amount_minor, position)
                        VALUES (:id, :transaction, :account, 'account', 100, 0)
                    """),
                        {"id": uuid4(), "transaction": transaction_id, "account": account_id},
                    )
                await connection.execute(
                    text("""
                    INSERT INTO merchants (id, name, version, created_at, updated_at)
                    VALUES (:id, 'migration merchant', 1, now(), now())
                """),
                    {"id": merchant_id},
                )
                await connection.execute(
                    text("""
                    INSERT INTO transaction_merchant_mappings
                    (id, transaction_id, merchant_id, version, confirmed_at, created_at, updated_at)
                    VALUES (:id, :transaction, :merchant, 1, now(), now(), now())
                """),
                    {"id": uuid4(), "transaction": current_id, "merchant": merchant_id},
                )
                for transaction_id, version in [(current_id, 8), (deleted_id, 4)]:
                    await connection.execute(
                        text("""
                        INSERT INTO merchant_operations
                        (id, idempotency_key, request_hash, action, receipt, created_at)
                        VALUES (:id, :key, :hash, 'confirmed',
                            jsonb_build_object('mapping', jsonb_build_object(
                                'transaction_id', CAST(:transaction AS text),
                                'mapping_version', CAST(:version AS integer))), now())
                    """),
                        {
                            "id": uuid4(),
                            "key": uuid4(),
                            "hash": "b" * 64,
                            "transaction": str(transaction_id),
                            "version": version,
                        },
                    )
        finally:
            await engine.dispose()

    asyncio.run(seed())
    command.upgrade(config, "head")

    async def verify():
        assert TEST_DATABASE_URL is not None
        engine = create_async_engine(TEST_DATABASE_URL)
        try:
            async with engine.connect() as connection:
                rows = dict(
                    (
                        await connection.execute(
                            text("SELECT id, merchant_mapping_generation FROM transactions")
                        )
                    ).all()
                )
                assert rows[current_id] == 9
                assert rows[deleted_id] == 5
                assert (
                    await connection.scalar(
                        text("SELECT version FROM transaction_merchant_mappings")
                    )
                    == 9
                )
        finally:
            await engine.dispose()

    asyncio.run(verify())
