from datetime import UTC, date, datetime, timedelta
from uuid import uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p13_schemas import (
    CashFlowDraft,
    CashFlowExistingSettlementDraft,
    CashFlowReplace,
    CashFlowSettlementDraft,
)
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import CashFlowDirection, LedgerTransaction, TransactionKind
from fiscal_api.services.cash_flow import CashFlowService
from fiscal_api.services.reporting import ReportingService
from fiscal_api.services.transactions import TransactionService
from test_p13_cash_flow_postgres import TEST_DATABASE_URL, seed, session  # noqa: F401

pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


async def test_partial_existing_void_restore_and_rolling_facts(session: AsyncSession) -> None:  # noqa: F811
    account, category = await seed(session)
    today = date(2026, 12, 31)
    cash = CashFlowService(session)
    item = (
        await cash.create(
            CashFlowDraft(
                title="Salary",
                direction=CashFlowDirection.INFLOW,
                planned_amount_minor=1000,
                expected_date=today + timedelta(days=29),
                account_id=account.id,
                category_id=category.id,
            ),
            uuid4(),
        )
    ).items[0]
    assert item.manual_item_id is not None
    item = await cash.confirm(item.manual_item_id, item.version)
    request = CashFlowSettlementDraft(
        expected_version=item.version,
        actual_amount_minor=300,
        occurred_at=datetime(2026, 12, 31, tzinfo=UTC),
        account_id=account.id,
        category_id=category.id,
        complete_remaining=False,
    )
    key = uuid4()
    partial = await cash.settle(item.manual_item_id, request, key)
    replay = await cash.settle(item.manual_item_id, request, key)
    assert partial.version == replay.version
    assert partial.status == "confirmed"
    assert partial.settled_amount_minor == 300
    assert partial.remaining_amount_minor == 700
    report = ReportingService(session, facts_today=today)
    facts = await report.facts(window_days=7)
    assert facts.disposable.date_to == date(2027, 1, 29)
    assert facts.disposable.expected_inflow_minor == 700
    assert facts.disposable.current_cash_minor == 300
    assert facts.disposable.projected_balance_minor == 1000
    page = await report.future_events(
        window_days=30,
        account_id=None,
        cursor=None,
        limit=1,
        expected_data_revision=facts.meta.data_revision,
    )
    assert page.items[0].amount_minor == 700
    with pytest.raises(APIError):
        await report.future_events(
            window_days=30,
            account_id=None,
            cursor=None,
            limit=1,
            expected_data_revision=facts.meta.data_revision + 1,
        )
    await session.rollback()
    ledger = TransactionService(session)
    transaction = await ledger.create(
        TransactionDraft(
            kind=TransactionKind.INCOME,
            amount_minor=200,
            occurred_at=datetime(2026, 12, 31, tzinfo=UTC),
            title="Imported salary",
            account_id=account.id,
            category_id=category.id,
        ),
        uuid4(),
    )
    linked = await cash.settle_existing(
        item.manual_item_id,
        CashFlowExistingSettlementDraft(
            expected_version=partial.version,
            transaction_id=transaction.id,
            transaction_expected_version=transaction.version,
            complete_remaining=False,
        ),
        uuid4(),
    )
    assert linked.settled_amount_minor == 500
    assert linked.remaining_amount_minor == 500
    assert await session.scalar(select(func.count()).select_from(LedgerTransaction)) == 2
    voided = await ledger.void(transaction.id, transaction.version)
    assert (await cash.get(item.manual_item_id)).remaining_amount_minor == 700
    await ledger.restore(transaction.id, voided.version)
    current = await cash.get(item.manual_item_id)
    assert current.remaining_amount_minor == 500
    closed = await cash.settle(
        item.manual_item_id,
        CashFlowSettlementDraft(
            expected_version=current.version,
            actual_amount_minor=100,
            occurred_at=datetime(2026, 12, 31, tzinfo=UTC),
            account_id=account.id,
            category_id=category.id,
            complete_remaining=True,
        ),
        uuid4(),
    )
    assert closed.settled_amount_minor == 600
    assert closed.planned_amount_minor == 1000
    assert closed.remaining_amount_minor == 0 and closed.status == "settled"
    assert closed.linked_transaction_id is not None
    await ledger.void(closed.linked_transaction_id, 1)
    reopened = await cash.get(item.manual_item_id)
    assert reopened.remaining_amount_minor == 500 and reopened.status == "confirmed"


async def test_voided_links_preserve_plan_identity(session: AsyncSession) -> None:  # noqa: F811
    account, category = await seed(session)
    cash, ledger = CashFlowService(session), TransactionService(session)
    item = (
        await cash.create(
            CashFlowDraft(
                title="Salary",
                direction=CashFlowDirection.INFLOW,
                planned_amount_minor=1000,
                expected_date=date(2026, 9, 12),
                account_id=account.id,
                category_id=category.id,
            ),
            uuid4(),
        )
    ).items[0]
    assert item.manual_item_id is not None
    item = await cash.confirm(item.manual_item_id, item.version)
    item = await cash.settle(
        item.manual_item_id,
        CashFlowSettlementDraft(
            expected_version=item.version,
            actual_amount_minor=100,
            occurred_at=datetime(2026, 9, 12, tzinfo=UTC),
            account_id=account.id,
            category_id=category.id,
            complete_remaining=False,
        ),
        uuid4(),
    )
    assert item.linked_transaction_id is not None
    await ledger.void(item.linked_transaction_id, 1)
    item = await cash.get(item.manual_item_id)
    with pytest.raises(APIError) as error:
        await cash.update(
            item.manual_item_id,
            CashFlowReplace(
                expected_version=item.version,
                title="Salary",
                direction=CashFlowDirection.INFLOW,
                planned_amount_minor=1000,
                expected_date=date(2026, 9, 12),
                account_id=None,
                category_id=category.id,
            ),
        )
    assert error.value.code == "cash_flow_settlement_identity_locked"


async def test_difference_completion_preserves_original_plan_and_allows_title_edit(
    session: AsyncSession,  # noqa: F811
) -> None:
    account, category = await seed(session)
    cash = CashFlowService(session)
    item = (
        await cash.create(
            CashFlowDraft(
                title="Salary",
                direction=CashFlowDirection.INFLOW,
                planned_amount_minor=1000,
                expected_date=date(2026, 9, 12),
                account_id=account.id,
                category_id=category.id,
            ),
            uuid4(),
        )
    ).items[0]
    assert item.manual_item_id is not None
    item = await cash.confirm(item.manual_item_id, item.version)
    item = await cash.settle(
        item.manual_item_id,
        CashFlowSettlementDraft(
            expected_version=item.version,
            actual_amount_minor=1100,
            occurred_at=datetime(2026, 9, 12, tzinfo=UTC),
            account_id=account.id,
            category_id=category.id,
            complete_remaining=True,
        ),
        uuid4(),
    )
    assert item.planned_amount_minor == 1000
    assert item.settled_amount_minor == 1100
    assert item.remaining_amount_minor == 0
    request = CashFlowReplace(
        expected_version=item.version,
        title="Salary corrected title",
        direction=CashFlowDirection.INFLOW,
        planned_amount_minor=1000,
        expected_date=date(2026, 9, 12),
        account_id=account.id,
        category_id=category.id,
    )
    edited = (await cash.update(item.manual_item_id, request)).items[0]
    assert edited.title == "Salary corrected title"
    assert edited.planned_amount_minor == 1000
    assert edited.status == "settled"
    with pytest.raises(APIError) as error:
        await cash.update(
            item.manual_item_id,
            request.model_copy(
                update={"expected_version": edited.version, "planned_amount_minor": 900}
            ),
        )
    assert error.value.code == "cash_flow_settlement_identity_locked"


async def test_series_resize_to_settled_amount_closes_partial_occurrence(
    session: AsyncSession,  # noqa: F811
) -> None:
    from fiscal_api.api.p13_schemas import CashFlowMutationScope
    from fiscal_api.db.models import CashFlowRecurrence

    account, category = await seed(session)
    cash = CashFlowService(session)
    item = (
        await cash.create(
            CashFlowDraft(
                title="Salary",
                direction=CashFlowDirection.INFLOW,
                planned_amount_minor=1000,
                expected_date=date(2026, 9, 12),
                account_id=account.id,
                category_id=category.id,
                recurrence=CashFlowRecurrence.MONTHLY,
                recurrence_end_date=date(2026, 10, 12),
            ),
            uuid4(),
        )
    ).items[0]
    assert item.manual_item_id is not None
    item = await cash.confirm(item.manual_item_id, item.version)
    item = await cash.settle(
        item.manual_item_id,
        CashFlowSettlementDraft(
            expected_version=item.version,
            actual_amount_minor=300,
            occurred_at=datetime(2026, 9, 12, tzinfo=UTC),
            account_id=account.id,
            category_id=category.id,
            complete_remaining=False,
        ),
        uuid4(),
    )
    updated = await cash.update(
        item.manual_item_id,
        CashFlowReplace(
            expected_version=item.version,
            title="Salary",
            direction=CashFlowDirection.INFLOW,
            planned_amount_minor=300,
            expected_date=date(2026, 9, 12),
            account_id=account.id,
            category_id=category.id,
            scope=CashFlowMutationScope.THIS_AND_FUTURE,
        ),
    )
    first = next(x for x in updated.items if x.id == item.id)
    assert first.status == "settled"
    assert first.remaining_amount_minor == 0
    active = await cash.repository.active()
    assert item.manual_item_id not in {x.id for x in active}
    assert len(active) == 1 and active[0].planned_amount_minor == 300


async def test_void_partial_settlement_does_not_uncancel_plan(
    session: AsyncSession,  # noqa: F811
) -> None:
    from fiscal_api.api.p13_schemas import CashFlowMutationScope

    account, category = await seed(session)
    cash, ledger = CashFlowService(session), TransactionService(session)
    item = (
        await cash.create(
            CashFlowDraft(
                title="Salary",
                direction=CashFlowDirection.INFLOW,
                planned_amount_minor=1000,
                expected_date=date(2026, 9, 12),
                account_id=account.id,
                category_id=category.id,
            ),
            uuid4(),
        )
    ).items[0]
    assert item.manual_item_id is not None
    item = await cash.confirm(item.manual_item_id, item.version)
    item = await cash.settle(
        item.manual_item_id,
        CashFlowSettlementDraft(
            expected_version=item.version,
            actual_amount_minor=100,
            occurred_at=datetime(2026, 9, 12, tzinfo=UTC),
            account_id=account.id,
            category_id=category.id,
            complete_remaining=False,
        ),
        uuid4(),
    )
    assert item.linked_transaction_id is not None
    await cash.cancel(item.manual_item_id, item.version, CashFlowMutationScope.OCCURRENCE)
    voided = await ledger.void(item.linked_transaction_id, 1)
    assert (await cash.get(item.manual_item_id)).status == "cancelled"
    assert not await cash.repository.active()
    with pytest.raises(APIError) as error:
        await ledger.restore(item.linked_transaction_id, voided.version)
    assert error.value.code == "cash_flow_not_confirmed"
