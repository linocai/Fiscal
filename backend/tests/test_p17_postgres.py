from collections.abc import AsyncIterator
from datetime import UTC, date, datetime
from os import environ
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p4_schemas import CreditScheduleChangeRequest
from fiscal_api.api.p5_schemas import InstallmentPurchaseCreate
from fiscal_api.api.p13_schemas import (
    CashFlowAction,
    CashFlowSystemKind,
    CashFlowSystemReplace,
)
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import (
    AccountKind,
    CashFlowStatus,
    CategoryDirection,
    CreditCycleMode,
    LedgerTransaction,
    TransactionKind,
)
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.cash_flow import CashFlowService
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.credit import CreditService
from fiscal_api.services.installments import InstallmentService
from fiscal_api.services.transactions import TransactionService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


@pytest_asyncio.fixture
async def session() -> AsyncIterator[AsyncSession]:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE cash_flow_system_overrides, installment_plan_revisions, "
                "installment_ledger_links, installment_operations, installment_periods, "
                "installment_plans, transaction_revisions, postings, transactions, "
                "credit_cycles, categories, accounts CASCADE"
            )
        )
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


async def natural_credit(session: AsyncSession, name: str = "花呗"):  # type: ignore[no-untyped-def]
    return await AccountService(session).create(
        AccountDraft(
            name=name,
            kind=AccountKind.CREDIT,
            opening_balance_minor=0,
            credit_limit_minor=1_000_000,
            statement_day=1,
            due_day=8,
            cycle_mode=CreditCycleMode.PREVIOUS_CALENDAR_MONTH,
        )
    )


async def expense_category(session: AsyncSession):  # type: ignore[no-untyped-def]
    return await CategoryService(session).create(
        CategoryDraft(
            name="网购",
            direction=CategoryDirection.EXPENSE,
            icon="cart",
            color_hex="#3366FF",
        )
    )


async def test_atomic_900_three_period_purchase_projects_read_only_cash_flow(
    session: AsyncSession,
) -> None:
    account = await natural_credit(session)
    category = await expense_category(session)
    request = InstallmentPurchaseCreate(
        purchase=TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=90_000,
            occurred_at=datetime(2026, 7, 15, 4, tzinfo=UTC),
            title="淘宝分期商品",
            account_id=account.id,
            category_id=category.id,
        ),
        installment_count=3,
        total_fee_minor=0,
    )
    service = InstallmentService(session)
    preview = await service.preview_purchase(request)
    assert preview.start_statement_date == date(2026, 8, 1)
    assert [item.amount_due_minor for item in preview.periods] == [30_000] * 3
    assert [item.due_date for item in preview.periods] == [
        date(2026, 8, 8),
        date(2026, 9, 8),
        date(2026, 10, 8),
    ]

    key = uuid4()
    created = await service.create_purchase(request, key)
    replay = await service.create_purchase(request, key)
    assert replay.purchase.id == created.purchase.id
    assert replay.plan.id == created.plan.id
    assert (await CreditService(session).get_account(account.id)).current_debt_minor == 90_000

    cash_flow = CashFlowService(session)
    projected = [
        item
        for item in (await cash_flow.active(account_id=account.id)).items
        if item.system_kind is CashFlowSystemKind.CREDIT_CYCLE
    ]
    assert [(item.expected_date, item.planned_amount_minor) for item in projected] == [
        (date(2026, 8, 8), 30_000),
        (date(2026, 9, 8), 30_000),
        (date(2026, 10, 8), 30_000),
    ]
    assert all(item.actions == [CashFlowAction.CONFIRM_REPAYMENT] for item in projected)
    first = projected[0]
    assert first.system_reference_id is not None
    with pytest.raises(APIError) as readonly:
        await cash_flow.update_system(
            CashFlowSystemKind.CREDIT_CYCLE,
            first.system_reference_id,
            CashFlowSystemReplace(
                title=first.title,
                planned_amount_minor=1,
                expected_date=first.expected_date,
                status=CashFlowStatus.COMPLETED,
                expected_version=first.version,
            ),
        )
    assert readonly.value.code == "cash_flow_credit_projection_read_only"

    payment = await AccountService(session).create(
        AccountDraft(name="还款卡", kind=AccountKind.DEBIT, opening_balance_minor=100_000)
    )
    first_period = created.plan.periods[0]
    repayment = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.REPAYMENT,
            amount_minor=10_000,
            occurred_at=datetime(2026, 7, 17, 4, tzinfo=UTC),
            title="部分还款",
            account_id=payment.id,
            destination_account_id=account.id,
            credit_cycle_id=first_period.effective_cycle_id,
        ),
        uuid4(),
    )
    refreshed = [
        item
        for item in (await cash_flow.active(account_id=account.id)).items
        if item.system_kind is CashFlowSystemKind.CREDIT_CYCLE
    ]
    assert refreshed[0].planned_amount_minor == 20_000
    voided = await TransactionService(session).void(repayment.id, repayment.version)
    assert [
        item.planned_amount_minor
        for item in (await cash_flow.active(account_id=account.id)).items
        if item.expected_date == date(2026, 8, 8)
    ] == [30_000]
    await TransactionService(session).restore(voided.id, voided.version)
    assert [
        item.planned_amount_minor
        for item in (await cash_flow.active(account_id=account.id)).items
        if item.expected_date == date(2026, 8, 8)
    ] == [20_000]


async def test_atomic_failure_rolls_back_purchase_and_schedule_change_rebinds(
    session: AsyncSession,
) -> None:
    account = await natural_credit(session, "白条")
    category = await expense_category(session)
    invalid_request = InstallmentPurchaseCreate(
        purchase=TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=10_000,
            occurred_at=datetime(2026, 7, 15, 4, tzinfo=UTC),
            title="应整体回滚",
            account_id=account.id,
            category_id=category.id,
        ),
        installment_count=3,
        total_fee_minor=300,
        fee_category_id=uuid4(),
        fee_occurred_at=datetime(2026, 7, 15, 5, tzinfo=UTC),
    )
    with pytest.raises(APIError):
        await InstallmentService(session).create_purchase(invalid_request, uuid4())
    assert (
        await session.scalar(
            select(func.count())
            .select_from(LedgerTransaction)
            .where(LedgerTransaction.title == "应整体回滚")
        )
        == 0
    )

    cutoff = await AccountService(session).create(
        AccountDraft(
            name="规则变更卡",
            kind=AccountKind.CREDIT,
            opening_balance_minor=0,
            credit_limit_minor=500_000,
            statement_day=10,
            due_day=20,
            cycle_mode=CreditCycleMode.STATEMENT_DAY_CUTOFF,
        )
    )
    purchase = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=12_345,
            occurred_at=datetime(2026, 7, 15, 4, tzinfo=UTC),
            title="待重算普通消费",
            account_id=cutoff.id,
            category_id=category.id,
        ),
        uuid4(),
    )
    assert purchase.credit_cycle_id is not None
    request = CreditScheduleChangeRequest(
        expected_version=cutoff.version,
        cycle_mode=CreditCycleMode.PREVIOUS_CALENDAR_MONTH,
        statement_day=1,
        due_day=8,
    )
    credit = CreditService(session)
    preview = await credit.preview_schedule_change(cutoff.id, request)
    assert preview.conflicts == []
    assert (preview.affected_cycle_count, preview.purchase_count) == (1, 1)
    unchanged = await AccountService(session).get(cutoff.id)
    assert unchanged.cycle_mode is CreditCycleMode.STATEMENT_DAY_CUTOFF

    applied = await credit.apply_schedule_change(cutoff.id, request)
    assert applied.conflicts == []
    changed_purchase = await TransactionService(session).get(purchase.id)
    assert changed_purchase.credit_cycle_id is not None
    cycle = await credit.get_cycle(changed_purchase.credit_cycle_id)
    assert (cycle.statement_date, cycle.due_date) == (date(2026, 8, 1), date(2026, 8, 8))
    item = next(
        value
        for value in (await CashFlowService(session).active(account_id=cutoff.id)).items
        if value.system_kind is CashFlowSystemKind.CREDIT_CYCLE
    )
    assert (item.expected_date, item.planned_amount_minor) == (date(2026, 8, 8), 12_345)
