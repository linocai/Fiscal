"""B5 regressions; use only the explicitly provided disposable test database."""

from __future__ import annotations

import asyncio
from datetime import UTC, date, datetime
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import insert, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.core.config import Settings
from fiscal_api.db.models import (
    Account,
    Category,
    CreditCycle,
    DataRevision,
    LedgerTransaction,
    Merchant,
    Posting,
    ReimbursementAllocation,
    ReimbursementClaim,
    ReimbursementParty,
    TransactionMerchantMapping,
    TransactionRevision,
)
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.main import create_app
from fiscal_api.repositories.reporting import ReportingRepository
from fiscal_api.services.archive import ArchiveService
from fiscal_api.services.reporting import ReportingService

URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(URL is None, reason="requires isolated PostgreSQL")


def test_archive_snapshot_is_independent_of_auth_and_concurrent_commit(monkeypatch):
    async def run():
        engine = create_engine(URL)
        factory = create_session_factory(engine)
        account_id, tx_id = uuid4(), uuid4()
        password = uuid4().hex
        captured = False
        execute = AsyncSession.execute

        async def interleave(session, statement, *args, **kwargs):
            nonlocal captured
            result = await execute(session, statement, *args, **kwargs)
            if not captured and str(statement).startswith("SELECT accounts."):
                captured = True
                assert await session.scalar(text("SHOW transaction_isolation")) == "repeatable read"
                assert await session.scalar(text("SHOW transaction_read_only")) == "on"
                async with factory() as writer:
                    writer.add(
                        Account(
                            id=account_id,
                            name="after snapshot",
                            kind="debit",
                            opening_balance_minor=0,
                        )
                    )
                    await writer.flush()
                    writer.add(
                        LedgerTransaction(
                            id=tx_id,
                            kind="income",
                            title="after snapshot",
                            occurred_at=datetime(2026, 9, 10, tzinfo=UTC),
                            idempotency_key=uuid4(),
                            request_hash="0" * 64,
                        )
                    )
                    await writer.flush()
                    writer.add(
                        Posting(
                            transaction_id=tx_id,
                            account_id=account_id,
                            amount_minor=101,
                            role="account",
                            position=0,
                        )
                    )
                    await writer.execute(
                        update(DataRevision).values(revision=DataRevision.revision + 1)
                    )
                    await writer.commit()
            return result

        monkeypatch.setattr(AsyncSession, "execute", interleave)
        try:
            async with factory() as auth_session:
                await auth_session.execute(text("SELECT 1"))
                transaction = auth_session.get_transaction()
                data, manifest = await ArchiveService(auth_session).export(
                    password=password, include_ai_raw=False
                )
                assert auth_session.get_transaction() is transaction
                _, payload = ArchiveService.open(data, password=password)
                assert captured
                assert manifest["data_revision"] == 0
                assert not payload["entities"]["accounts"]
                assert not payload["entities"]["transactions"]
                assert not payload["entities"]["postings"]
                assert ArchiveService.dry_run_report(manifest, payload)["relationship_errors"] == 0
            async with factory() as session:
                assert await session.scalar(select(DataRevision.revision)) == 1
                assert await session.get(LedgerTransaction, tx_id) is not None
        finally:
            await engine.dispose()

    asyncio.run(run())


def test_history_balance_opt_in_legacy_and_exports():
    async def seed():
        engine = create_engine(URL)
        try:
            async with create_session_factory(engine)() as session:
                account = Account(
                    name="historical credit",
                    kind="credit",
                    opening_balance_minor=10000,
                    credit_limit_minor=100000,
                    statement_day=10,
                    due_day=20,
                    cycle_mode="statement_day_cutoff",
                    opening_balance_as_of_date=date(2026, 9, 10),
                    opening_due_date=date(2026, 9, 20),
                )
                session.add(account)
                await session.flush()
                category = Category(
                    name="basis fixture expense",
                    direction="expense",
                    icon="cart",
                    color_hex="#123456",
                )
                cycle = CreditCycle(
                    account_id=account.id,
                    period_start=date(2026, 8, 11),
                    period_end=date(2026, 9, 10),
                    statement_date=date(2026, 9, 10),
                    due_date=date(2026, 9, 20),
                )
                session.add_all([category, cycle])
                await session.flush()
                for day, amount in ((9, 200), (10, 250)):
                    tx = LedgerTransaction(
                        kind="credit_purchase",
                        category_id=category.id,
                        credit_cycle_id=cycle.id,
                        title="basis boundary",
                        occurred_at=datetime(2026, 9, day, 4, tzinfo=UTC),
                        idempotency_key=uuid4(),
                        request_hash="0" * 64,
                    )
                    session.add(tx)
                    await session.flush()
                    session.add(
                        Posting(
                            transaction_id=tx.id,
                            account_id=account.id,
                            amount_minor=-amount,
                            role="account",
                            position=0,
                        )
                    )
                await session.commit()
        finally:
            await engine.dispose()

    asyncio.run(seed())

    async def ready():
        return None

    app = create_app(settings=Settings(environment="test", database_url=URL), readiness_check=ready)
    auth = {"Authorization": "Bearer v221-report-fixture"}
    opt = {**auth, "X-Fiscal-Report-Balance-Semantics": "as-of-v1"}
    with TestClient(app) as client:
        for period in ("2026-08", "2026-09"):
            path = f"/api/v1/reports/v2/monthly/{period}"
            legacy = client.get(path, headers=auth)
            assert legacy.status_code == 409, legacy.text
            assert legacy.json()["error"]["code"] == "historical_balance_unavailable"
            response = client.get(path, headers=opt)
            assert response.status_code == 200, response.text
            assert response.headers["X-Fiscal-Report-Balance-Semantics"] == "as-of-v1"
            assert "X-Fiscal-Report-Balance-Semantics" in response.headers["Vary"]
            report = response.json()
            row = report["accounts"][0]
            assert row["opening_balance_minor"] is None
            assert row["balance_unavailable_reason"] == "before_opening_as_of"
            assert report["summary"]["income_minor"] == 0
            if period == "2026-08":
                assert report["summary"]["credit_debt_at_period_end_minor"] is None
                assert row["closing_balance_minor"] is None
            else:
                assert report["summary"]["credit_debt_at_period_end_minor"] == 10250
                assert row["closing_balance_minor"] == 10250
            exported = client.get(path + "/export.csv?expected_data_revision=0", headers=opt)
            assert exported.status_code == 200, exported.text
            assert "before_opening_as_of" in exported.text
            assert exported.headers["X-Fiscal-Report-Balance-Semantics"] == "as-of-v1"
        known = client.get("/api/v1/reports/v2/monthly/2026-10", headers=auth)
        assert known.status_code == 200, known.text
        assert known.json()["accounts"][0]["opening_balance_minor"] == 10250
        assert "opening_balance_status" not in known.json()["accounts"][0]
        assert "credit_debt_at_period_end_status" not in known.json()["summary"]
        legacy_v1 = client.get("/api/v1/reports/monthly/2026-08", headers=auth)
        assert legacy_v1.status_code == 409


def test_large_report_source_sets_have_bounded_binds_and_exact_totals():
    async def run():
        engine = create_engine(URL)
        factory = create_session_factory(engine)
        ids = [uuid4() for _ in range(32768)]
        now = datetime(2026, 9, 10, tzinfo=UTC)
        try:
            async with factory() as session:
                account = Account(name="large ledger", kind="debit", opening_balance_minor=0)
                session.add(account)
                await session.flush()
                for offset in range(0, len(ids), 500):
                    batch = ids[offset : offset + 500]
                    await session.execute(
                        insert(LedgerTransaction),
                        [
                            dict(
                                id=id,
                                kind="expense",
                                title="source",
                                occurred_at=now,
                                idempotency_key=uuid4(),
                                request_hash="0" * 64,
                            )
                            for id in batch
                        ],
                    )
                    await session.execute(
                        insert(Posting),
                        [
                            dict(
                                transaction_id=id,
                                account_id=account.id,
                                amount_minor=-1,
                                role="account",
                                position=0,
                            )
                            for id in batch
                        ],
                    )
                    await session.execute(
                        insert(TransactionRevision),
                        [
                            dict(
                                transaction_id=id,
                                version=1,
                                event="created",
                                snapshot={"amount_minor": 1},
                                created_at=now,
                            )
                            for id in batch
                        ],
                    )
                merchant = Merchant(name="large fixture merchant")
                claim = ReimbursementClaim(
                    title="large fixture claim",
                    submitted_at=now,
                    create_idempotency_key=uuid4(),
                    create_request_hash="0" * 64,
                )
                session.add_all([merchant, claim])
                await session.flush()
                party = ReimbursementParty(claim_id=claim.id, name="fixture payer", position=0)
                session.add(party)
                await session.flush()
                session.add(
                    ReimbursementAllocation(
                        claim_id=claim.id,
                        party_id=party.id,
                        transaction_id=ids[-1],
                        amount_minor=1,
                        position=0,
                    )
                )
                session.add(
                    TransactionMerchantMapping(transaction_id=ids[-1], merchant_id=merchant.id)
                )
                await session.commit()
            async with factory() as session:
                repository = ReportingRepository(session)
                service = ReportingService(session)
                assert len(
                    await repository.period_transaction_snapshots(
                        transaction_ids=set(ids), recorded_before=datetime(2026, 10, 1, tzinfo=UTC)
                    )
                ) == len(ids)
                assert await repository.refunds_for_sources(set(ids)) == []
                reimbursements = await repository.reimbursement_facts(set(ids))
                assert len(reimbursements) == 1
                assert reimbursements[0].allocated_minor == 1
                assert set(await service._merchant_by_transaction(set(ids))) == {ids[-1]}
                report = await service.monthly_report_v2(period="2026-09")
                assert report.summary.gross_consumption_minor == len(ids)
                assert report.summary.expected_reimbursement_minor == 1
                assert report.summary.personal_expected_minor == len(ids) - 1
                assert report.summary.cash_outflow_minor == len(ids)
                assert report.accounts[0].closing_balance_minor == -len(ids)
                assert sum(row.transaction_count for row in report.sources) == len(ids)
                for sources in (set(), {ids[0]}, set(ids[:32765])):
                    assert len(
                        await repository.period_transaction_snapshots(
                            transaction_ids=sources,
                            recorded_before=datetime(2026, 10, 1, tzinfo=UTC),
                        )
                    ) == len(sources)
        finally:
            await engine.dispose()

    asyncio.run(run())
