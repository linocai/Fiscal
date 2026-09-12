from __future__ import annotations

import asyncio
from datetime import UTC, date, datetime
from os import environ
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text

from fiscal_api.db.models import (
    Account,
    CashFlowItem,
    CashFlowItemRevision,
    LedgerTransaction,
    Posting,
)
from fiscal_api.db.session import create_engine, create_session_factory

URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(URL is None, reason="requires isolated PostgreSQL")


def test_0039_upgrade_preserves_superseded_links_and_protected_downgrade(monkeypatch):
    monkeypatch.setenv("FISCAL_DATABASE_URL", URL)
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    command.downgrade(config, "20260910_0039")
    old_tx, new_tx, item_id = uuid4(), uuid4(), uuid4()

    async def seed():
        engine = create_engine(URL)
        try:
            async with create_session_factory(engine)() as session:
                account = Account(name="Synthetic old cash", kind="debit", opening_balance_minor=0)
                session.add(account)
                await session.flush()
                for tx_id in [old_tx, new_tx]:
                    session.add(
                        LedgerTransaction(
                            id=tx_id,
                            kind="income",
                            title="Synthetic old settled",
                            occurred_at=datetime(2026, 7, 1, tzinfo=UTC),
                            source="cash_flow",
                            idempotency_key=uuid4(),
                            request_hash="0" * 64,
                        )
                    )
                await session.flush()
                for tx_id in [old_tx, new_tx]:
                    session.add(
                        Posting(
                            transaction_id=tx_id,
                            account_id=account.id,
                            role="account",
                            amount_minor=100,
                            position=0,
                        )
                    )
                await session.flush()
                session.add(
                    CashFlowItem(
                        id=item_id,
                        title="Synthetic old plan",
                        direction="inflow",
                        planned_amount_minor=100,
                        expected_date=date(2026, 7, 1),
                        account_id=account.id,
                        status="settled",
                        source="manual",
                        idempotency_key=uuid4(),
                        request_hash="0" * 64,
                        linked_transaction_id=new_tx,
                    )
                )
                await session.flush()
                session.add(
                    CashFlowItemRevision(
                        item_id=item_id,
                        version=1,
                        event="settled",
                        snapshot={"linked_transaction_id": str(old_tx)},
                    )
                )
                await session.commit()
        finally:
            await engine.dispose()

    asyncio.run(seed())
    command.upgrade(config, "head")

    async def verify():
        engine = create_engine(URL)
        try:
            async with engine.begin() as connection:
                result = (
                    await connection.execute(
                        text(
                            "SELECT transaction_id, closes_remainder "
                            "FROM cash_flow_settlement_links "
                            "ORDER BY transaction_id"
                        )
                    )
                ).all()
                assert {row[0] for row in result} == {old_tx, new_tx}
                assert all(row[1] for row in result)
                await connection.execute(
                    text(
                        "INSERT INTO accounts(id,name,kind,opening_balance_minor,cycle_mode,"
                        "sort_order,usage_count,version,created_at,updated_at) "
                        "VALUES (:id,'Synthetic on demand','credit',0,"
                        "'on_demand',0,0,1,now(),now())"
                    ),
                    {"id": uuid4()},
                )
        finally:
            await engine.dispose()

    asyncio.run(verify())
    with pytest.raises(RuntimeError, match="financial data exists"):
        command.downgrade(config, "20260910_0039")
