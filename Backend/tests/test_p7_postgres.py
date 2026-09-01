import base64
import json
from collections.abc import AsyncIterator
from datetime import UTC, date, datetime
from os import environ
from uuid import uuid4

import pytest
import pytest_asyncio
from fastapi.testclient import TestClient
from sqlalchemy import event, text, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft, CategoryPatch
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p5_schemas import InstallmentActionRequest, InstallmentCreate
from fiscal_api.api.p6_schemas import (
    ReimbursementAllocationDraft,
    ReimbursementClaimDraft,
    ReimbursementPartyDraft,
    ReimbursementReceiptDraft,
)
from fiscal_api.api.p7_schemas import (
    FactsDrillDownScopeType,
    KnownFutureCertainty,
    KnownFutureDirection,
    KnownFutureSourceType,
    ReportLens,
)
from fiscal_api.api.p13_schemas import CashFlowDraft
from fiscal_api.core.config import Settings
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import (
    Account,
    AccountKind,
    CashFlowDirection,
    CashFlowRecurrence,
    CategoryDirection,
    DataRevision,
    LedgerTransaction,
    Posting,
    ReimbursementAllocation,
    ReimbursementClaim,
    ReimbursementParty,
    ReimbursementReceipt,
    ReimbursementReceiptAllocation,
    StatementImport,
    TransactionKind,
)
from fiscal_api.main import create_app
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.cash_flow import CashFlowService
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.common import INT64_MAX
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
    # Overview cash flow is the independent future-action projection, not the historical month.
    # P18 keeps that legacy field compatible while adding the credit-only due aggregation below.
    assert overview.current_credit_debt_minor == debt.current_credit_debt_minor
    assert overview.monthly_income_minor == 5_000
    assert [item.category_id for item in overview.top_spending_categories] == [root.id]
    assert overview.reimbursement_outstanding_minor == 600
    assert len(overview.recent_transactions) <= 10
    assert len(overview.credit_due_events) == 1
    credit_due = overview.credit_due_events[0]
    assert (credit_due.account_id, credit_due.due_date, credit_due.remaining_minor) == (
        credit.id,
        date(2026, 7, 22),
        1_500,
    )
    assert len(credit_due.cycle_ids) == 1


async def test_facts_are_recomputable_and_project_each_credit_cycle_once(
    session: AsyncSession,
) -> None:
    _bank, _cash, _credit, _root, _child, _income = await seed_reporting(session)
    cash_flow = CashFlowService(session)
    confirmed = (
        await cash_flow.create(
            CashFlowDraft(
                title="已确认房租",
                direction=CashFlowDirection.OUTFLOW,
                planned_amount_minor=700,
                expected_date=date(2026, 7, 16),
            ),
            uuid4(),
        )
    ).items[0]
    assert confirmed.manual_item_id is not None
    await cash_flow.confirm(confirmed.manual_item_id, confirmed.version)
    await cash_flow.create(
        CashFlowDraft(
            title="预计奖金",
            direction=CashFlowDirection.INFLOW,
            planned_amount_minor=200,
            expected_date=date(2026, 7, 17),
        ),
        uuid4(),
    )
    await cash_flow.create(
        CashFlowDraft(
            title="预计水电",
            direction=CashFlowDirection.OUTFLOW,
            planned_amount_minor=500,
            expected_date=date(2026, 7, 18),
        ),
        uuid4(),
    )
    await cash_flow.create(
        CashFlowDraft(
            title="每月订阅",
            direction=CashFlowDirection.OUTFLOW,
            planned_amount_minor=300,
            expected_date=date(2026, 7, 19),
            recurrence=CashFlowRecurrence.MONTHLY,
            recurrence_end_date=date(2026, 7, 19),
        ),
        uuid4(),
    )

    reports = ReportingService(session, facts_today=date(2026, 7, 15))
    facts = await reports.facts(window_days=30)

    assert facts.meta.timezone == "Asia/Shanghai"
    assert facts.meta.currency == "CNY"
    assert facts.meta.data_revision == 0
    assert facts.window.date_from == date(2026, 7, 15)
    assert facts.window.date_to == date(2026, 8, 13)
    assert facts.cash.current_balance_minor == 24_300
    assert facts.credit.current_debt_minor == 1_500
    assert facts.reimbursements.outstanding_minor == 600
    assert facts.completeness.unresolved_import_count == 0
    assert facts.completeness.failed_import_count == 0
    assert facts.completeness.uncategorized_transaction_count == 0
    assert facts.completeness.uncategorized_transaction_amount_minor == 0
    assert "open_reconciliation_difference_count" not in facts.completeness.model_dump()
    assert "last_reconciled_at" not in facts.completeness.model_dump()
    assert facts.completeness.scope is not None
    # The service exposes the current public schema.  Legacy route serialization
    # adds its transition-only keys after this model boundary.
    period_report = await reports.monthly_report(period="2026-07")
    assert "open_reconciliation_difference_count" not in period_report.completeness.model_dump()
    assert facts.future.model_dump() == {
        "exact_due_outflow_minor": 1_500,
        "confirmed_outflow_minor": 700,
        "expected_outflow_minor": 500,
        "scheduled_outflow_minor": 300,
        "confirmed_inflow_minor": 0,
        "expected_inflow_minor": 800,
        "scheduled_inflow_minor": 0,
        "after_confirmed_outflow_minor": 22_100,
    }
    exact_due = [
        item
        for item in facts.known_future_events
        if item.source_type is KnownFutureSourceType.CREDIT_CYCLE
    ]
    assert len(exact_due) == 1
    assert exact_due[0].certainty is KnownFutureCertainty.EXACT_DUE
    assert exact_due[0].direction is KnownFutureDirection.OUTFLOW
    assert exact_due[0].amount_minor == facts.future.exact_due_outflow_minor
    assert exact_due[0].deep_link.endswith(str(exact_due[0].cycle_id))
    assert all(
        item.amount_minor > 0 and item.deep_link.startswith("fiscal://")
        for item in facts.known_future_events
    )
    assert {item.certainty for item in facts.known_future_events} == {
        KnownFutureCertainty.EXACT_DUE,
        KnownFutureCertainty.CONFIRMED,
        KnownFutureCertainty.EXPECTED,
        KnownFutureCertainty.SCHEDULED,
    }

    assert facts.cash.scope is not None
    assert facts.credit.scope is not None
    assert facts.reimbursements.scope is not None
    assert {
        facts.cash.scope.scope_type,
        facts.credit.scope.scope_type,
        facts.reimbursements.scope.scope_type,
        facts.completeness.scope.scope_type,
    } == {
        FactsDrillDownScopeType.CASH_ACCOUNTS,
        FactsDrillDownScopeType.CREDIT_CYCLES,
        FactsDrillDownScopeType.REIMBURSEMENT_OUTSTANDING,
        FactsDrillDownScopeType.COMPLETENESS_ISSUES,
    }
    assert all(
        scope.schema_version == "1"
        and scope.expected_data_revision == facts.meta.data_revision
        and "expected_data_revision=0" in scope.read_path
        for scope in (
            facts.cash.scope,
            facts.credit.scope,
            facts.reimbursements.scope,
            facts.completeness.scope,
        )
    )

    cash_page = await reports.facts_drill_down(
        scope_type=FactsDrillDownScopeType.CASH_ACCOUNTS,
        expected_data_revision=facts.meta.data_revision,
        cursor=None,
        limit=1,
    )
    assert cash_page.next_cursor is not None
    cash_tail = await reports.facts_drill_down(
        scope_type=FactsDrillDownScopeType.CASH_ACCOUNTS,
        expected_data_revision=facts.meta.data_revision,
        cursor=cash_page.next_cursor,
        limit=50,
    )
    cash_items = [
        item for item in [*cash_page.items, *cash_tail.items] if item.item_type == "cash_account"
    ]
    assert len(cash_items) == len(cash_page.items) + len(cash_tail.items)
    assert (
        sum(item.current_balance_minor for item in cash_items) == facts.cash.current_balance_minor
    )
    assert all(item.read_path.startswith("/api/v1/accounts/") for item in cash_items)

    credit_page = await reports.facts_drill_down(
        scope_type=FactsDrillDownScopeType.CREDIT_CYCLES,
        expected_data_revision=facts.meta.data_revision,
        cursor=None,
        limit=50,
    )
    credit_items = [item for item in credit_page.items if item.item_type == "credit_cycle"]
    assert len(credit_items) == len(credit_page.items)
    assert sum(item.remaining_minor for item in credit_items) == facts.credit.current_debt_minor
    assert all(item.read_path.startswith("/api/v1/credit-cycles/") for item in credit_items)

    reimbursement_page = await reports.facts_drill_down(
        scope_type=FactsDrillDownScopeType.REIMBURSEMENT_OUTSTANDING,
        expected_data_revision=facts.meta.data_revision,
        cursor=None,
        limit=50,
    )
    reimbursement_items = [
        item for item in reimbursement_page.items if item.item_type == "reimbursement_outstanding"
    ]
    assert len(reimbursement_items) == len(reimbursement_page.items)
    assert (
        sum(item.outstanding_minor for item in reimbursement_items)
        == facts.reimbursements.outstanding_minor
    )
    assert all(
        item.read_path.startswith("/api/v1/reimbursement-claims/") for item in reimbursement_items
    )

    completeness_page = await reports.facts_drill_down(
        scope_type=FactsDrillDownScopeType.COMPLETENESS_ISSUES,
        expected_data_revision=facts.meta.data_revision,
        cursor=None,
        limit=50,
    )
    assert completeness_page.items == []
    with pytest.raises(APIError) as malformed_cursor:
        await reports.facts_drill_down(
            scope_type=FactsDrillDownScopeType.CASH_ACCOUNTS,
            expected_data_revision=facts.meta.data_revision,
            cursor="not-a-facts-cursor",
            limit=50,
        )
    assert malformed_cursor.value.code == "invalid_facts_scope_cursor"
    with pytest.raises(APIError) as stale_scope:
        await reports.facts_drill_down(
            scope_type=FactsDrillDownScopeType.CASH_ACCOUNTS,
            expected_data_revision=facts.meta.data_revision + 1,
            cursor=None,
            limit=50,
        )
    assert stale_scope.value.code == "report_facts_scope_changed"


async def test_future_events_uses_bounded_merge_keyset_and_account_filter(
    session: AsyncSession,
) -> None:
    bank, _cash, credit, _root, _child, _income = await seed_reporting(session)
    reports = ReportingService(session, facts_today=date(2026, 7, 15))

    first = await reports.future_events(window_days=30, account_id=None, cursor=None, limit=1)
    assert len(first.items) == 1
    assert first.items[0].source_type is KnownFutureSourceType.REIMBURSEMENT_PARTY
    assert first.next_cursor is not None
    second = await reports.future_events(
        window_days=30, account_id=None, cursor=first.next_cursor, limit=1
    )
    assert [item.source_type for item in second.items] == [KnownFutureSourceType.CREDIT_CYCLE]
    assert {item.source_id for item in [*first.items, *second.items]} == {
        first.items[0].source_id,
        second.items[0].source_id,
    }
    assert second.next_cursor is None

    filtered = await reports.future_events(
        window_days=30, account_id=credit.id, cursor=None, limit=20
    )
    assert [item.source_type for item in filtered.items] == [KnownFutureSourceType.CREDIT_CYCLE]
    assert filtered.items[0].account_id == credit.id
    assert all(item.account_id != bank.id for item in filtered.items)

    await session.execute(update(DataRevision).where(DataRevision.id == 1).values(revision=1))
    await session.commit()
    with pytest.raises(APIError) as stale:
        await reports.future_events(
            window_days=30, account_id=None, cursor=first.next_cursor, limit=1
        )
    assert stale.value.code == "future_events_scope_changed"


async def test_future_reimbursement_page_aggregates_receipts_without_join_multiplication(
    session: AsyncSession,
) -> None:
    bank = await AccountService(session).create(
        AccountDraft(name="未来报销账户", kind=AccountKind.DEBIT, opening_balance_minor=50_000)
    )
    category = await CategoryService(session).create(
        CategoryDraft(
            name="未来报销分类",
            direction=CategoryDirection.EXPENSE,
            icon="briefcase",
            color_hex="#445566",
        )
    )
    ledger = TransactionService(session)

    async def expense(amount_minor: int, title: str):  # type: ignore[no-untyped-def]
        return await ledger.create(
            TransactionDraft(
                kind=TransactionKind.EXPENSE,
                amount_minor=amount_minor,
                occurred_at=datetime(2026, 7, 15, 1, tzinfo=UTC),
                title=title,
                account_id=bank.id,
                category_id=category.id,
            ),
            uuid4(),
        )

    alpha_one, alpha_two, beta = (
        await expense(8_000, "甲方第一笔"),
        await expense(2_000, "甲方第二笔"),
        await expense(4_000, "乙方费用"),
    )
    reimbursements = ReimbursementService(session)
    claim = await reimbursements.create(
        ReimbursementClaimDraft(
            title="多笔回款聚合",
            parties=[
                ReimbursementPartyDraft(
                    name="甲方",
                    expected_date=date(2026, 7, 16),
                    allocations=[
                        ReimbursementAllocationDraft(
                            transaction_id=alpha_one.id, amount_minor=8_000
                        ),
                        ReimbursementAllocationDraft(
                            transaction_id=alpha_two.id, amount_minor=2_000
                        ),
                    ],
                ),
                ReimbursementPartyDraft(
                    name="乙方",
                    expected_date=date(2026, 7, 17),
                    allocations=[
                        ReimbursementAllocationDraft(transaction_id=beta.id, amount_minor=4_000)
                    ],
                ),
            ],
        ),
        uuid4(),
    )
    claim = await reimbursements.lifecycle(claim.id, claim.version, "submit")

    async def receipt(party_id, amount_minor: int, title: str):  # type: ignore[no-untyped-def]
        nonlocal claim
        response = await reimbursements.create_receipt(
            claim.id,
            ReimbursementReceiptDraft(
                expected_claim_version=claim.version,
                party_id=party_id,
                amount_minor=amount_minor,
                received_at=datetime(2026, 7, 15, 2, tzinfo=UTC),
                destination_account_id=bank.id,
                title=title,
            ),
            uuid4(),
        )
        claim = await reimbursements.get(claim.id)
        return response

    alpha_id, beta_id = claim.parties[0].id, claim.parties[1].id
    alpha_first = await receipt(alpha_id, 3_000, "甲方首笔")
    alpha_second = await receipt(alpha_id, 2_000, "甲方第二笔")
    assert alpha_first.allocations[0].allocation_id == alpha_second.allocations[0].allocation_id
    voided_beta = await receipt(beta_id, 1_000, "乙方作废回款")
    await reimbursements.receipt_lifecycle(
        voided_beta.id, claim.version, voided_beta.version, "void"
    )
    claim = await reimbursements.get(claim.id)
    reports = ReportingService(session, facts_today=date(2026, 7, 15))
    assert (await reports.facts(window_days=7)).reimbursements.outstanding_minor == 9_000

    # These receipt-heavy historical parties are deliberately outside the
    # seven-day window. The future query must not bring their allocation rows
    # into either aggregate before it applies the candidate-party CTE.
    historical_allocations: list[ReimbursementAllocation] = []
    historical_transactions: list[LedgerTransaction] = []
    historical_receipts: list[ReimbursementReceipt] = []
    historical_receipt_allocations: list[ReimbursementReceiptAllocation] = []
    for index in range(80):
        historical_claim_id = uuid4()
        historical_party_id = uuid4()
        historical_allocation_id = uuid4()
        historical_transaction_id = uuid4()
        historical_receipt_id = uuid4()
        historical_receipt_allocation_id = uuid4()
        session.add_all(
            [
                ReimbursementClaim(
                    id=historical_claim_id,
                    title=f"历史噪声 {index}",
                    submitted_at=datetime(2020, 1, 1, tzinfo=UTC),
                    create_idempotency_key=uuid4(),
                    create_request_hash="0" * 64,
                ),
                ReimbursementParty(
                    id=historical_party_id,
                    claim_id=historical_claim_id,
                    name=f"历史方 {index}",
                    expected_date=date(2020, 1, 1),
                    position=0,
                ),
            ]
        )
        historical_allocations.append(
            ReimbursementAllocation(
                id=historical_allocation_id,
                claim_id=historical_claim_id,
                party_id=historical_party_id,
                transaction_id=alpha_one.id,
                amount_minor=8_000,
                position=0,
            )
        )
        historical_transactions.append(
            LedgerTransaction(
                id=historical_transaction_id,
                kind=TransactionKind.REIMBURSEMENT_RECEIPT,
                occurred_at=datetime(2020, 1, 1, tzinfo=UTC),
                title=f"历史回款 {index}",
                source="system",
                idempotency_key=uuid4(),
                request_hash="0" * 64,
            )
        )
        historical_receipts.append(
            ReimbursementReceipt(
                id=historical_receipt_id,
                claim_id=historical_claim_id,
                party_id=historical_party_id,
                transaction_id=historical_transaction_id,
            )
        )
        historical_receipt_allocations.append(
            ReimbursementReceiptAllocation(
                id=historical_receipt_allocation_id,
                receipt_id=historical_receipt_id,
                allocation_id=historical_allocation_id,
                amount_minor=1_000,
                position=0,
            )
        )
    await session.flush()
    session.add_all([*historical_allocations, *historical_transactions])
    await session.flush()
    session.add_all(historical_receipts)
    await session.flush()
    session.add_all(historical_receipt_allocations)
    await session.flush()

    engine = session.bind
    assert engine is not None
    statements: list[tuple[str, object]] = []

    def counted(
        _conn: object,
        _cursor: object,
        statement: str,
        parameters: object,
        *_args: object,
    ) -> None:
        statements.append((statement, parameters))

    event.listen(engine.sync_engine, "before_cursor_execute", counted)
    try:
        first = await reports.future_events(window_days=7, account_id=None, cursor=None, limit=1)
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", counted)
    second = await reports.future_events(
        window_days=7, account_id=None, cursor=first.next_cursor, limit=1
    )
    reimbursement_items = [*first.items, *second.items]
    assert [(item.party_id, item.amount_minor) for item in reimbursement_items] == [
        (alpha_id, 5_000),
        (beta_id, 4_000),
    ]
    assert sum(item.amount_minor for item in reimbursement_items) == 9_000
    assert len(statements) <= 6
    assert any(
        "reimbursement_allocations" in statement
        and "LIMIT" in statement.upper()
        and 2 in parameters
        for statement, parameters in statements
    )
    reimbursement_sql = next(
        statement.lower()
        for statement, _parameters in statements
        if "reimbursement_allocations" in statement
    )
    assert "future_reimbursement_candidates as" in reimbursement_sql
    assert reimbursement_sql.count("join future_reimbursement_candidates") == 2
    await receipt(alpha_id, 5_000, "甲方结清")
    settled_alpha = await reports.future_events(
        window_days=7, account_id=None, cursor=None, limit=10
    )
    assert [(item.party_id, item.amount_minor) for item in settled_alpha.items] == [
        (beta_id, 4_000)
    ]


async def test_facts_completeness_separates_pending_and_failed_imports(
    session: AsyncSession,
) -> None:
    session.add_all(
        [
            StatementImport(
                document_sha256=uuid4().hex * 2,
                byte_size=1,
                page_count=1,
                mime_type="application/pdf",
                display_name="statement.pdf",
                status="review_required",
            ),
            StatementImport(
                document_sha256=uuid4().hex * 2,
                byte_size=1,
                page_count=1,
                mime_type="application/pdf",
                display_name="statement.pdf",
                status="failed",
            ),
        ]
    )
    await session.commit()

    reports = ReportingService(session, facts_today=date(2026, 7, 15))
    facts = await reports.facts(window_days=30)

    assert facts.completeness.unresolved_import_count == 1
    assert facts.completeness.failed_import_count == 1
    assert facts.completeness.scope is not None
    completeness = await reports.facts_drill_down(
        scope_type=FactsDrillDownScopeType.COMPLETENESS_ISSUES,
        expected_data_revision=facts.meta.data_revision,
        cursor=None,
        limit=50,
    )
    issue_counts = {item.issue_type.value: item.count for item in completeness.items}
    assert issue_counts == {"unresolved_imports": 1, "failed_imports": 1}


async def test_facts_drill_down_does_not_read_full_facts_snapshot(
    session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    await seed_reporting(session)
    reports = ReportingService(session, facts_today=date(2026, 7, 15))
    facts = await reports.facts(window_days=30)

    async def full_snapshot_must_not_run(*_args: object, **_kwargs: object) -> object:
        raise AssertionError("facts drill-down must use its own bounded repository path")

    monkeypatch.setattr(reports, "_facts_snapshot", full_snapshot_must_not_run)
    scopes = (
        (FactsDrillDownScopeType.CASH_ACCOUNTS, facts.cash.scope),
        (FactsDrillDownScopeType.CREDIT_CYCLES, facts.credit.scope),
        (FactsDrillDownScopeType.REIMBURSEMENT_OUTSTANDING, facts.reimbursements.scope),
        (FactsDrillDownScopeType.COMPLETENESS_ISSUES, facts.completeness.scope),
    )
    for scope_type, scope in scopes:
        assert scope is not None
        page = await reports.facts_drill_down(
            scope_type=scope_type,
            expected_data_revision=scope.expected_data_revision,
            cursor=None,
            limit=1,
        )
        assert page.scope == scope


async def test_facts_cash_scope_uses_keyset_limit_for_hundreds_of_accounts(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    for index in range(220):
        await accounts.create(
            AccountDraft(
                name=f"P32 大数据账户 {index}",
                kind=AccountKind.DEBIT,
                opening_balance_minor=index + 1,
            )
        )

    reports = ReportingService(session, facts_today=date(2026, 7, 15))
    facts = await reports.facts(window_days=30)
    engine = session.bind
    assert engine is not None
    session.expunge_all()
    statements: list[tuple[str, object]] = []

    def counted(
        _conn: object,
        _cursor: object,
        statement: str,
        parameters: object,
        *_args: object,
    ) -> None:
        statements.append((statement, parameters))

    event.listen(engine.sync_engine, "before_cursor_execute", counted)
    try:
        page = await reports.facts_drill_down(
            scope_type=FactsDrillDownScopeType.CASH_ACCOUNTS,
            expected_data_revision=facts.meta.data_revision,
            cursor=None,
            limit=25,
        )
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", counted)
    assert len(page.items) == 25
    assert page.next_cursor is not None
    # The account result set is exactly one keyset page, rather than a complete
    # snapshot being materialized and sliced in memory.
    assert sum(isinstance(item, Account) for item in session.identity_map.values()) <= 26
    assert any(
        "LIMIT" in statement.upper() and 26 in parameters for statement, parameters in statements
    )

    cash_items = list(page.items)
    identifiers = [item.account_id for item in cash_items]
    cursor = page.next_cursor
    while cursor is not None:
        tail = await reports.facts_drill_down(
            scope_type=FactsDrillDownScopeType.CASH_ACCOUNTS,
            expected_data_revision=facts.meta.data_revision,
            cursor=cursor,
            limit=25,
        )
        identifiers.extend(item.account_id for item in tail.items)
        cash_items.extend(tail.items)
        cursor = tail.next_cursor
    assert len(identifiers) == 220
    assert len(set(identifiers)) == 220
    assert (
        sum(item.current_balance_minor for item in cash_items) == facts.cash.current_balance_minor
    )


async def test_facts_cash_aggregate_overflow_is_a_stable_domain_error(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    for index in range(2):
        await accounts.create(
            AccountDraft(
                name=f"P32 cash overflow {index}",
                kind=AccountKind.DEBIT,
                opening_balance_minor=INT64_MAX,
            )
        )

    with pytest.raises(APIError) as error:
        await ReportingService(session, facts_today=date(2026, 7, 15)).facts(window_days=30)
    assert error.value.code == "derived_amount_out_of_range"


async def test_facts_reimbursement_aggregate_overflow_is_a_stable_domain_error(
    session: AsyncSession,
) -> None:
    category = await CategoryService(session).create(
        CategoryDraft(
            name="P32 报销溢出分类",
            direction=CategoryDirection.EXPENSE,
            icon="tag",
            color_hex="#112233",
        )
    )
    source_ids = []
    for index in range(2):
        account = await AccountService(session).create(
            AccountDraft(
                name=f"P32 报销溢出账户 {index}",
                kind=AccountKind.DEBIT,
                opening_balance_minor=INT64_MAX,
            )
        )
        transaction_id = uuid4()
        session.add(
            LedgerTransaction(
                id=transaction_id,
                kind=TransactionKind.EXPENSE.value,
                occurred_at=datetime(2026, 7, 15, 4, tzinfo=UTC),
                title=f"P32 报销溢出支出 {index}",
                note=None,
                category_id=category.id,
                credit_cycle_id=None,
                source="manual",
                idempotency_key=uuid4(),
                request_hash="0" * 64,
                version=1,
                voided_at=None,
            )
        )
        await session.flush()
        session.add(
            Posting(
                transaction_id=transaction_id,
                account_id=account.id,
                role="account",
                amount_minor=-INT64_MAX,
                position=0,
            )
        )
        source_ids.append(transaction_id)
    # These are valid PostgreSQL bigint rows. Direct insertion bypasses the
    # write-side aggregate guard to exercise the read-side legacy-data boundary.
    for index, transaction_id in enumerate(source_ids):
        claim_id = uuid4()
        party_id = uuid4()
        claim = ReimbursementClaim(
            id=claim_id,
            title=f"P32 报销溢出单 {index}",
            note=None,
            submitted_at=datetime(2026, 7, 15, tzinfo=UTC),
            cancelled_at=None,
            voided_at=None,
            archived_at=None,
            create_idempotency_key=uuid4(),
            create_request_hash="0" * 64,
        )
        party = ReimbursementParty(
            id=party_id,
            claim_id=claim_id,
            name=f"P32 主体 {index}",
            expected_date=None,
            note=None,
            position=0,
        )
        session.add_all([claim, party])
        await session.flush()
        allocation = ReimbursementAllocation(
            claim_id=claim_id,
            party_id=party_id,
            transaction_id=transaction_id,
            amount_minor=INT64_MAX,
            position=0,
        )
        session.add(allocation)
    await session.commit()

    with pytest.raises(APIError) as error:
        await ReportingService(session).repository.facts_reimbursement_total()
    assert error.value.code == "derived_amount_out_of_range"


async def test_facts_uncategorized_aggregate_overflow_is_a_stable_domain_error(
    session: AsyncSession,
) -> None:
    transactions = TransactionService(session)
    for index in range(2):
        account = await AccountService(session).create(
            AccountDraft(
                name=f"P32 未分类溢出账户 {index}",
                kind=AccountKind.DEBIT,
                opening_balance_minor=INT64_MAX,
            )
        )
        await transactions.create(
            TransactionDraft(
                kind=TransactionKind.EXPENSE,
                amount_minor=INT64_MAX,
                occurred_at="2026-07-15T12:00:00+08:00",
                title=f"P32 未分类溢出支出 {index}",
                account_id=account.id,
            ),
            uuid4(),
        )

    with pytest.raises(APIError) as error:
        await ReportingService(session)._completeness_facts()  # pyright: ignore[reportPrivateUsage]
    assert error.value.code == "derived_amount_out_of_range"


@pytest.mark.parametrize(
    ("field", "value", "expected_revision"),
    [
        ("v", True, 0),
        ("v", False, 0),
        ("v", 1.0, 0),
        ("v", [], 0),
        ("v", None, 0),
        ("schema_version", True, 0),
        ("schema_version", 1.0, 0),
        ("schema_version", [], 0),
        ("schema_version", None, 0),
        ("scope", True, 0),
        ("scope", 1.0, 0),
        ("scope", [], 0),
        ("scope", None, 0),
        ("revision", True, 1),
        ("revision", False, 0),
        ("revision", 1.0, 1),
        ("revision", [], 0),
        ("revision", None, 0),
        ("filter", True, 0),
        ("filter", 1.0, 0),
        ("filter", [], 0),
        ("filter", None, 0),
        ("sort", True, 0),
        ("sort", 1.0, 0),
        ("sort", [], 0),
        ("sort", None, 0),
        ("key", True, 0),
        ("key", 1.0, 0),
        ("key", [], 0),
        ("key", None, 0),
    ],
)
async def test_facts_scope_cursor_rejects_wrong_payload_types(
    session: AsyncSession, field: str, value: object, expected_revision: int
) -> None:
    report = ReportingService(session, facts_today=date(2026, 7, 15))
    payload: dict[str, object] = {
        "v": 1,
        "schema_version": "1",
        "scope": "cash_accounts",
        "revision": expected_revision,
        "filter": "none",
        "sort": "cash_accounts:v1",
        "key": "0:00000000-0000-0000-0000-000000000000",
    }
    payload[field] = value
    encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    with pytest.raises(APIError) as error:
        await report.facts_drill_down(
            scope_type=FactsDrillDownScopeType.CASH_ACCOUNTS,
            expected_data_revision=expected_revision,
            cursor=encoded,
            limit=1,
        )
    assert error.value.code == "invalid_facts_scope_cursor"


async def test_facts_scope_cursor_is_bound_to_its_snapshot_revision(
    session: AsyncSession,
) -> None:
    report = ReportingService(session, facts_today=date(2026, 7, 15))
    cursor = report._encode_facts_scope_cursor(  # pyright: ignore[reportPrivateUsage]
        FactsDrillDownScopeType.CASH_ACCOUNTS, 0, "0:00000000-0000-0000-0000-000000000000"
    )
    with pytest.raises(APIError) as error:
        await report.facts_drill_down(
            scope_type=FactsDrillDownScopeType.CASH_ACCOUNTS,
            expected_data_revision=1,
            cursor=cursor,
            limit=1,
        )
    assert error.value.code == "invalid_facts_scope_cursor"


async def test_facts_scope_cursor_rejects_wrong_sort_fingerprint(
    session: AsyncSession,
) -> None:
    report = ReportingService(session, facts_today=date(2026, 7, 15))
    payload = {
        "v": 1,
        "schema_version": "1",
        "scope": "cash_accounts",
        "revision": 0,
        "filter": "none",
        "sort": "credit_cycles:v1",
        "key": "0:00000000-0000-0000-0000-000000000000",
    }
    cursor = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    with pytest.raises(APIError) as error:
        await report.facts_drill_down(
            scope_type=FactsDrillDownScopeType.CASH_ACCOUNTS,
            expected_data_revision=0,
            cursor=cursor,
            limit=1,
        )
    assert error.value.code == "invalid_facts_scope_cursor"


async def test_facts_scope_cursor_does_not_hide_unexpected_decoder_failures(
    session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    report = ReportingService(session, facts_today=date(2026, 7, 15))

    def broken_decoder(_value: str) -> bytes:
        raise RuntimeError("decoder unavailable")

    monkeypatch.setattr("fiscal_api.services.reporting.base64.urlsafe_b64decode", broken_decoder)
    with pytest.raises(RuntimeError, match="decoder unavailable"):
        await report.facts_drill_down(
            scope_type=FactsDrillDownScopeType.CASH_ACCOUNTS,
            expected_data_revision=0,
            cursor="opaque",
            limit=1,
        )


async def test_facts_retry_reloads_domain_rows_after_a_concurrent_formal_write(
    session: AsyncSession,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    initial = await AccountService(session).create(
        AccountDraft(name="初始账户", kind=AccountKind.DEBIT, opening_balance_minor=100)
    )
    service = ReportingService(session, facts_today=date(2026, 7, 15))
    original_data_revision = service._data_revision
    calls = 0

    async def revision_with_interleaved_write() -> int:
        nonlocal calls
        calls += 1
        if calls == 2:
            assert TEST_DATABASE_URL is not None

            async def ready() -> None:
                return None

            app = create_app(
                settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
                readiness_check=ready,
            )
            with TestClient(app) as client:
                response = client.patch(
                    f"/api/v1/accounts/{initial.id}",
                    headers={"Authorization": "Bearer p30a-concurrent-writer"},
                    json={"expected_version": initial.version, "opening_balance_minor": 400},
                )
                revision = client.get(
                    "/api/v1/data-revision",
                    headers={"Authorization": "Bearer p30a-concurrent-writer"},
                )
            assert response.status_code == 200, response.text
            assert revision.json()["revision"] == 1
        return await original_data_revision()

    monkeypatch.setattr(service, "_data_revision", revision_with_interleaved_write)
    facts = await service.facts(window_days=30)

    assert calls == 4
    assert facts.meta.data_revision == 1
    assert facts.cash.current_balance_minor == 400


async def test_balancing_category_is_excluded_from_every_report_caliber(
    session: AsyncSession,
) -> None:
    bank, _cash, _credit, _root, _child, _income = await seed_reporting(session)
    categories = CategoryService(session)
    balancing = await categories.create(
        CategoryDraft(
            name="平账",
            direction=CategoryDirection.EXPENSE,
            icon="equal.circle",
            color_hex="#777777",
            is_balance_adjustment=True,
        )
    )
    balancing_child = await categories.create(
        CategoryDraft(
            name="迁移校准",
            direction=CategoryDirection.EXPENSE,
            icon="arrow.triangle.2.circlepath",
            color_hex="#888888",
            parent_id=balancing.id,
        )
    )
    ledger = TransactionService(session)
    for amount, category_id, title in (
        (223, balancing.id, "直接平账"),
        (777, balancing_child.id, "子分类平账"),
    ):
        await ledger.create(
            TransactionDraft(
                kind=TransactionKind.EXPENSE,
                amount_minor=amount,
                occurred_at="2026-07-12T12:00:00+08:00",  # type: ignore[arg-type]
                title=title,
                account_id=bank.id,
                category_id=category_id,
            ),
            uuid4(),
        )

    renamed = await categories.update(
        balancing.id,
        CategoryPatch(expected_version=balancing.version, name="余额调整"),
    )
    assert renamed.is_balance_adjustment
    reports = ReportingService(session)
    spending = await reports.spending(date_from=date(2026, 7, 1), date_to=date(2026, 7, 31))
    assert spending.gross_consumption_minor == 3_200
    assert balancing.id not in {item.category_id for item in spending.categories}

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

    for lens in (ReportLens.SPENDING, ReportLens.CASH_FLOW):
        for category_id in (balancing.id, balancing_child.id):
            drill_down = await reports.drill_down(
                lens=lens,
                date_from=date(2026, 7, 1),
                date_to=date(2026, 7, 31),
                category_id=category_id,
                account_id=None,
                cursor=None,
                limit=50,
            )
            assert drill_down.items == []
            assert drill_down.next_cursor is None


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
