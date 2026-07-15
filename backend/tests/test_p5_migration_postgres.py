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
pytestmark = pytest.mark.skipif(
    TEST_DATABASE_URL is None,
    reason="requires a migrated disposable PostgreSQL database",
)
BACKEND_ROOT = Path(__file__).resolve().parents[1]


def _config() -> Config:
    config = Config(str(BACKEND_ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return config


async def _seed_plan_marker() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        statements = "".join(
            (
                "TRUNCATE reimbursement_operations, reimbursement_receipt_revisions, "
                "reimbursement_claim_revisions, reimbursement_receipt_allocations, "
                "reimbursement_receipts, reimbursement_allocations, reimbursement_parties, "
                "reimbursement_claims, installment_plan_revisions, installment_ledger_links, "
                "installment_operations, installment_periods, installment_plans, "
                "transaction_revisions, postings, transactions, credit_cycles, "
                "categories, accounts CASCADE;",
                "INSERT INTO accounts (id,name,kind,opening_balance_minor,credit_limit_minor,"
                "statement_day,due_day,usage_count,sort_order,version,created_at,updated_at) "
                "VALUES ('00000000-0000-0000-0000-000000000001','卡','credit',0,1000,10,20,0,0,1,now(),now());",
                "INSERT INTO categories (id,name,direction,icon,color_hex,aliases,examples,usage_count,sort_order,version,created_at,updated_at) "
                "VALUES ('00000000-0000-0000-0000-000000000002','分类','expense','cart','#AA5500','[]'::json,'[]'::json,0,0,1,now(),now());",
                "INSERT INTO credit_cycles (id,account_id,period_start,period_end,statement_date,due_date,is_opening_cycle,version,created_at,updated_at) "
                "VALUES ('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','2026-07-11','2026-08-10','2026-08-10','2026-08-20',false,1,now(),now());",
                "INSERT INTO credit_cycles (id,account_id,period_start,period_end,statement_date,due_date,is_opening_cycle,version,created_at,updated_at) "
                "VALUES ('00000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000001','2026-08-11','2026-09-10','2026-09-10','2026-09-20',false,1,now(),now());",
                "INSERT INTO transactions (id,kind,occurred_at,title,category_id,credit_cycle_id,source,idempotency_key,request_hash,version,created_at,updated_at) "
                "VALUES ('00000000-0000-0000-0000-000000000004','credit_purchase',now(),'消费','00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003','manual','00000000-0000-0000-0000-000000000005',repeat('a',64),1,now(),now());",
                "INSERT INTO postings (id,transaction_id,account_id,role,amount_minor,position) "
                "VALUES ('00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001','account',-100,0);",
                "INSERT INTO installment_plans (id,purchase_transaction_id,credit_account_id,installment_count,start_cycle_id,lifecycle,create_idempotency_key,create_request_hash,version,created_at,updated_at) "
                "VALUES ('00000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000001',2,'00000000-0000-0000-0000-000000000003','active','00000000-0000-0000-0000-000000000008',repeat('b',64),1,now(),now());",
                "INSERT INTO installment_periods (id,plan_id,sequence,scheduled_cycle_id,effective_cycle_id,principal_minor,fee_minor,version,created_at,updated_at) VALUES "
                "('00000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000007',1,'00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000003',50,0,1,now(),now()),"
                "('00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000007',2,'00000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000012',50,0,1,now(),now());",
                "INSERT INTO installment_ledger_links (id,transaction_id,plan_id,role,created_at) "
                "VALUES ('00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000007','purchase',now())",
            )
        )
        for statement in statements.split(";"):
            if statement.strip():
                await connection.execute(text(statement))
    await engine.dispose()


async def _clear() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE reimbursement_operations, reimbursement_receipt_revisions, "
                "reimbursement_claim_revisions, reimbursement_receipt_allocations, "
                "reimbursement_receipts, reimbursement_allocations, reimbursement_parties, "
                "reimbursement_claims, installment_plan_revisions, installment_ledger_links, "
                "installment_operations, installment_periods, installment_plans, "
                "transaction_revisions, postings, transactions, credit_cycles, "
                "categories, accounts CASCADE"
            )
        )
    await engine.dispose()


def test_p5_data_blocks_downgrade_and_empty_round_trip(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    asyncio.run(_seed_plan_marker())
    try:
        with pytest.raises(DBAPIError, match="P5 downgrade blocked"):
            command.downgrade(_config(), "20260715_0004")
        asyncio.run(_clear())
        command.downgrade(_config(), "20260715_0004")
        command.upgrade(_config(), "head")
    finally:
        try:
            asyncio.run(_clear())
        except DBAPIError:
            command.upgrade(_config(), "head")
            asyncio.run(_clear())
        command.upgrade(_config(), "head")
        get_settings.cache_clear()
