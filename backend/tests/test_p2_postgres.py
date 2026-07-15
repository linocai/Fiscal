import asyncio
from collections.abc import AsyncIterator
from datetime import date
from os import environ
from uuid import UUID

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, AccountPatch, CategoryDraft, CategoryPatch
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import AccountKind, CategoryDirection
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.common import acquire_p2_mutation_lock

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
        await connection.execute(text("TRUNCATE categories, accounts CASCADE"))
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


def account_draft(name: str, kind: AccountKind = AccountKind.DEBIT) -> AccountDraft:
    if kind is AccountKind.CREDIT:
        return AccountDraft(
            name=name,
            kind=kind,
            opening_balance_minor=12_345,
            credit_limit_minor=100_000,
            statement_day=10,
            due_day=20,
            opening_balance_as_of_date=date(2026, 7, 1),
            opening_due_date=date(2026, 7, 20),
        )
    return AccountDraft(name=name, kind=kind, opening_balance_minor=-500)


def category_draft(
    name: str,
    *,
    direction: CategoryDirection = CategoryDirection.EXPENSE,
    parent_id: UUID | None = None,
) -> CategoryDraft:
    return CategoryDraft(
        name=name,
        direction=direction,
        parent_id=parent_id,
        icon="fork.knife",
        color_hex="#aa5500",
        aliases=["  Alias ", "alias", "Second"],
        examples=["Example"],
    )


def assert_error(error: pytest.ExceptionInfo[APIError], code: str) -> None:
    assert error.value.code == code


async def test_account_crud_order_archive_restore_delete_and_conflicts(
    session: AsyncSession,
) -> None:
    service = AccountService(session)
    debit = await service.create(account_draft("储蓄卡"))
    credit = await service.create(account_draft("信用卡", AccountKind.CREDIT))
    assert debit.opening_balance_minor == -500
    assert credit.opening_balance_minor == 12_345
    assert [item.id for item in await service.list(include_archived=False)] == [
        debit.id,
        credit.id,
    ]

    with pytest.raises(APIError) as duplicate:
        await service.create(account_draft(" 储蓄卡 "))
    assert_error(duplicate, "account_name_conflict")

    with pytest.raises(APIError) as invalid_credit:
        await service.create(
            AccountDraft(
                name="坏信用卡",
                kind=AccountKind.CREDIT,
                opening_balance_minor=101,
                credit_limit_minor=100,
                statement_day=1,
                due_day=2,
            )
        )
    assert_error(invalid_credit, "invalid_account_configuration")

    updated = await service.update(
        debit.id,
        AccountPatch(expected_version=debit.version, institution="银行"),
    )
    assert updated.version == 2
    with pytest.raises(APIError) as stale:
        await service.update(debit.id, AccountPatch(expected_version=1, name="旧写入"))
    assert_error(stale, "resource_version_conflict")

    ordered = await service.reorder([credit.id, debit.id])
    assert [item.id for item in ordered] == [credit.id, debit.id]
    with pytest.raises(APIError) as incomplete_order:
        await service.reorder([credit.id])
    assert_error(incomplete_order, "invalid_account_configuration")

    current = await service.get(debit.id)
    archived = await service.archive(debit.id, current.version)
    assert archived.archived_at is not None
    assert [item.id for item in await service.list(include_archived=False)] == [credit.id]
    restored = await service.restore(debit.id, archived.version)
    assert restored.archived_at is None
    account_model = await service.repository.get(debit.id)
    assert account_model is not None
    account_model.usage_count = 1
    await session.commit()
    with pytest.raises(APIError) as in_use:
        await service.delete(debit.id, restored.version)
    assert_error(in_use, "account_in_use")
    account_model.usage_count = 0
    await session.commit()
    await service.delete(debit.id, restored.version)
    with pytest.raises(APIError) as missing:
        await service.get(debit.id)
    assert_error(missing, "account_not_found")


async def test_category_hierarchy_nested_list_reorder_and_safe_delete(
    session: AsyncSession,
) -> None:
    service = CategoryService(session)
    food = await service.create(category_draft("餐饮"))
    travel = await service.create(category_draft("交通"))
    salary = await service.create(category_draft("工资", direction=CategoryDirection.INCOME))
    breakfast = await service.create(category_draft("早餐", parent_id=food.id))
    assert breakfast.aliases == ["Alias", "Second"]
    roots = await service.list(direction=CategoryDirection.EXPENSE, include_archived=False)
    assert [root.id for root in roots] == [food.id, travel.id]
    assert [child.id for child in roots[0].children] == [breakfast.id]

    with pytest.raises(APIError) as third_level:
        await service.create(category_draft("豆浆", parent_id=breakfast.id))
    assert_error(third_level, "invalid_category_hierarchy")
    with pytest.raises(APIError) as wrong_direction:
        await service.create(
            category_draft(
                "奖金",
                direction=CategoryDirection.INCOME,
                parent_id=food.id,
            )
        )
    assert_error(wrong_direction, "invalid_category_hierarchy")

    reordered = await service.reorder(parent_id=None, ordered_ids=[travel.id, food.id])
    assert [item.id for item in reordered] == [travel.id, food.id]
    with pytest.raises(APIError) as mixed_direction:
        await service.reorder(parent_id=None, ordered_ids=[travel.id, salary.id, food.id])
    assert_error(mixed_direction, "invalid_category_hierarchy")

    with pytest.raises(APIError) as has_children:
        await service.archive(food.id, (await service.get(food.id)).version)
    assert_error(has_children, "category_has_children")
    await service.delete(breakfast.id, breakfast.version)
    current_food = await service.get(food.id)
    archived = await service.archive(food.id, current_food.version)
    restored = await service.restore(food.id, archived.version)
    assert restored.archived_at is None


async def test_category_split_merge_conflict_children_and_optimistic_versions(
    session: AsyncSession,
) -> None:
    service = CategoryService(session)
    source = await service.create(category_draft("来源"))
    target = await service.create(category_draft("目标"))
    source_same = await service.create(category_draft("同名", parent_id=source.id))
    source_unique = await service.create(category_draft("独有", parent_id=source.id))
    target_same = await service.create(category_draft("同名", parent_id=target.id))

    merged = await service.merge(
        source_id=source.id,
        target_id=target.id,
        source_expected_version=source.version,
        target_expected_version=target.version,
    )
    assert merged.version == target.version + 1
    assert (await service.get(source.id)).archived_at is not None
    assert (await service.get(source_same.id)).archived_at is not None
    assert (await service.get(source_unique.id)).parent_id == target.id
    assert (await service.get(target_same.id)).archived_at is None

    root = await service.create(category_draft("拆分根"))
    children = await service.split(
        root_id=root.id,
        root_expected_version=root.version,
        drafts=[category_draft("甲"), category_draft("乙")],
    )
    assert [child.parent_id for child in children] == [root.id, root.id]
    with pytest.raises(APIError) as stale:
        await service.split(
            root_id=root.id,
            root_expected_version=root.version,
            drafts=[category_draft("丙"), category_draft("丁")],
        )
    assert_error(stale, "resource_version_conflict")

    with pytest.raises(APIError) as direction_with_children:
        await service.update(
            root.id,
            CategoryPatch(
                expected_version=(await service.get(root.id)).version,
                direction=CategoryDirection.INCOME,
            ),
        )
    assert_error(direction_with_children, "invalid_category_hierarchy")


async def test_global_mutation_lock_serializes_parent_child_changes() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.execute(text("TRUNCATE categories, accounts CASCADE"))
    async with factory() as setup_session:
        root = await CategoryService(setup_session).create(category_draft("并发根"))

    async with factory() as blocker, factory() as contender:
        await acquire_p2_mutation_lock(blocker)
        create_task = asyncio.create_task(
            CategoryService(contender).create(category_draft("并发子", parent_id=root.id))
        )
        await asyncio.sleep(0.05)
        assert not create_task.done()
        await blocker.commit()
        child = await create_task
        assert child.parent_id == root.id

    async with factory() as verification_session:
        service = CategoryService(verification_session)
        current_root = await service.get(root.id)
        with pytest.raises(APIError) as has_children:
            await service.archive(root.id, current_root.version)
        assert_error(has_children, "category_has_children")
    await engine.dispose()
