from collections.abc import AsyncIterator
from datetime import UTC, date, datetime
from os import environ
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft
from fiscal_api.api.p13_schemas import (
    CashFlowAction,
    CashFlowDraft,
    CashFlowMutationScope,
    CashFlowReplace,
    CashFlowSettlementDraft,
    CashFlowSystemKind,
    CashFlowSystemReplace,
)
from fiscal_api.db.models import (
    AccountKind,
    CashFlowDirection,
    CashFlowItem,
    CashFlowRecurrence,
    CashFlowStatus,
    CategoryDirection,
    LedgerTransaction,
)
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.cash_flow import CashFlowService
from fiscal_api.services.categories import CategoryService
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
                "TRUNCATE cash_flow_system_overrides, cash_flow_item_revisions, "
                "cash_flow_items, cash_flow_series, "
                "transaction_revisions, postings, transactions, credit_cycles, categories, "
                "accounts CASCADE"
            )
        )
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


async def seed(session: AsyncSession):  # type: ignore[no-untyped-def]
    account = await AccountService(session).create(
        AccountDraft(name="银行卡", kind=AccountKind.DEBIT, opening_balance_minor=0)
    )
    category = await CategoryService(session).create(
        CategoryDraft(
            name="工资",
            direction=CategoryDirection.INCOME,
            icon="banknote",
            color_hex="#3366FF",
        )
    )
    return account, category


async def test_monthly_create_is_idempotent_and_settle_creates_one_ledger_row(
    session: AsyncSession,
) -> None:
    account, category = await seed(session)
    service = CashFlowService(session)
    create_key = uuid4()
    draft = CashFlowDraft(
        title="工资",
        direction=CashFlowDirection.INFLOW,
        planned_amount_minor=500_000,
        expected_date=date(2026, 7, 21),
        account_id=account.id,
        category_id=category.id,
        recurrence=CashFlowRecurrence.MONTHLY,
        recurrence_end_date=date(2026, 12, 21),
    )
    first = await service.create(draft, create_key)
    replay = await service.create(draft, create_key)
    assert len(first.items) == 6
    assert [item.id for item in replay.items] == [item.id for item in first.items]

    item = first.items[0]
    assert item.manual_item_id is not None
    confirmed = await service.confirm(item.manual_item_id, item.version)
    settle_key = uuid4()
    settled = await service.settle(
        item.manual_item_id,
        CashFlowSettlementDraft(
            expected_version=confirmed.version,
            actual_amount_minor=510_000,
            occurred_at=datetime(2026, 7, 21, 9, 0, tzinfo=UTC),
            account_id=account.id,
            category_id=category.id,
        ),
        settle_key,
    )
    replay_settlement = await service.settle(
        item.manual_item_id,
        CashFlowSettlementDraft(
            expected_version=confirmed.version,
            actual_amount_minor=510_000,
            occurred_at=datetime(2026, 7, 21, 9, 0, tzinfo=UTC),
            account_id=account.id,
            category_id=category.id,
        ),
        settle_key,
    )
    assert settled.status is CashFlowStatus.SETTLED
    assert replay_settlement.linked_transaction_id == settled.linked_transaction_id
    assert settled.actual_amount_minor == 510_000
    assert await session.scalar(select(func.count()).select_from(LedgerTransaction)) == 1


async def test_monthly_bulk_edit_preserves_each_occurrence_date_and_series_end(
    session: AsyncSession,
) -> None:
    account, _income_category = await seed(session)
    expense_category = await CategoryService(session).create(
        CategoryDraft(
            name="车贷",
            direction=CategoryDirection.EXPENSE,
            icon="car",
            color_hex="#CC3344",
        )
    )
    service = CashFlowService(session)
    created = await service.create(
        CashFlowDraft(
            title="车贷",
            direction=CashFlowDirection.INFLOW,
            planned_amount_minor=253_300,
            expected_date=date(2026, 9, 22),
            account_id=account.id,
            recurrence=CashFlowRecurrence.MONTHLY,
            recurrence_end_date=date(2029, 9, 22),
        ),
        uuid4(),
    )
    first = created.items[0]
    assert first.manual_item_id is not None

    updated = await service.update(
        first.manual_item_id,
        CashFlowReplace(
            title="车贷",
            direction=CashFlowDirection.OUTFLOW,
            planned_amount_minor=253_300,
            expected_date=date(2026, 9, 22),
            account_id=account.id,
            category_id=expense_category.id,
            recurrence=CashFlowRecurrence.MONTHLY,
            # Simulates Build 8's incorrect editor default. The server owns the original
            # series boundary and must not truncate a 2029 plan to this client value.
            recurrence_end_date=date(2027, 3, 22),
            expected_version=first.version,
            scope=CashFlowMutationScope.THIS_AND_FUTURE,
        ),
    )

    assert len(updated.items) == 37
    assert [item.expected_date for item in updated.items] == CashFlowService._monthly_dates(
        date(2026, 9, 22), date(2029, 9, 22)
    )
    assert all(item.direction is CashFlowDirection.OUTFLOW for item in updated.items)
    assert all(item.status is CashFlowStatus.EXPECTED for item in updated.items)


async def test_void_and_restore_keep_cash_flow_and_ledger_in_sync(session: AsyncSession) -> None:
    account, category = await seed(session)
    service = CashFlowService(session)
    created = await service.create(
        CashFlowDraft(
            title="奖金",
            direction=CashFlowDirection.INFLOW,
            planned_amount_minor=100_000,
            expected_date=date(2026, 8, 1),
            account_id=account.id,
            category_id=category.id,
        ),
        uuid4(),
    )
    item = created.items[0]
    assert item.manual_item_id is not None
    confirmed = await service.confirm(item.manual_item_id, item.version)
    settled = await service.settle(
        item.manual_item_id,
        CashFlowSettlementDraft(
            expected_version=confirmed.version,
            actual_amount_minor=100_000,
            occurred_at=datetime(2026, 8, 1, 0, 0, tzinfo=UTC),
            account_id=account.id,
            category_id=category.id,
        ),
        uuid4(),
    )
    assert settled.linked_transaction_id is not None
    ledger = TransactionService(session)
    transaction = await ledger.get(settled.linked_transaction_id)
    voided = await ledger.void(transaction.id, transaction.version)
    reopened = await session.get(CashFlowItem, item.manual_item_id)
    assert reopened is not None and reopened.status == CashFlowStatus.CONFIRMED.value
    await ledger.restore(voided.id, voided.version)
    restored = await session.get(CashFlowItem, item.manual_item_id)
    assert restored is not None and restored.status == CashFlowStatus.SETTLED.value


async def test_system_item_can_be_edited_completed_and_reopened_without_ledger_write(
    session: AsyncSession,
) -> None:
    credit = await AccountService(session).create(
        AccountDraft(
            name="白条",
            kind=AccountKind.CREDIT,
            opening_balance_minor=47_751,
            credit_limit_minor=1_000_000,
            statement_day=1,
            due_day=11,
            opening_balance_as_of_date=date(2026, 6, 1),
            opening_due_date=date(2026, 6, 11),
        )
    )
    service = CashFlowService(session)
    active = await service.active()
    item = next(value for value in active.items if value.account_id == credit.id)
    assert item.system_reference_id is not None
    assert CashFlowAction.EDIT in item.actions

    completed = await service.update_system(
        CashFlowSystemKind.CREDIT_CYCLE,
        item.system_reference_id,
        CashFlowSystemReplace(
            title="白条 6 月账单",
            planned_amount_minor=47_751,
            expected_date=date(2026, 6, 11),
            status=CashFlowStatus.COMPLETED,
            expected_version=item.version,
        ),
    )
    assert completed.status is CashFlowStatus.COMPLETED
    assert not any(value.id == item.id for value in (await service.active()).items)
    history = await service.history("2026-07")
    historical = next(value for value in history.items if value.id == item.id)
    assert historical.title == "白条 6 月账单"
    assert historical.actions == [CashFlowAction.EDIT]
    assert await session.scalar(select(func.count()).select_from(LedgerTransaction)) == 0

    reopened = await service.update_system(
        CashFlowSystemKind.CREDIT_CYCLE,
        item.system_reference_id,
        CashFlowSystemReplace(
            title="白条 6 月账单",
            planned_amount_minor=47_751,
            expected_date=date(2026, 6, 11),
            status=CashFlowStatus.CONFIRMED,
            expected_version=completed.version,
        ),
    )
    assert reopened.status is CashFlowStatus.CONFIRMED
    assert any(value.id == item.id for value in (await service.active()).items)
