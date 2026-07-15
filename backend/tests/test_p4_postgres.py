import asyncio
from collections.abc import AsyncIterator
from datetime import date
from os import environ
from uuid import UUID, uuid4

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, AccountPatch, CategoryDraft
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import Account, AccountKind, CategoryDirection, TransactionKind
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.common import acquire_mutation_lock
from fiscal_api.services.credit import CreditService, cycle_calendar
from fiscal_api.services.transactions import TransactionService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(
    TEST_DATABASE_URL is None,
    reason="requires a migrated disposable PostgreSQL database",
)


@pytest_asyncio.fixture
async def session() -> AsyncIterator[AsyncSession]:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE transaction_revisions, postings, transactions, "
                "credit_cycles, categories, accounts CASCADE"
            )
        )
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


async def debit(service: AccountService, name: str = "储蓄卡", opening: int = 100_000) -> UUID:
    return (
        await service.create(
            AccountDraft(name=name, kind=AccountKind.DEBIT, opening_balance_minor=opening)
        )
    ).id


async def credit(
    service: AccountService,
    *,
    name: str = "信用卡",
    opening: int = 500,
    limit: int = 10_000,
) -> UUID:
    return (
        await service.create(
            AccountDraft(
                name=name,
                kind=AccountKind.CREDIT,
                opening_balance_minor=opening,
                credit_limit_minor=limit,
                statement_day=10,
                due_day=22,
                opening_balance_as_of_date=date(2026, 7, 1) if opening else None,
                opening_due_date=date(2026, 7, 20) if opening else None,
            )
        )
    ).id


async def expense_category(service: CategoryService) -> UUID:
    return (
        await service.create(
            CategoryDraft(
                name="餐饮",
                direction=CategoryDirection.EXPENSE,
                icon="fork.knife",
                color_hex="#AA5500",
            )
        )
    ).id


def purchase(account_id: UUID, category_id: UUID, amount: int, at: str) -> TransactionDraft:
    return TransactionDraft(
        kind=TransactionKind.CREDIT_PURCHASE,
        amount_minor=amount,
        occurred_at=at,  # type: ignore[arg-type]
        title="信用消费",
        account_id=account_id,
        category_id=category_id,
    )


def repayment(
    payment_id: UUID, credit_id: UUID, cycle_id: UUID, amount: int, at: str
) -> TransactionDraft:
    return TransactionDraft(
        kind=TransactionKind.REPAYMENT,
        amount_minor=amount,
        occurred_at=at,  # type: ignore[arg-type]
        title="还款",
        account_id=payment_id,
        destination_account_id=credit_id,
        credit_cycle_id=cycle_id,
    )


def assert_error(error: pytest.ExceptionInfo[APIError], code: str) -> None:
    assert error.value.code == code


def test_cycle_calendar_boundaries_and_rollover() -> None:
    assert cycle_calendar(date(2026, 7, 10), 10, 22) == (
        date(2026, 6, 11),
        date(2026, 7, 10),
        date(2026, 7, 22),
    )
    assert cycle_calendar(date(2026, 7, 11), 10, 5) == (
        date(2026, 7, 11),
        date(2026, 8, 10),
        date(2026, 9, 5),
    )


async def test_opening_purchase_repayment_and_summary_stay_consistent(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    ledger = TransactionService(session)
    credit_view = CreditService(session, today=lambda: date(2026, 7, 15))
    payment_id = await debit(accounts)
    credit_id = await credit(accounts)
    category_id = await expense_category(CategoryService(session))

    opening_summary = await credit_view.get_account(credit_id)
    opening_cycle = opening_summary.next_due_cycle
    assert opening_cycle is not None
    assert opening_cycle.is_opening_cycle
    assert opening_cycle.opening_minor == 500

    created = await ledger.create(
        purchase(credit_id, category_id, 2_000, "2026-07-10T12:00:00+08:00"), uuid4()
    )
    assert [item.amount_minor for item in created.postings] == [-2_000]
    assert created.credit_cycle_id is not None
    normal_cycle = await credit_view.get_cycle(created.credit_cycle_id)
    assert (normal_cycle.period_start, normal_cycle.period_end) == (
        date(2026, 6, 11),
        date(2026, 7, 10),
    )

    paid = await ledger.create(
        repayment(
            payment_id,
            credit_id,
            normal_cycle.id,
            300,
            "2026-07-11T12:00:00+08:00",
        ),
        uuid4(),
    )
    assert [item.amount_minor for item in paid.postings] == [-300, 300]
    refreshed = await credit_view.get_account(credit_id)
    refreshed_cycle = await credit_view.get_cycle(normal_cycle.id)
    assert (refreshed.current_debt_minor, refreshed.available_credit_minor) == (2_200, 7_800)
    assert (refreshed_cycle.amount_due_minor, refreshed_cycle.repaid_minor) == (2_000, 300)
    assert (await accounts.get(payment_id)).current_balance_minor == 99_700
    summary = await ledger.summary(date_from=None, date_to=None)
    assert (summary.expense_minor, summary.income_minor) == (2_000, 0)


async def test_cycle_local_chronology_overpayment_and_schedule_freeze(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    ledger = TransactionService(session)
    payment_id = await debit(accounts)
    credit_id = await credit(accounts, opening=0)
    category_id = await expense_category(CategoryService(session))
    created = await ledger.create(
        purchase(credit_id, category_id, 1_000, "2026-07-15T12:00:00+08:00"), uuid4()
    )
    assert created.credit_cycle_id is not None

    with pytest.raises(APIError) as backdated:
        await ledger.create(
            repayment(
                payment_id,
                credit_id,
                created.credit_cycle_id,
                100,
                "2026-07-14T12:00:00+08:00",
            ),
            uuid4(),
        )
    assert_error(backdated, "repayment_exceeds_cycle_remaining")

    with pytest.raises(APIError) as overpayment:
        await ledger.create(
            repayment(
                payment_id,
                credit_id,
                created.credit_cycle_id,
                1_001,
                "2026-07-16T12:00:00+08:00",
            ),
            uuid4(),
        )
    assert_error(overpayment, "repayment_exceeds_cycle_remaining")

    state = await accounts.get(credit_id)
    with pytest.raises(APIError) as schedule:
        await accounts.update(
            credit_id,
            AccountPatch(expected_version=state.version, statement_day=12),
        )
    assert_error(schedule, "credit_schedule_in_use")


async def test_limit_is_admission_only_and_cycle_protects_purchase_void(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    ledger = TransactionService(session)
    credit_view = CreditService(session, today=lambda: date(2026, 7, 15))
    payment_id = await debit(accounts)
    credit_id = await credit(accounts, opening=0, limit=1_000)
    category_id = await expense_category(CategoryService(session))
    created = await ledger.create(
        purchase(credit_id, category_id, 1_000, "2026-07-15T12:00:00+08:00"), uuid4()
    )
    assert created.credit_cycle_id is not None
    with pytest.raises(APIError) as limit:
        await ledger.create(
            purchase(credit_id, category_id, 1, "2026-07-15T13:00:00+08:00"), uuid4()
        )
    assert_error(limit, "credit_limit_exceeded")

    state = await accounts.get(credit_id)
    await accounts.update(
        credit_id,
        AccountPatch(expected_version=state.version, credit_limit_minor=500),
    )
    assert (await credit_view.get_account(credit_id)).over_limit_minor == 500

    paid = await ledger.create(
        repayment(
            payment_id,
            credit_id,
            created.credit_cycle_id,
            400,
            "2026-07-16T12:00:00+08:00",
        ),
        uuid4(),
    )
    with pytest.raises(APIError) as protected:
        await ledger.void(created.id, created.version)
    assert_error(protected, "credit_cycle_overpaid")

    voided_payment = await ledger.void(paid.id, paid.version)
    assert voided_payment.voided_at is not None
    assert (await credit_view.get_account(credit_id)).over_limit_minor == 500


async def test_opening_marker_id_is_stable_and_cannot_be_reduced_below_payment(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    ledger = TransactionService(session)
    credit_view = CreditService(session, today=lambda: date(2026, 7, 15))
    payment_id = await debit(accounts)
    credit_id = await credit(accounts, opening=500)
    first = await credit_view.get_account(credit_id)
    opening = next(
        item
        for item in (await credit_view.list_cycles(credit_id, cursor=None, limit=20)).items
        if item.is_opening_cycle
    )
    await ledger.create(
        repayment(payment_id, credit_id, opening.id, 300, "2026-07-02T12:00:00+08:00"),
        uuid4(),
    )
    state = await accounts.get(credit_id)
    corrected = await accounts.update(
        credit_id,
        AccountPatch(
            expected_version=state.version,
            opening_balance_minor=400,
            opening_balance_as_of_date=date(2026, 6, 30),
            opening_due_date=date(2026, 7, 18),
        ),
    )
    assert corrected.opening_balance_minor == 400
    second = next(
        item
        for item in (await credit_view.list_cycles(credit_id, cursor=None, limit=20)).items
        if item.is_opening_cycle
    )
    assert second.id == opening.id
    assert second.statement_date == date(2026, 6, 30)
    with pytest.raises(APIError) as overpaid:
        await accounts.update(
            credit_id,
            AccountPatch(expected_version=corrected.version, opening_balance_minor=299),
        )
    assert_error(overpaid, "credit_cycle_overpaid")
    assert first.current_debt_minor == 500


async def test_unresolved_opening_does_not_block_normal_cycle_repayment(
    session: AsyncSession,
) -> None:
    unresolved = Account(
        name="迁移信用卡",
        kind=AccountKind.CREDIT.value,
        opening_balance_minor=500,
        credit_limit_minor=10_000,
        statement_day=10,
        due_day=22,
        sort_order=0,
    )
    session.add(unresolved)
    await session.commit()
    payment_id = await debit(AccountService(session))
    category_id = await expense_category(CategoryService(session))
    ledger = TransactionService(session)
    credit_view = CreditService(session, today=lambda: date(2026, 7, 15))

    initial = await credit_view.get_account(unresolved.id)
    assert initial.opening_configuration_required
    assert initial.current_debt_minor == 500
    assert all(
        not item.is_opening_cycle
        for item in (await credit_view.list_cycles(unresolved.id, cursor=None, limit=20)).items
    )

    created = await ledger.create(
        purchase(unresolved.id, category_id, 100, "2026-07-15T12:00:00+08:00"), uuid4()
    )
    assert created.credit_cycle_id is not None
    await ledger.create(
        repayment(
            payment_id,
            unresolved.id,
            created.credit_cycle_id,
            50,
            "2026-07-16T12:00:00+08:00",
        ),
        uuid4(),
    )
    summary = await credit_view.get_account(unresolved.id)
    assert summary.opening_configuration_required
    assert summary.current_debt_minor == 550
    assert summary.next_due_cycle is not None
    assert not summary.next_due_cycle.is_opening_cycle
    assert not summary.has_overdue_cycle


async def test_cross_cycle_edits_repayment_lifecycle_pagination_and_replay(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    ledger = TransactionService(session)
    credit_view = CreditService(session, today=lambda: date(2026, 7, 15))
    payment_id = await debit(accounts)
    credit_id = await credit(accounts, opening=0)
    category_id = await expense_category(CategoryService(session))
    key = uuid4()
    created = await ledger.create(
        purchase(credit_id, category_id, 600, "2026-07-10T12:00:00+08:00"), key
    )
    replay = await ledger.create(
        purchase(credit_id, category_id, 600, "2026-07-10T12:00:00+08:00"), key
    )
    assert replay == created
    assert created.credit_cycle_id is not None

    moved = await ledger.update(
        created.id,
        purchase(credit_id, category_id, 600, "2026-07-11T12:00:00+08:00"),
        created.version,
    )
    assert moved.credit_cycle_id is not None
    assert moved.credit_cycle_id != created.credit_cycle_id
    moved_cycle = await credit_view.get_cycle(moved.credit_cycle_id)
    assert moved_cycle.period_end == date(2026, 8, 10)

    payment = await ledger.create(
        repayment(
            payment_id,
            credit_id,
            moved_cycle.id,
            200,
            "2026-07-12T12:00:00+08:00",
        ),
        uuid4(),
    )
    edited_payment = await ledger.update(
        payment.id,
        repayment(
            payment_id,
            credit_id,
            moved_cycle.id,
            150,
            "2026-07-13T12:00:00+08:00",
        ),
        payment.version,
    )
    assert (await credit_view.get_cycle(moved_cycle.id)).repaid_minor == 150
    voided = await ledger.void(edited_payment.id, edited_payment.version)
    assert (await credit_view.get_cycle(moved_cycle.id)).repaid_minor == 0
    restored = await ledger.restore(voided.id, voided.version)
    assert restored.voided_at is None
    assert (await credit_view.get_cycle(moved_cycle.id)).repaid_minor == 150

    first_page = await credit_view.list_cycles(credit_id, cursor=None, limit=1)
    assert len(first_page.items) == 1
    assert first_page.next_cursor is not None
    second_page = await credit_view.list_cycles(credit_id, cursor=first_page.next_cursor, limit=1)
    assert second_page.items
    assert second_page.items[0].id != first_page.items[0].id
    cycle_page = await ledger.list_cycle(moved_cycle.id, cursor=None, limit=1)
    assert len(cycle_page.items) == 1
    assert cycle_page.next_cursor is not None


async def test_database_trigger_rejects_invalid_credit_posting_shape(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    ledger = TransactionService(session)
    credit_id = await credit(accounts, opening=0)
    category_id = await expense_category(CategoryService(session))
    created = await ledger.create(
        purchase(credit_id, category_id, 100, "2026-07-15T12:00:00+08:00"), uuid4()
    )
    await session.execute(
        text("UPDATE postings SET amount_minor = abs(amount_minor) WHERE transaction_id = :id"),
        {"id": created.id},
    )
    with pytest.raises(DBAPIError):
        await session.commit()
    await session.rollback()


async def test_materialized_cycle_blocks_kind_change_in_service_and_database(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    credit_id = await credit(accounts, opening=0)
    await CreditService(session, today=lambda: date(2026, 7, 15)).get_account(credit_id)
    state = await accounts.get(credit_id)
    with pytest.raises(APIError) as service_error:
        await accounts.update(
            credit_id,
            AccountPatch(
                expected_version=state.version,
                kind=AccountKind.DEBIT,
                credit_limit_minor=None,
                statement_day=None,
                due_day=None,
            ),
        )
    assert_error(service_error, "account_in_use")
    await session.rollback()

    with pytest.raises(DBAPIError):
        await session.execute(
            text(
                "UPDATE accounts SET kind = 'debit', credit_limit_minor = NULL, "
                "statement_day = NULL, due_day = NULL WHERE id = :id"
            ),
            {"id": credit_id},
        )
        await session.commit()
    await session.rollback()
    assert (await accounts.get(credit_id)).kind is AccountKind.CREDIT


async def test_account_service_guards_int64_even_for_constructed_draft(
    session: AsyncSession,
) -> None:
    unsafe = AccountDraft.model_construct(
        name="绕过 DTO",
        kind=AccountKind.CASH,
        institution=None,
        last_four=None,
        opening_balance_minor=2**63,
        credit_limit_minor=None,
        statement_day=None,
        due_day=None,
        opening_balance_as_of_date=None,
        opening_due_date=None,
    )
    with pytest.raises(APIError) as overflow:
        await AccountService(session).create(unsafe)
    assert_error(overflow, "derived_amount_out_of_range")


async def test_get_cycle_waits_for_shared_mutation_lock(session: AsyncSession) -> None:
    assert TEST_DATABASE_URL is not None
    accounts = AccountService(session)
    credit_id = await credit(accounts, opening=0)
    current = (
        await CreditService(session, today=lambda: date(2026, 7, 15)).get_account(credit_id)
    ).current_cycle

    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as lock_session, factory() as read_session:
        await acquire_mutation_lock(lock_session)
        task = asyncio.create_task(
            CreditService(read_session, today=lambda: date(2026, 7, 15)).get_cycle(current.id)
        )
        await asyncio.sleep(0.05)
        assert not task.done()
        await lock_session.commit()
        response = await asyncio.wait_for(task, timeout=1)
        assert response.id == current.id
    await engine.dispose()
