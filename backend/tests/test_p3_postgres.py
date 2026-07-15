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

from fiscal_api.api.p2_schemas import AccountDraft, AccountPatch, CategoryDraft, CategoryPatch
from fiscal_api.api.p3_schemas import MAX_MINOR_UNITS, TransactionDraft
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import AccountKind, CategoryDirection, TransactionKind
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.categories import CategoryService
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
                "categories, accounts CASCADE"
            )
        )
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


async def account(service: AccountService, name: str, opening: int = 0) -> UUID:
    return (
        await service.create(
            AccountDraft(
                name=name,
                kind=AccountKind.DEBIT,
                opening_balance_minor=opening,
            )
        )
    ).id


async def category(
    service: CategoryService,
    name: str,
    direction: CategoryDirection,
) -> UUID:
    return (
        await service.create(
            CategoryDraft(
                name=name,
                direction=direction,
                icon="banknote",
                color_hex="#00AA00",
            )
        )
    ).id


def draft(
    kind: TransactionKind,
    amount: int,
    account_id: UUID,
    *,
    category_id: UUID | None = None,
    destination_id: UUID | None = None,
    title: str = "记录",
    occurred_at: str = "2026-07-15T12:00:00Z",
) -> TransactionDraft:
    return TransactionDraft(
        kind=kind,
        amount_minor=amount,
        occurred_at=occurred_at,  # type: ignore[arg-type]
        title=title,
        account_id=account_id,
        destination_account_id=destination_id,
        category_id=category_id,
    )


def assert_error(error: pytest.ExceptionInfo[APIError], code: str) -> None:
    assert error.value.code == code


async def test_all_shapes_balances_summary_filters_and_cursor(session: AsyncSession) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    wallet = await account(accounts, "钱包", 10_000)
    bank = await account(accounts, "银行卡", 20_000)
    food = await category(categories, "餐饮", CategoryDirection.EXPENSE)
    salary = await category(categories, "工资", CategoryDirection.INCOME)

    income = await ledger.create(
        draft(TransactionKind.INCOME, 5_000, bank, category_id=salary, title="七月工资"),
        uuid4(),
    )
    expense = await ledger.create(
        draft(TransactionKind.EXPENSE, 800, wallet, category_id=food, title="午餐"),
        uuid4(),
    )
    transfer = await ledger.create(
        draft(TransactionKind.TRANSFER, 2_000, bank, destination_id=wallet, title="取现"),
        uuid4(),
    )
    assert [posting.amount_minor for posting in transfer.postings] == [-2_000, 2_000]
    assert (await accounts.get(wallet)).current_balance_minor == 11_200
    assert (await accounts.get(bank)).current_balance_minor == 23_000

    summary = await ledger.summary(date_from=date(2026, 7, 15), date_to=date(2026, 7, 15))
    assert (summary.income_minor, summary.expense_minor, summary.net_minor) == (5_000, 800, 4_200)
    assert {item.category_name for item in summary.by_category} == {"餐饮", "工资"}
    assert {item.category_name: item.amount_minor for item in summary.by_category} == {
        "餐饮": 800,
        "工资": 5_000,
    }

    first = await ledger.list(
        cursor=None,
        limit=2,
        kind=None,
        account_id=None,
        category_id=None,
        date_from=None,
        date_to=None,
        query=None,
        include_voided=False,
    )
    assert len(first.items) == 2 and first.next_cursor is not None
    second = await ledger.list(
        cursor=first.next_cursor,
        limit=2,
        kind=None,
        account_id=None,
        category_id=None,
        date_from=None,
        date_to=None,
        query=None,
        include_voided=False,
    )
    assert {item.id for item in first.items}.isdisjoint(item.id for item in second.items)
    assert {income.id, expense.id, transfer.id} == {
        *(item.id for item in first.items),
        *(item.id for item in second.items),
    }


async def test_full_edit_void_restore_and_immutable_idempotent_replay(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    source = await account(accounts, "来源", 10_000)
    destination = await account(accounts, "目标", 0)
    food = await category(categories, "餐饮", CategoryDirection.EXPENSE)
    key = uuid4()
    original_draft = draft(TransactionKind.EXPENSE, 1_000, source, category_id=food)
    created = await ledger.create(original_draft, key)
    updated = await ledger.update(
        created.id,
        draft(TransactionKind.TRANSFER, 2_000, source, destination_id=destination),
        created.version,
    )
    assert (await accounts.get(source)).current_balance_minor == 8_000
    assert (await accounts.get(destination)).current_balance_minor == 2_000
    replay = await ledger.create(original_draft, key)
    assert replay.version == 1 and replay.kind is TransactionKind.EXPENSE
    assert replay.amount_minor == 1_000
    with pytest.raises(APIError) as reused:
        await ledger.create(draft(TransactionKind.EXPENSE, 999, source, category_id=food), key)
    assert_error(reused, "idempotency_key_reused")

    voided = await ledger.void(updated.id, updated.version)
    assert (await accounts.get(source)).current_balance_minor == 10_000
    repeated_void = await ledger.void(voided.id, voided.version)
    assert repeated_void.version == voided.version
    with pytest.raises(APIError) as stale:
        await ledger.restore(voided.id, updated.version)
    assert_error(stale, "resource_version_conflict")
    restored = await ledger.restore(voided.id, voided.version)
    repeated_restore = await ledger.restore(restored.id, restored.version)
    assert repeated_restore.version == restored.version
    assert (await accounts.get(source)).current_balance_minor == 8_000


async def test_archived_retention_safe_delete_merge_and_trigger(session: AsyncSession) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await account(accounts, "账户")
    other = await account(accounts, "归档账户")
    source_category = await category(categories, "来源分类", CategoryDirection.EXPENSE)
    target_category = await category(categories, "目标分类", CategoryDirection.EXPENSE)
    created = await ledger.create(
        draft(TransactionKind.EXPENSE, 300, bank, category_id=source_category), uuid4()
    )
    bank_state = await accounts.get(bank)
    await accounts.archive(bank, bank_state.version)
    category_state = await categories.get(source_category)
    await categories.archive(source_category, category_state.version)
    retained = await ledger.update(
        created.id,
        draft(TransactionKind.EXPENSE, 400, bank, category_id=source_category),
        created.version,
    )
    assert retained.amount_minor == 400
    await accounts.archive(other, (await accounts.get(other)).version)
    with pytest.raises(APIError) as archived_account:
        await ledger.update(
            retained.id,
            draft(TransactionKind.EXPENSE, 400, other, category_id=source_category),
            retained.version,
        )
    assert_error(archived_account, "account_archived")

    restored_category = await categories.restore(
        source_category,
        (await categories.get(source_category)).version,
    )
    with pytest.raises(APIError) as category_in_use:
        await categories.update(
            source_category,
            CategoryPatch(
                expected_version=restored_category.version,
                direction=CategoryDirection.INCOME,
            ),
        )
    assert_error(category_in_use, "category_in_use")
    merged = await categories.merge(
        source_id=source_category,
        target_id=target_category,
        source_expected_version=restored_category.version,
        target_expected_version=(await categories.get(target_category)).version,
    )
    assert merged.usage_count == 1
    assert (await ledger.get(created.id)).category_id == target_category
    merged_summary = await ledger.summary(date_from=None, date_to=None)
    assert [item.category_name for item in merged_summary.by_category] == ["目标分类"]
    with pytest.raises(APIError) as account_in_use:
        await accounts.delete(bank, (await accounts.get(bank)).version)
    assert_error(account_in_use, "account_in_use")

    await session.execute(
        text("UPDATE postings SET amount_minor = abs(amount_minor) WHERE transaction_id = :id"),
        {"id": created.id},
    )
    with pytest.raises(DBAPIError):
        await session.commit()
    await session.rollback()

    await session.execute(
        text("UPDATE postings SET position = 1 WHERE transaction_id = :id"),
        {"id": created.id},
    )
    with pytest.raises(DBAPIError):
        await session.commit()
    await session.rollback()


async def test_search_treats_wildcards_and_escape_as_literals(session: AsyncSession) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await account(accounts, "搜索账户")
    expense = await category(categories, "搜索分类", CategoryDirection.EXPENSE)
    titles = ["100%完成", "under_score", r"path\file", "普通记录"]
    for title in titles:
        await ledger.create(
            draft(TransactionKind.EXPENSE, 1, bank, category_id=expense, title=title),
            uuid4(),
        )

    async def matching(query: str) -> list[str]:
        page = await ledger.list(
            cursor=None,
            limit=50,
            kind=None,
            account_id=None,
            category_id=None,
            date_from=None,
            date_to=None,
            query=query,
            include_voided=False,
        )
        return [item.title for item in page.items]

    assert await matching("%") == ["100%完成"]
    assert await matching("_") == ["under_score"]
    assert await matching("\\") == [r"path\file"]
    assert await matching("UNDER") == ["under_score"]


async def test_create_rejects_derived_overflow_without_changing_ledger(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await account(accounts, "极值账户")
    income = await category(categories, "极值收入", CategoryDirection.INCOME)
    created = await ledger.create(
        draft(TransactionKind.INCOME, MAX_MINOR_UNITS, bank, category_id=income),
        uuid4(),
    )

    with pytest.raises(APIError) as overflow:
        await ledger.create(
            draft(TransactionKind.INCOME, 1, bank, category_id=income),
            uuid4(),
        )
    assert_error(overflow, "derived_amount_out_of_range")
    assert (await accounts.get(bank)).current_balance_minor == MAX_MINOR_UNITS
    summary = await ledger.summary(date_from=None, date_to=None)
    assert (summary.income_minor, summary.expense_minor, summary.net_minor) == (
        MAX_MINOR_UNITS,
        0,
        MAX_MINOR_UNITS,
    )
    page = await ledger.list(
        cursor=None,
        limit=10,
        kind=None,
        account_id=None,
        category_id=None,
        date_from=None,
        date_to=None,
        query=None,
        include_voided=True,
    )
    assert [item.id for item in page.items] == [created.id]


async def test_update_rejects_derived_overflow_and_preserves_old_revision(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await account(accounts, "更新极值账户")
    expense = await category(categories, "原支出", CategoryDirection.EXPENSE)
    income = await category(categories, "更新极值收入", CategoryDirection.INCOME)
    original = await ledger.create(
        draft(TransactionKind.EXPENSE, 1, bank, category_id=expense),
        uuid4(),
    )
    await ledger.create(
        draft(TransactionKind.INCOME, MAX_MINOR_UNITS, bank, category_id=income),
        uuid4(),
    )

    with pytest.raises(APIError) as overflow:
        await ledger.update(
            original.id,
            draft(TransactionKind.INCOME, 1, bank, category_id=income),
            original.version,
        )
    assert_error(overflow, "derived_amount_out_of_range")
    preserved = await ledger.get(original.id)
    assert preserved.kind is TransactionKind.EXPENSE
    assert preserved.version == original.version
    assert (await accounts.get(bank)).current_balance_minor == MAX_MINOR_UNITS - 1
    summary = await ledger.summary(date_from=None, date_to=None)
    assert (summary.income_minor, summary.expense_minor, summary.net_minor) == (
        MAX_MINOR_UNITS,
        1,
        MAX_MINOR_UNITS - 1,
    )


async def test_restore_rejects_derived_overflow_and_remains_voided(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await account(accounts, "恢复极值账户")
    income = await category(categories, "恢复极值收入", CategoryDirection.INCOME)
    created = await ledger.create(
        draft(TransactionKind.INCOME, 1, bank, category_id=income),
        uuid4(),
    )
    voided = await ledger.void(created.id, created.version)
    await ledger.create(
        draft(TransactionKind.INCOME, MAX_MINOR_UNITS, bank, category_id=income),
        uuid4(),
    )

    with pytest.raises(APIError) as overflow:
        await ledger.restore(voided.id, voided.version)
    assert_error(overflow, "derived_amount_out_of_range")
    preserved = await ledger.get(voided.id)
    assert preserved.voided_at is not None
    assert preserved.version == voided.version
    assert (await accounts.get(bank)).current_balance_minor == MAX_MINOR_UNITS
    summary = await ledger.summary(date_from=None, date_to=None)
    assert (summary.income_minor, summary.expense_minor, summary.net_minor) == (
        MAX_MINOR_UNITS,
        0,
        MAX_MINOR_UNITS,
    )


async def test_void_rejects_derived_overflow_and_remains_active(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    minimum = -MAX_MINOR_UNITS - 1
    bank = await account(accounts, "作废极值账户", minimum)
    income = await category(categories, "作废极值收入", CategoryDirection.INCOME)
    expense = await category(categories, "作废极值支出", CategoryDirection.EXPENSE)
    offset = await ledger.create(
        draft(TransactionKind.INCOME, MAX_MINOR_UNITS, bank, category_id=income),
        uuid4(),
    )
    await ledger.create(
        draft(TransactionKind.EXPENSE, MAX_MINOR_UNITS, bank, category_id=expense),
        uuid4(),
    )

    with pytest.raises(APIError) as overflow:
        await ledger.void(offset.id, offset.version)
    assert_error(overflow, "derived_amount_out_of_range")
    preserved = await ledger.get(offset.id)
    assert preserved.voided_at is None
    assert preserved.version == offset.version
    revision_count = await session.scalar(
        text("SELECT count(*) FROM transaction_revisions WHERE transaction_id = :id"),
        {"id": offset.id},
    )
    assert revision_count == 1
    assert (await accounts.get(bank)).current_balance_minor == minimum
    summary = await ledger.summary(date_from=None, date_to=None)
    assert (summary.income_minor, summary.expense_minor, summary.net_minor) == (
        MAX_MINOR_UNITS,
        MAX_MINOR_UNITS,
        0,
    )


async def test_opening_balance_update_rejects_derived_overflow(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await account(accounts, "期初极值账户")
    income = await category(categories, "期初极值收入", CategoryDirection.INCOME)
    await ledger.create(
        draft(TransactionKind.INCOME, MAX_MINOR_UNITS, bank, category_id=income),
        uuid4(),
    )
    original = await accounts.get(bank)

    with pytest.raises(APIError) as overflow:
        await accounts.update(
            bank,
            AccountPatch(
                expected_version=original.version,
                opening_balance_minor=1,
            ),
        )
    assert_error(overflow, "derived_amount_out_of_range")
    preserved = await accounts.get(bank)
    assert preserved.opening_balance_minor == 0
    assert preserved.current_balance_minor == MAX_MINOR_UNITS
    assert preserved.version == original.version


async def test_concurrent_idempotency_and_optimistic_update() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE transaction_revisions, postings, transactions, "
                "categories, accounts CASCADE"
            )
        )
    async with factory() as setup:
        account_id = await account(AccountService(setup), "并发账户")
        category_id = await category(CategoryService(setup), "并发分类", CategoryDirection.EXPENSE)
    request = draft(TransactionKind.EXPENSE, 100, account_id, category_id=category_id)
    key = uuid4()

    async def create_once() -> object:
        async with factory() as concurrent_session:
            return await TransactionService(concurrent_session).create(request, key)

    first, second = await asyncio.gather(create_once(), create_once())
    assert first == second
    async with factory() as verify:
        count = await verify.scalar(text("SELECT count(*) FROM transactions"))
        revisions = await verify.scalar(text("SELECT count(*) FROM transaction_revisions"))
        transaction_id = await verify.scalar(text("SELECT id FROM transactions"))
    assert count == 1 and revisions == 1 and isinstance(transaction_id, UUID)

    async def update_once(amount: int) -> object:
        async with factory() as concurrent_session:
            try:
                return await TransactionService(concurrent_session).update(
                    transaction_id,
                    draft(
                        TransactionKind.EXPENSE,
                        amount,
                        account_id,
                        category_id=category_id,
                    ),
                    1,
                )
            except APIError as error:
                return error

    results = await asyncio.gather(update_once(200), update_once(300))
    assert sum(not isinstance(result, APIError) for result in results) == 1
    conflicts = [result for result in results if isinstance(result, APIError)]
    assert len(conflicts) == 1 and conflicts[0].code == "resource_version_conflict"
    await engine.dispose()
