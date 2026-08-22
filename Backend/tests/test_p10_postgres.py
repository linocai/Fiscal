import asyncio
from collections.abc import AsyncIterator
from os import environ
from uuid import UUID, uuid4

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p10_schemas import (
    BatchCategoryItem,
    BatchCategoryRequest,
    TransactionClassification,
)
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import AccountKind, CategoryDirection, TransactionKind, TransactionSource
from fiscal_api.services.accounts import AccountService
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
                "TRUNCATE transaction_revisions, postings, transactions, "
                "categories, accounts CASCADE"
            )
        )
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


async def make_account(service: AccountService, name: str) -> UUID:
    return (
        await service.create(
            AccountDraft(name=name, kind=AccountKind.DEBIT, opening_balance_minor=100_000)
        )
    ).id


async def make_category(
    service: CategoryService,
    name: str,
    direction: CategoryDirection = CategoryDirection.EXPENSE,
    parent_id: UUID | None = None,
) -> UUID:
    return (
        await service.create(
            CategoryDraft(
                name=name,
                direction=direction,
                parent_id=parent_id,
                icon="tag",
                color_hex="#123456",
            )
        )
    ).id


def expense(account_id: UUID, category_id: UUID, amount: int, title: str) -> TransactionDraft:
    return TransactionDraft(
        kind=TransactionKind.EXPENSE,
        amount_minor=amount,
        occurred_at="2026-07-16T12:00:00+08:00",  # type: ignore[arg-type]
        title=title,
        account_id=account_id,
        category_id=category_id,
    )


async def test_advanced_filters_search_and_filter_bound_cursor(session: AsyncSession) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await make_account(accounts, "远山银行卡")
    wallet = await make_account(accounts, "随身钱包")
    food = await make_category(categories, "深夜食堂")
    travel = await make_category(categories, "通勤交通")
    first = await ledger.create(expense(bank, food, 1_200, "普通午餐"), uuid4())
    second = await ledger.create(expense(wallet, travel, 2_500, "地铁"), uuid4())
    transfer = await ledger.create(
        TransactionDraft(
            kind=TransactionKind.TRANSFER,
            amount_minor=300,
            occurred_at="2026-07-16T11:00:00+08:00",  # type: ignore[arg-type]
            title="分类为空但不是待归类",
            account_id=wallet,
            destination_account_id=bank,
        ),
        uuid4(),
    )
    await session.execute(
        text("UPDATE transactions SET source='ocr' WHERE id=:id"), {"id": second.id}
    )
    await session.execute(
        text("UPDATE transactions SET category_id=NULL WHERE id=:id"), {"id": first.id}
    )
    await session.commit()

    by_account = await ledger.list(
        cursor=None,
        limit=20,
        kind=None,
        account_id=None,
        category_id=None,
        date_from=None,
        date_to=None,
        query="远山",
        include_voided=False,
    )
    assert {item.id for item in by_account.items} == {first.id, transfer.id}
    by_category = await ledger.list(
        cursor=None,
        limit=20,
        kind=None,
        account_id=None,
        category_id=None,
        date_from=None,
        date_to=None,
        query="通勤",
        include_voided=False,
    )
    assert [item.id for item in by_category.items] == [second.id]
    filtered = await ledger.list(
        cursor=None,
        limit=20,
        kind=None,
        account_id=None,
        category_id=None,
        date_from=None,
        date_to=None,
        query=None,
        include_voided=False,
        classification=TransactionClassification.CATEGORIZED,
        source=TransactionSource.OCR,
        amount_min_minor=2_500,
        amount_max_minor=2_500,
    )
    assert [item.id for item in filtered.items] == [second.id]
    inbox = await ledger.list(
        cursor=None,
        limit=1,
        kind=None,
        account_id=None,
        category_id=None,
        date_from=None,
        date_to=None,
        query=None,
        include_voided=True,
        classification=TransactionClassification.UNCATEGORIZED,
    )
    assert [item.id for item in inbox.items] == [first.id]

    page = await ledger.list(
        cursor=None,
        limit=1,
        kind=None,
        account_id=None,
        category_id=None,
        date_from=None,
        date_to=None,
        query=None,
        include_voided=False,
    )
    assert page.next_cursor is not None
    with pytest.raises(APIError) as mismatch:
        await ledger.list(
            cursor=page.next_cursor,
            limit=1,
            kind=TransactionKind.EXPENSE,
            account_id=None,
            category_id=None,
            date_from=None,
            date_to=None,
            query=None,
            include_voided=False,
        )
    assert mismatch.value.code == "invalid_transaction_cursor"


async def test_atomic_bulk_category_versions_revisions_usage_and_rollback(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await make_account(accounts, "批量银行卡")
    old = await make_category(categories, "旧分类")
    target = await make_category(categories, "新分类")
    first = await ledger.create(expense(bank, old, 100, "甲"), uuid4())
    second = await ledger.create(expense(bank, old, 200, "乙"), uuid4())

    result = await ledger.bulk_category(
        BatchCategoryRequest(
            items=[
                BatchCategoryItem(transaction_id=second.id, expected_version=second.version),
                BatchCategoryItem(transaction_id=first.id, expected_version=first.version),
            ],
            category_id=target,
        )
    )
    assert result.changed_count == 2
    assert {item.category_id for item in result.items} == {target}
    assert {item.version for item in result.items} == {2}
    old_value = await categories.get(old)
    target_value = await categories.get(target)
    assert old_value.usage_count == 0 and target_value.usage_count == 2
    revisions = await session.scalar(
        text("SELECT count(*) FROM transaction_revisions WHERE version=2")
    )
    assert revisions == 2

    with pytest.raises(APIError) as stale:
        await ledger.bulk_category(
            BatchCategoryRequest(
                items=[
                    BatchCategoryItem(transaction_id=first.id, expected_version=2),
                    BatchCategoryItem(transaction_id=second.id, expected_version=1),
                ],
                category_id=old,
            )
        )
    assert stale.value.code == "resource_version_conflict"
    await session.rollback()
    assert (await ledger.get(first.id)).category_id == target
    assert (await ledger.get(second.id)).category_id == target


async def test_bulk_requires_active_leaf_and_csv_is_safe_and_filtered(
    session: AsyncSession,
) -> None:
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await make_account(accounts, "+公式账户")
    old = await make_category(categories, "旧分类")
    root = await make_category(categories, "父分类")
    leaf = await make_category(categories, "@公式分类", parent_id=root)
    created = await ledger.create(expense(bank, old, 321, "=SUM(A1:A2)"), uuid4())

    with pytest.raises(APIError) as not_leaf:
        await ledger.bulk_category(
            BatchCategoryRequest(
                items=[BatchCategoryItem(transaction_id=created.id, expected_version=1)],
                category_id=root,
            )
        )
    assert not_leaf.value.code == "category_not_leaf"
    await session.rollback()

    changed = await ledger.bulk_category(
        BatchCategoryRequest(
            items=[BatchCategoryItem(transaction_id=created.id, expected_version=1)],
            category_id=leaf,
        )
    )
    assert changed.changed_count == 1
    body = await ledger.export_csv(
        kind=TransactionKind.EXPENSE,
        account_id=bank,
        category_id=leaf,
        date_from=None,
        date_to=None,
        query=None,
        include_voided=False,
        classification=TransactionClassification.CATEGORIZED,
        source=TransactionSource.MANUAL,
        amount_min_minor=321,
        amount_max_minor=321,
    )
    assert body.startswith("# Fiscal Transactions CSV schema=v1\r\n")
    assert "'=SUM(A1:A2)" in body
    assert "'+公式账户" in body
    assert "'@公式分类" in body
    assert str(created.id) in body
    ledger.EXPORT_LIMIT = 0
    with pytest.raises(APIError) as too_large:
        await ledger.export_csv(
            kind=None,
            account_id=None,
            category_id=None,
            date_from=None,
            date_to=None,
            query=None,
            include_voided=False,
            classification=TransactionClassification.ALL,
            source=None,
            amount_min_minor=None,
            amount_max_minor=None,
        )
    assert too_large.value.code == "transaction_export_too_large"


async def test_concurrent_bulk_category_allows_one_version_winner() -> None:
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
        bank = await make_account(AccountService(setup), "并发批量卡")
        old = await make_category(CategoryService(setup), "并发旧分类")
        first_target = await make_category(CategoryService(setup), "并发目标一")
        second_target = await make_category(CategoryService(setup), "并发目标二")
        created = await TransactionService(setup).create(
            expense(bank, old, 100, "并发分类"), uuid4()
        )

    async def change(target_id: UUID) -> object:
        async with factory() as concurrent:
            try:
                return await TransactionService(concurrent).bulk_category(
                    BatchCategoryRequest(
                        items=[
                            BatchCategoryItem(
                                transaction_id=created.id,
                                expected_version=created.version,
                            )
                        ],
                        category_id=target_id,
                    )
                )
            except APIError as error:
                return error

    results = await asyncio.gather(change(first_target), change(second_target))
    assert sum(not isinstance(item, APIError) for item in results) == 1
    errors = [item for item in results if isinstance(item, APIError)]
    assert len(errors) == 1 and errors[0].code == "resource_version_conflict"
    async with factory() as verify:
        value = await TransactionService(verify).get(created.id)
        assert value.version == 2
        assert value.category_id in {first_target, second_target}
    await engine.dispose()
