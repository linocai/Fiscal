from collections.abc import AsyncIterator
from datetime import UTC, date, datetime
from os import environ
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p5_schemas import InstallmentActionRequest, InstallmentCreate
from fiscal_api.api.p6_schemas import (
    ReimbursementAllocationDraft,
    ReimbursementClaimDraft,
    ReimbursementPartyDraft,
    ReimbursementReceiptDraft,
)
from fiscal_api.api.p7_schemas import ReportLens
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import AccountKind, CategoryDirection, TransactionKind
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.installments import InstallmentService
from fiscal_api.services.reimbursements import ReimbursementService
from fiscal_api.services.reporting import ReportingService
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
                "TRUNCATE reimbursement_operations, reimbursement_receipt_revisions, "
                "reimbursement_claim_revisions, reimbursement_receipt_allocations, "
                "reimbursement_receipts, reimbursement_allocations, reimbursement_parties, "
                "reimbursement_claims, installment_plan_revisions, installment_ledger_links, "
                "installment_operations, installment_periods, installment_plans, "
                "transaction_revisions, postings, transactions, credit_cycles, categories, "
                "accounts CASCADE"
            )
        )
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


async def seed_reporting(session: AsyncSession):  # type: ignore[no-untyped-def]
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await accounts.create(
        AccountDraft(name="银行", kind=AccountKind.DEBIT, opening_balance_minor=20_000)
    )
    cash = await accounts.create(
        AccountDraft(name="现金", kind=AccountKind.CASH, opening_balance_minor=1_000)
    )
    credit = await accounts.create(
        AccountDraft(
            name="信用卡",
            kind=AccountKind.CREDIT,
            opening_balance_minor=0,
            credit_limit_minor=10_000,
            statement_day=10,
            due_day=22,
        )
    )
    root = await categories.create(
        CategoryDraft(
            name="生活",
            direction=CategoryDirection.EXPENSE,
            icon="cart",
            color_hex="#112233",
        )
    )
    child = await categories.create(
        CategoryDraft(
            name="餐饮",
            direction=CategoryDirection.EXPENSE,
            icon="fork.knife",
            color_hex="#334455",
            parent_id=root.id,
        )
    )
    income_category = await categories.create(
        CategoryDraft(
            name="工资",
            direction=CategoryDirection.INCOME,
            icon="banknote",
            color_hex="#556677",
        )
    )

    async def create(
        kind: TransactionKind,
        amount: int,
        occurred_at: str,
        account_id,
        *,
        category_id=None,
        destination_account_id=None,
        title: str,
        credit_cycle_id=None,
    ):  # type: ignore[no-untyped-def]
        return await ledger.create(
            TransactionDraft(
                kind=kind,
                amount_minor=amount,
                occurred_at=occurred_at,  # type: ignore[arg-type]
                title=title,
                account_id=account_id,
                destination_account_id=destination_account_id,
                category_id=category_id,
                credit_cycle_id=credit_cycle_id,
            ),
            uuid4(),
        )

    income = await create(
        TransactionKind.INCOME,
        5_000,
        "2026-07-01T00:00:00+08:00",
        bank.id,
        category_id=income_category.id,
        title="月初工资",
    )
    reimbursable = await create(
        TransactionKind.EXPENSE,
        1_000,
        "2026-07-02T12:00:00+08:00",
        bank.id,
        category_id=child.id,
        title="工作餐",
    )
    await create(
        TransactionKind.EXPENSE,
        200,
        "2026-07-03T12:00:00+08:00",
        cash.id,
        category_id=root.id,
        title="生活用品",
    )
    await create(
        TransactionKind.TRANSFER,
        300,
        "2026-07-04T12:00:00+08:00",
        bank.id,
        destination_account_id=cash.id,
        title="取现",
    )
    purchase = await create(
        TransactionKind.CREDIT_PURCHASE,
        2_000,
        "2026-07-10T12:00:00+08:00",
        credit.id,
        category_id=child.id,
        title="信用消费",
    )
    assert purchase.credit_cycle_id is not None
    await create(
        TransactionKind.REPAYMENT,
        500,
        "2026-07-11T12:00:00+08:00",
        bank.id,
        destination_account_id=credit.id,
        credit_cycle_id=purchase.credit_cycle_id,
        title="还款",
    )
    claim = await ReimbursementService(session).create(
        ReimbursementClaimDraft(
            title="工作餐报销",
            parties=[
                ReimbursementPartyDraft(
                    name="公司",
                    expected_date=date(2026, 7, 20),
                    allocations=[
                        ReimbursementAllocationDraft(
                            transaction_id=reimbursable.id,
                            amount_minor=600,
                        )
                    ],
                )
            ],
        ),
        uuid4(),
    )
    await ReimbursementService(session).lifecycle(claim.id, claim.version, "submit")
    return bank, cash, credit, root, child, income


async def test_reporting_lenses_overview_forecast_and_hierarchy(session: AsyncSession) -> None:
    bank, cash, credit, root, child, _income = await seed_reporting(session)
    reports = ReportingService(session)

    spending = await reports.spending(date_from=date(2026, 7, 1), date_to=date(2026, 7, 31))
    assert spending.meta.timezone == "Asia/Shanghai"
    assert len(spending.trend) == 31
    assert (
        spending.gross_consumption_minor,
        spending.merchant_refund_minor,
        spending.net_consumption_minor,
        spending.expected_reimbursement_minor,
        spending.received_reimbursement_minor,
        spending.personal_expected_minor,
        spending.personal_realized_minor,
    ) == (3_200, 0, 3_200, 600, 0, 2_600, 3_200)
    living = next(item for item in spending.categories if item.category_id == root.id)
    assert living.gross_consumption_minor == 3_200
    assert living.direct.gross_consumption_minor == 200
    assert living.children[0].category_id == child.id
    assert living.children[0].gross_consumption_minor == 3_000

    cash_flow = await reports.cash_flow(
        date_from=date(2026, 7, 1),
        date_to=date(2026, 7, 31),
        forecast_days=30,
        today=date(2026, 7, 15),
    )
    assert (cash_flow.inflow_minor, cash_flow.outflow_minor, cash_flow.net_minor) == (
        5_000,
        1_700,
        3_300,
    )
    assert (
        cash_flow.internal_transfer_inflow_minor,
        cash_flow.internal_transfer_outflow_minor,
    ) == (300, 300)
    bank_row = next(item for item in cash_flow.accounts if item.account_id == bank.id)
    cash_row = next(item for item in cash_flow.accounts if item.account_id == cash.id)
    assert bank_row.internal_transfer_outflow_minor == 300
    assert cash_row.internal_transfer_inflow_minor == 300
    assert cash_flow.forecast.exact_due_outflow_minor == 1_500
    assert cash_flow.forecast.expected_receipt_inflow_minor == 600
    assert {item.basis.value for item in cash_flow.forecast.events} == {
        "exact_due",
        "expected_receipt",
    }

    debt = await reports.debt(as_of=date(2026, 7, 15))
    assert debt.current_credit_debt_minor == 1_500
    assert debt.total_available_credit_minor == 8_500
    credit_row = next(item for item in debt.accounts if item.account_id == credit.id)
    assert credit_row.next_due_cycle is not None
    assert credit_row.next_due_cycle.remaining_minor == 1_500

    overview = await reports.overview(month="2026-07")
    assert overview.spending.model_dump() == {
        name: getattr(spending, name) for name in type(overview.spending).model_fields
    }
    assert overview.cash_flow.inflow_minor == cash_flow.inflow_minor
    assert overview.cash_flow.outflow_minor == cash_flow.outflow_minor
    assert overview.current_credit_debt_minor == debt.current_credit_debt_minor
    assert overview.reimbursement_outstanding_minor == 600
    assert len(overview.recent_transactions) <= 5


async def test_report_drill_down_pagination_filters_and_shanghai_edges(
    session: AsyncSession,
) -> None:
    bank, _cash, _credit, root, child, income = await seed_reporting(session)
    reports = ReportingService(session)
    spending = await reports.drill_down(
        lens=ReportLens.SPENDING,
        date_from=date(2026, 7, 1),
        date_to=date(2026, 7, 31),
        category_id=root.id,
        account_id=None,
        cursor=None,
        limit=2,
    )
    assert len(spending.items) == 2
    assert spending.next_cursor is not None
    second = await reports.drill_down(
        lens=ReportLens.SPENDING,
        date_from=date(2026, 7, 1),
        date_to=date(2026, 7, 31),
        category_id=root.id,
        account_id=None,
        cursor=spending.next_cursor,
        limit=2,
    )
    assert len(second.items) == 1
    assert {item.id for item in spending.items}.isdisjoint(item.id for item in second.items)
    assert {item.category_id for item in (*spending.items, *second.items)} == {root.id, child.id}

    bank_cash = await reports.drill_down(
        lens=ReportLens.CASH_FLOW,
        date_from=date(2026, 7, 1),
        date_to=date(2026, 7, 31),
        category_id=None,
        account_id=bank.id,
        cursor=None,
        limit=100,
    )
    assert income.id in {item.transaction_id for item in bank_cash.items}
    assert all(item.account_id == bank.id for item in bank_cash.items)
    transfer = next(item for item in bank_cash.items if item.internal_transfer)
    assert transfer.signed_amount_minor == -300

    with pytest.raises(APIError) as wrong_lens:
        await reports.drill_down(
            lens=ReportLens.CASH_FLOW,
            date_from=date(2026, 7, 1),
            date_to=date(2026, 7, 31),
            category_id=None,
            account_id=None,
            cursor=spending.next_cursor,
            limit=10,
        )
    assert wrong_lens.value.code == "invalid_report_cursor"


async def test_report_range_validation_and_future_window_edge(session: AsyncSession) -> None:
    reports = ReportingService(session)
    with pytest.raises(APIError) as incomplete:
        await reports.spending(date_from=date(2026, 7, 1), date_to=None)
    assert incomplete.value.code == "incomplete_report_range"
    with pytest.raises(APIError) as reversed_range:
        await reports.spending(date_from=date(2026, 7, 2), date_to=date(2026, 7, 1))
    assert reversed_range.value.code == "invalid_report_range"

    start, end = reports._bounds(date(2028, 2, 29), date(2028, 2, 29))
    assert start == datetime.fromisoformat("2028-02-28T16:00:00+00:00")
    assert end == datetime.fromisoformat("2028-02-29T16:00:00+00:00")


async def test_installment_schedule_is_not_double_debt_and_refunds_reattribute(
    session: AsyncSession,
) -> None:
    account = await AccountService(session).create(
        AccountDraft(
            name="分期卡",
            kind=AccountKind.CREDIT,
            opening_balance_minor=0,
            credit_limit_minor=1_000_000,
            statement_day=10,
            due_day=20,
        )
    )
    category = await CategoryService(session).create(
        CategoryDraft(
            name="电脑",
            direction=CategoryDirection.EXPENSE,
            icon="laptopcomputer",
            color_hex="#123456",
        )
    )
    purchase = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=329_900,
            occurred_at=datetime(2026, 7, 15, 0, tzinfo=UTC),
            title="Mac",
            account_id=account.id,
            category_id=category.id,
        ),
        uuid4(),
    )
    plan = await InstallmentService(session).create(
        InstallmentCreate(
            purchase_transaction_id=purchase.id,
            installment_count=6,
            total_fee_minor=10_000,
            fee_category_id=category.id,
            fee_occurred_at=datetime(2026, 7, 15, 1, tzinfo=UTC),
            start_statement_date=date(2026, 8, 10),
        ),
        uuid4(),
    )
    reports = ReportingService(session)
    debt = await reports.debt(as_of=date(2026, 7, 15))
    assert debt.current_credit_debt_minor == 339_900
    assert sum(item.total_scheduled_gross_minor for item in debt.installments) == 339_900

    before = await reports.spending(date_from=date(2026, 7, 15), date_to=date(2026, 7, 15))
    assert (before.gross_consumption_minor, before.net_consumption_minor) == (339_900, 339_900)
    await InstallmentService(session).cancel_future(
        plan.id,
        InstallmentActionRequest(
            expected_version=plan.version,
            occurred_at=datetime(2026, 7, 15, 2, tzinfo=UTC),
        ),
        uuid4(),
    )
    after = await reports.spending(date_from=date(2026, 7, 15), date_to=date(2026, 7, 15))
    assert after.gross_consumption_minor == 339_900
    assert after.merchant_refund_minor == 339_900
    assert after.net_consumption_minor == 0
    assert after.trend[0].merchant_refund_minor == 339_900
    assert (await reports.debt(as_of=date(2026, 7, 15))).current_credit_debt_minor == 0


async def test_partial_receipt_cancel_and_future_day_thirty_exclusion(
    session: AsyncSession,
) -> None:
    bank = await AccountService(session).create(
        AccountDraft(name="报销卡", kind=AccountKind.DEBIT, opening_balance_minor=20_000)
    )
    category = await CategoryService(session).create(
        CategoryDraft(
            name="差旅",
            direction=CategoryDirection.EXPENSE,
            icon="airplane",
            color_hex="#445566",
        )
    )
    ledger = TransactionService(session)
    expense = await ledger.create(
        TransactionDraft(
            kind=TransactionKind.EXPENSE,
            amount_minor=10_000,
            occurred_at="2026-07-15T08:00:00+08:00",  # type: ignore[arg-type]
            title="酒店",
            account_id=bank.id,
            category_id=category.id,
        ),
        uuid4(),
    )
    excluded_expense = await ledger.create(
        TransactionDraft(
            kind=TransactionKind.EXPENSE,
            amount_minor=100,
            occurred_at="2026-07-15T09:00:00+08:00",  # type: ignore[arg-type]
            title="边界",
            account_id=bank.id,
            category_id=category.id,
        ),
        uuid4(),
    )
    reimbursements = ReimbursementService(session)
    claim = await reimbursements.create(
        ReimbursementClaimDraft(
            title="部分到账",
            parties=[
                ReimbursementPartyDraft(
                    name="公司",
                    expected_date=date(2026, 7, 15),
                    allocations=[
                        ReimbursementAllocationDraft(transaction_id=expense.id, amount_minor=8_000)
                    ],
                )
            ],
        ),
        uuid4(),
    )
    claim = await reimbursements.lifecycle(claim.id, claim.version, "submit")
    await reimbursements.create_receipt(
        claim.id,
        ReimbursementReceiptDraft(
            expected_claim_version=claim.version,
            party_id=claim.parties[0].id,
            amount_minor=3_000,
            received_at=datetime(2026, 7, 15, 8, tzinfo=UTC),
            destination_account_id=bank.id,
            title="首笔回款",
        ),
        uuid4(),
    )
    boundary = await reimbursements.create(
        ReimbursementClaimDraft(
            title="第三十天",
            parties=[
                ReimbursementPartyDraft(
                    name="客户",
                    expected_date=date(2026, 8, 14),
                    allocations=[
                        ReimbursementAllocationDraft(
                            transaction_id=excluded_expense.id, amount_minor=100
                        )
                    ],
                )
            ],
        ),
        uuid4(),
    )
    await reimbursements.lifecycle(boundary.id, boundary.version, "submit")

    reports = ReportingService(session)
    spending = await reports.spending(date_from=date(2026, 7, 15), date_to=date(2026, 7, 15))
    assert spending.expected_reimbursement_minor == 8_100
    assert spending.received_reimbursement_minor == 3_000
    cash = await reports.cash_flow(
        date_from=date(2026, 7, 15),
        date_to=date(2026, 7, 15),
        forecast_days=30,
        today=date(2026, 7, 15),
    )
    assert cash.inflow_minor == 3_000
    assert cash.outflow_minor == 10_100
    assert cash.forecast.expected_receipt_inflow_minor == 5_000
    assert all(item.date != date(2026, 8, 14) for item in cash.forecast.events)

    refreshed = await reimbursements.get(claim.id)
    await reimbursements.lifecycle(claim.id, refreshed.version, "cancel_outstanding")
    cancelled = await reports.spending(date_from=date(2026, 7, 15), date_to=date(2026, 7, 15))
    assert cancelled.expected_reimbursement_minor == 3_100
    assert cancelled.received_reimbursement_minor == 3_000
    assert cancelled.personal_expected_minor == 7_000
    assert cancelled.personal_realized_minor == 7_100
