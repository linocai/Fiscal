import asyncio
from os import environ
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import func, select, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft
from fiscal_api.core.config import get_settings
from fiscal_api.db.models import AccountKind, CreditCycle
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.credit import CreditService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(
    TEST_DATABASE_URL is None,
    reason="requires a migrated disposable PostgreSQL database",
)
BACKEND_ROOT = Path(__file__).resolve().parents[1]


async def _seed_materialized_cycle() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE reimbursement_operations, reimbursement_receipt_revisions, "
                "reimbursement_claim_revisions, reimbursement_receipt_allocations, "
                "reimbursement_receipts, reimbursement_allocations, reimbursement_parties, "
                "reimbursement_claims, transaction_revisions, postings, transactions, "
                "credit_cycles, categories, accounts CASCADE"
            )
        )
    async with factory() as session:
        account = await AccountService(session).create(
            AccountDraft(
                name="降级保护信用卡",
                kind=AccountKind.CREDIT,
                opening_balance_minor=0,
                credit_limit_minor=10_000,
                statement_day=10,
                due_day=20,
            )
        )
        await CreditService(session).get_account(account.id)
    await engine.dispose()


async def _cycle_count() -> int:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.connect() as connection:
        count = await connection.scalar(select(func.count()).select_from(CreditCycle))
    await engine.dispose()
    return int(count or 0)


async def _clear_p4_data() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE reimbursement_operations, reimbursement_receipt_revisions, "
                "reimbursement_claim_revisions, reimbursement_receipt_allocations, "
                "reimbursement_receipts, reimbursement_allocations, reimbursement_parties, "
                "reimbursement_claims, transaction_revisions, postings, transactions, "
                "credit_cycles, categories, accounts CASCADE"
            )
        )
    await engine.dispose()


def _config() -> Config:
    config = Config(str(BACKEND_ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return config


def test_data_bearing_downgrade_aborts_atomically_and_empty_round_trip_succeeds(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    asyncio.run(_seed_materialized_cycle())

    try:
        with pytest.raises(DBAPIError, match="P4 downgrade blocked"):
            command.downgrade(_config(), "20260715_0003")
        assert asyncio.run(_cycle_count()) == 1

        asyncio.run(_clear_p4_data())
        command.downgrade(_config(), "20260715_0003")
        command.upgrade(_config(), "head")
    finally:
        get_settings.cache_clear()
        # If an assertion fails after the protected downgrade, restore the shared test schema.
        try:
            asyncio.run(_clear_p4_data())
        except DBAPIError:
            command.upgrade(_config(), "head")
            asyncio.run(_clear_p4_data())
        command.upgrade(_config(), "head")
        get_settings.cache_clear()
