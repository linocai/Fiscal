# ruff: noqa: E501

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


async def clear() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE reimbursement_operations, reimbursement_receipt_revisions, reimbursement_claim_revisions, reimbursement_receipt_allocations, reimbursement_receipts, reimbursement_allocations, reimbursement_parties, reimbursement_claims, installment_plan_revisions, installment_ledger_links, installment_operations, installment_periods, installment_plans, transaction_revisions, postings, transactions, credit_cycles, categories, accounts CASCADE"
            )
        )
    await engine.dispose()


async def seed_marker() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        statements = (
            "INSERT INTO accounts(id,name,kind,opening_balance_minor,usage_count,sort_order,version,created_at,updated_at) VALUES('10000000-0000-0000-0000-000000000001','卡','debit',0,0,0,1,now(),now())",
            "INSERT INTO categories(id,name,direction,icon,color_hex,aliases,examples,usage_count,sort_order,version,created_at,updated_at) VALUES('10000000-0000-0000-0000-000000000002','差旅','expense','airplane','#445566','[]','[]',0,0,1,now(),now())",
            "INSERT INTO transactions(id,kind,occurred_at,title,category_id,source,idempotency_key,request_hash,version,created_at,updated_at) VALUES('10000000-0000-0000-0000-000000000003','expense',now(),'垫付','10000000-0000-0000-0000-000000000002','manual','10000000-0000-0000-0000-000000000004',repeat('a',64),1,now(),now())",
            "INSERT INTO postings(id,transaction_id,account_id,role,amount_minor,position) VALUES('10000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','account',-100,0)",
            "INSERT INTO reimbursement_claims(id,title,create_idempotency_key,create_request_hash,version,created_at,updated_at) VALUES('10000000-0000-0000-0000-000000000006','报销','10000000-0000-0000-0000-000000000007',repeat('b',64),1,now(),now())",
            "INSERT INTO reimbursement_parties(id,claim_id,name,position) VALUES('10000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000006','公司',0)",
            "INSERT INTO reimbursement_allocations(id,claim_id,party_id,transaction_id,amount_minor,position) VALUES('10000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000003',100,0)",
        )
        for statement in statements:
            await connection.execute(text(statement))
    await engine.dispose()


def test_p6_data_blocks_downgrade_and_empty_roundtrip(monkeypatch: pytest.MonkeyPatch) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    asyncio.run(clear())
    asyncio.run(seed_marker())
    with pytest.raises(DBAPIError, match="P6 downgrade blocked"):
        command.downgrade(config(), "20260715_0005")
    asyncio.run(clear())
    command.downgrade(config(), "20260715_0005")
    command.upgrade(config(), "head")
    get_settings.cache_clear()
