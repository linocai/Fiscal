# ruff: noqa: F811
from datetime import UTC, date, datetime
from os import environ
from uuid import uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p2_schemas import AccountDraft
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p13_schemas import CashFlowDraft
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import AccountKind, LedgerTransaction, TransactionKind
from fiscal_api.db.models.cash_flow import CashFlowItem
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.cash_flow import CashFlowService
from fiscal_api.services.credit import CreditService
from fiscal_api.services.loan_recovery import LoanRecoveryRequest, recover_loan
from fiscal_api.services.transactions import TransactionService
from test_p5_postgres import session  # noqa: F401

pytestmark = pytest.mark.skipif(
    not environ.get("FISCAL_TEST_DATABASE_URL"), reason="isolated PostgreSQL required"
)


async def fixture_request(db: AsyncSession) -> LoanRecoveryRequest:
    credit = await AccountService(db).create(
        AccountDraft(
            name="Loan",
            kind=AccountKind.CREDIT,
            opening_balance_minor=0,
            credit_limit_minor=20000000,
            statement_day=20,
            due_day=22,
        )
    )
    debit = await AccountService(db).create(
        AccountDraft(name="Debit", kind=AccountKind.DEBIT, opening_balance_minor=1000000)
    )
    plans = await CashFlowService(db).create(
        CashFlowDraft(
            title="Loan",
            direction="outflow",
            planned_amount_minor=253300,
            expected_date=date(2026, 9, 22),
            recurrence="monthly",
            recurrence_end_date=date(2029, 9, 22),
        ),
        uuid4(),
    )
    return LoanRecoveryRequest(
        account_id=credit.id,
        account_expected_version=credit.version,
        payment_account_id=debit.id,
        confirmed_at=datetime(2026, 9, 22, 0, tzinfo=UTC),
        first_statement_date=date(2026, 9, 20),
        installment_count=37,
        monthly_principal_minor=253300,
        confirmed_principal_before_payment_minor=9372100,
        title="Loan",
        superseded_plan_versions={i.manual_item_id: i.version for i in plans.items},
    )


async def test_recovers_principal_monthly_cycles_and_payment_without_spending(
    session: AsyncSession,
):
    request = await fixture_request(session)
    key = uuid4()
    receipt = await recover_loan(session, request, key)
    await session.commit()
    assert receipt["principal_after_minor"] == 9118800
    summary = await CreditService(session).get_account(request.account_id)
    assert summary.current_debt_minor == 9118800
    assert summary.next_due_cycle.due_date == date(2026, 10, 22)
    cycles = await CreditService(session).list_cycles(request.account_id, limit=100, cursor=None)
    pending = [c for c in cycles.items if c.remaining_minor]
    assert len(pending) == 36 and all(c.remaining_minor == 253300 for c in pending)
    rows = list((await session.scalars(select(LedgerTransaction))).all())
    assert {r.kind for r in rows} == {"loan_principal", "repayment"}
    assert all(r.occurred_at >= request.confirmed_at for r in rows)
    cash = await AccountService(session).get(request.payment_account_id)
    assert cash.current_balance_minor == 746700
    plans = list((await session.scalars(select(CashFlowItem))).all())
    assert len(plans) == 37 and all(p.status == "cancelled" for p in plans)
    from fiscal_api.services.archive import ArchiveService
    from fiscal_api.services.reporting import ReportingService

    reporting = ReportingService(session)
    spending = await reporting.spending(date_from=date(2026, 9, 1), date_to=date(2026, 9, 30))
    assert spending.gross_consumption_minor == 0
    flow = await reporting.cash_flow(
        date_from=date(2026, 9, 1),
        date_to=date(2026, 9, 30),
        forecast_days=30,
        today=date(2026, 9, 22),
    )
    assert flow.inflow_minor == 0 and flow.outflow_minor == 253300
    previous = await reporting.monthly_report(period="2026-08")
    assert previous.summary.credit_debt_at_period_end_minor == 0
    password = str(uuid4())
    archive, _ = await ArchiveService(session).export(password=password, include_ai_raw=False)
    manifest, payload = ArchiveService.open(archive, password=password)
    assert manifest["database_revision"] == "20260922_0041"
    assert any(t["kind"] == "loan_principal" for t in payload["entities"]["transactions"])
    replay = await recover_loan(session, request, key)
    assert replay["repayment_id"] == receipt["repayment_id"] and replay["replayed"]
    await session.rollback()


async def test_confirmation_mismatch_makes_no_financial_write(session: AsyncSession):
    request = await fixture_request(session)
    request.confirmed_principal_before_payment_minor += 1
    with pytest.raises(APIError):
        await recover_loan(session, request, uuid4())
    await session.rollback()
    assert not list((await session.scalars(select(LedgerTransaction))).all())


async def test_stale_plan_rolls_back_and_zero_debt_guard(session: AsyncSession):
    request = await fixture_request(session)
    request.superseded_plan_versions[next(iter(request.superseded_plan_versions))] += 1
    with pytest.raises(APIError):
        await recover_loan(session, request, uuid4())
    await session.rollback()
    assert not list((await session.scalars(select(LedgerTransaction))).all())


async def test_void_repayment_restores_debt_and_first_period(session: AsyncSession):
    request = await fixture_request(session)
    receipt = await recover_loan(session, request, uuid4())
    await session.commit()
    from uuid import UUID

    tx = await TransactionService(session).get(UUID(receipt["repayment_id"]))
    await TransactionService(session).void(tx.id, tx.version)
    summary = await CreditService(session).get_account(request.account_id)
    assert summary.current_debt_minor == 9372100
    with pytest.raises(APIError):
        await recover_loan(session, request, uuid4())
    await session.rollback()


def test_principal_cannot_be_submitted_as_manual_transaction():
    with pytest.raises(ValidationError):
        TransactionDraft(
            kind=TransactionKind.LOAN_PRINCIPAL,
            amount_minor=100,
            occurred_at=datetime.now(UTC),
            title="Must reject",
        )
