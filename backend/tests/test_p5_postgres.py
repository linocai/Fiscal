from collections.abc import AsyncIterator
from datetime import UTC, date, datetime
from os import environ
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p5_schemas import (
    InstallmentActionRequest,
    InstallmentCreate,
    InstallmentPlanStatus,
    InstallmentPurchaseReplacement,
    InstallmentReplacement,
    InstallmentSettlementRequest,
)
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import AccountKind, CategoryDirection, TransactionKind
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.credit import CreditService
from fiscal_api.services.installments import InstallmentService
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
                "TRUNCATE installment_plan_revisions, installment_ledger_links, "
                "installment_operations, installment_periods, installment_plans, "
                "transaction_revisions, postings, transactions, credit_cycles, "
                "categories, accounts CASCADE"
            )
        )
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


async def seeded_plan(session: AsyncSession, *, ai_text: bool = False):  # type: ignore[no-untyped-def]
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
            name="电子产品",
            direction=CategoryDirection.EXPENSE,
            icon="laptopcomputer",
            color_hex="#AA5500",
        )
    )
    transaction_service = TransactionService(session)
    create_purchase = transaction_service.create_ai_text if ai_text else transaction_service.create
    purchase = await create_purchase(
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
    return account, purchase, plan


async def test_ai_text_credit_purchase_is_an_ordinary_installment_purchase(
    session: AsyncSession,
) -> None:
    _account, purchase, plan = await seeded_plan(session, ai_text=True)
    assert purchase.source == "ai_text"
    assert plan.purchase_transaction_id == purchase.id
    options = await InstallmentService(session).options(purchase.id, 3)
    assert len(options) == 3


async def additional_plan(
    session: AsyncSession,
    *,
    account_id,  # type: ignore[no-untyped-def]
    category_id,  # type: ignore[no-untyped-def]
    title: str,
    amount: int = 600,
):  # type: ignore[no-untyped-def]
    purchase = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=amount,
            occurred_at=datetime(2026, 7, 15, 2, tzinfo=UTC),
            title=title,
            account_id=account_id,
            category_id=category_id,
        ),
        uuid4(),
    )
    return await InstallmentService(session).create(
        InstallmentCreate(
            purchase_transaction_id=purchase.id,
            installment_count=2,
            total_fee_minor=0,
            start_statement_date=date(2026, 8, 10),
        ),
        uuid4(),
    )


async def test_create_allocation_and_generic_bypass(session: AsyncSession) -> None:
    _account, purchase, plan = await seeded_plan(session)
    assert [item.principal_minor for item in plan.periods] == [
        54984,
        54984,
        54983,
        54983,
        54983,
        54983,
    ]
    assert [item.fee_minor for item in plan.periods] == [1667, 1667, 1667, 1667, 1666, 1666]
    assert plan.total_financed_minor == 339_900
    with pytest.raises(APIError) as caught:
        await TransactionService(session).void(purchase.id, purchase.version)
    assert caught.value.code == "installment_plan_in_use"
    options = await InstallmentService(session).options(purchase.id, 6)
    assert len(options) == 6
    assert options[0].statement_date == plan.start_statement_date


async def test_cancel_future_creates_canonical_refunds(session: AsyncSession) -> None:
    _account, _purchase, plan = await seeded_plan(session)
    result = await InstallmentService(session).cancel_future(
        plan.id,
        InstallmentActionRequest(
            expected_version=plan.version,
            occurred_at=datetime(2026, 7, 15, 2, tzinfo=UTC),
        ),
        uuid4(),
    )
    assert result.plan.status.value == "cancelled"
    assert result.plan.scheduled_gross_minor == 0
    assert [item.kind.value for item in result.refund_transactions] == [
        "installment_refund",
        "installment_refund",
    ]


async def test_settle_and_reverse_are_real_atomic_repayment(session: AsyncSession) -> None:
    _account, _purchase, plan = await seeded_plan(session)
    payment = await AccountService(session).create(
        AccountDraft(
            name="结算账户",
            kind=AccountKind.DEBIT,
            opening_balance_minor=1_000_000,
        )
    )
    service = InstallmentService(session)
    settled = await service.settle_early(
        plan.id,
        InstallmentSettlementRequest(
            expected_version=plan.version,
            payment_account_id=payment.id,
            target_statement_date=date(2026, 8, 10),
            occurred_at=datetime(2026, 7, 15, 2, tzinfo=UTC),
        ),
        uuid4(),
    )
    assert settled.repayment_transaction.amount_minor == 339_900
    assert settled.plan.status.value == "settled_early"
    reversed_result = await service.reverse_settlement(
        plan.id,
        InstallmentActionRequest(
            expected_version=settled.plan.version,
            occurred_at=datetime(2026, 7, 15, 3, tzinfo=UTC),
        ),
        uuid4(),
    )
    assert reversed_result.voided_repayment_transaction.voided_at is not None
    assert reversed_result.plan.status.value == "active"


async def test_preview_is_read_only_and_update_replaces_schedule(
    session: AsyncSession,
) -> None:
    account, purchase, plan = await seeded_plan(session)
    replacement = InstallmentReplacement(
        expected_version=plan.version,
        purchase=InstallmentPurchaseReplacement(
            amount_minor=330_000,
            occurred_at=purchase.occurred_at,
            title="MacBook Pro",
            note="更新",
            account_id=account.id,
            category_id=purchase.category_id,
        ),
        installment_count=7,
        total_fee_minor=10_500,
        fee_category_id=plan.fee_category_id,
        fee_occurred_at=plan.fee_occurred_at,
        start_statement_date=plan.start_statement_date,
    )
    preview = await InstallmentService(session).preview_update(plan.id, replacement)
    assert preview.proposed_plan.installment_count == 7
    assert preview.proposed_plan.periods[-1].scheduled_cycle_id is None
    updated = await InstallmentService(session).update(plan.id, replacement)
    assert updated.installment_count == 7
    assert updated.title == "MacBook Pro"
    assert updated.total_financed_minor == 340_500


async def test_idempotency_replay_conflict_and_terminal_aggregation(
    session: AsyncSession,
) -> None:
    account = await AccountService(session).create(
        AccountDraft(
            name="幂等卡",
            kind=AccountKind.CREDIT,
            opening_balance_minor=0,
            credit_limit_minor=1_000_000,
            statement_day=10,
            due_day=20,
        )
    )
    category = await CategoryService(session).create(
        CategoryDraft(
            name="幂等分类",
            direction=CategoryDirection.EXPENSE,
            icon="cart",
            color_hex="#AA5500",
        )
    )
    purchase = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=101,
            occurred_at=datetime(2026, 7, 15, 0, tzinfo=UTC),
            title="幂等消费",
            account_id=account.id,
            category_id=category.id,
        ),
        uuid4(),
    )
    request = InstallmentCreate(
        purchase_transaction_id=purchase.id,
        installment_count=2,
        total_fee_minor=1,
        fee_category_id=category.id,
        fee_occurred_at=datetime(2026, 7, 15, 1, tzinfo=UTC),
        start_statement_date=date(2026, 8, 10),
    )
    key = uuid4()
    service = InstallmentService(session)
    created = await service.create(request, key)
    replay = await service.create(request, key)
    assert replay.id == created.id
    with pytest.raises(APIError) as caught:
        await service.create(request.model_copy(update={"installment_count": 3}), key)
    assert caught.value.code == "idempotency_key_reused"
    cancelled = await service.cancel_future(
        created.id,
        InstallmentActionRequest(
            expected_version=created.version,
            occurred_at=datetime(2026, 7, 15, 2, tzinfo=UTC),
        ),
        uuid4(),
    )
    assert cancelled.plan.status.value == "cancelled"
    summary = await CreditService(session).get_account(account.id)
    assert summary.current_debt_minor == 0
    assert summary.future_scheduled_gross_minor == 0
    first_cycle = await CreditService(session).get_cycle(created.periods[0].effective_cycle_id)
    assert first_cycle.amount_due_minor == 0
    transaction_summary = await TransactionService(session).summary(date_from=None, date_to=None)
    assert transaction_summary.expense_minor == 0


async def test_shared_cycle_partial_repayment_keeps_gross_schedule(
    session: AsyncSession,
) -> None:
    account, purchase, first = await seeded_plan(session)
    assert purchase.category_id is not None
    second_purchase = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=600,
            occurred_at=datetime(2026, 7, 15, 2, tzinfo=UTC),
            title="共享账期消费",
            account_id=account.id,
            category_id=purchase.category_id,
        ),
        uuid4(),
    )
    second = await InstallmentService(session).create(
        InstallmentCreate(
            purchase_transaction_id=second_purchase.id,
            installment_count=2,
            total_fee_minor=0,
            start_statement_date=date(2026, 8, 10),
        ),
        uuid4(),
    )
    before_first = first.future_scheduled_gross_minor
    before_second = second.future_scheduled_gross_minor
    payment = await AccountService(session).create(
        AccountDraft(
            name="共享账期还款卡",
            kind=AccountKind.DEBIT,
            opening_balance_minor=10_000,
        )
    )
    await TransactionService(session).create_ai_text(
        TransactionDraft(
            kind=TransactionKind.REPAYMENT,
            amount_minor=100,
            occurred_at=datetime(2026, 7, 15, 3, tzinfo=UTC),
            title="共享账期部分还款",
            account_id=payment.id,
            destination_account_id=account.id,
            credit_cycle_id=first.periods[0].effective_cycle_id,
        ),
        uuid4(),
    )
    first_after = await InstallmentService(session).get(first.id)
    second_after = await InstallmentService(session).get(second.id)
    assert first_after.future_scheduled_gross_minor == before_first
    assert second_after.future_scheduled_gross_minor == before_second
    cycle = await CreditService(session).get_cycle(first.periods[0].effective_cycle_id)
    assert cycle.repaid_minor == 100
    assert cycle.remaining_minor == cycle.amount_due_minor - 100


async def test_direct_sql_cannot_break_allocation_conservation(session: AsyncSession) -> None:
    _account, _purchase, plan = await seeded_plan(session)
    await session.execute(
        text(
            "UPDATE installment_periods SET principal_minor=principal_minor+1 WHERE id=:period_id"
        ),
        {"period_id": plan.periods[0].id},
    )
    with pytest.raises(DBAPIError, match="principal allocation mismatch"):
        await session.commit()
    await session.rollback()


async def test_plan_pagination_status_filter_and_cross_plan_operation_key(
    session: AsyncSession,
) -> None:
    account, purchase, first = await seeded_plan(session)
    assert purchase.category_id is not None
    second = await additional_plan(
        session,
        account_id=account.id,
        category_id=purchase.category_id,
        title="第二计划",
    )
    third = await additional_plan(
        session,
        account_id=account.id,
        category_id=purchase.category_id,
        title="第三计划",
        amount=700,
    )
    service = InstallmentService(session)
    page_one = await service.list(account_id=account.id, status=None, cursor=None, limit=2)
    assert len(page_one.items) == 2 and page_one.next_cursor is not None
    page_two = await service.list(
        account_id=account.id, status=None, cursor=page_one.next_cursor, limit=2
    )
    assert len(page_two.items) == 1
    assert {item.id for item in page_one.items}.isdisjoint({item.id for item in page_two.items})
    occurrence = datetime(2026, 7, 15, 4, tzinfo=UTC)
    key = uuid4()
    await service.cancel_future(
        first.id,
        InstallmentActionRequest(expected_version=first.version, occurred_at=occurrence),
        key,
    )
    with pytest.raises(APIError) as caught:
        await service.cancel_future(
            second.id,
            InstallmentActionRequest(expected_version=second.version, occurred_at=occurrence),
            key,
        )
    assert caught.value.code == "installment_operation_conflict"
    cancelled = await service.list(
        account_id=account.id,
        status=InstallmentPlanStatus.CANCELLED,
        cursor=None,
        limit=10,
    )
    assert [item.id for item in cancelled.items] == [first.id]
    active = await service.list(
        account_id=account.id,
        status=InstallmentPlanStatus.ACTIVE,
        cursor=None,
        limit=10,
    )
    assert {item.id for item in active.items} == {second.id, third.id}


async def test_settlement_preview_action_validation_parity(session: AsyncSession) -> None:
    account, _purchase, plan = await seeded_plan(session)
    request = InstallmentSettlementRequest(
        expected_version=plan.version,
        payment_account_id=account.id,
        target_statement_date=date(2026, 8, 11),
        occurred_at=datetime(2026, 7, 15, 5, tzinfo=UTC),
    )
    service = InstallmentService(session)
    with pytest.raises(APIError) as preview_error:
        await service.settlement_preview(plan.id, request)
    with pytest.raises(APIError) as action_error:
        await service.settle_early(plan.id, request, uuid4())
    assert preview_error.value.code == action_error.value.code == "invalid_installment_schedule"


async def test_reverse_rejects_later_generic_target_cycle_repayment(
    session: AsyncSession,
) -> None:
    account, purchase, plan = await seeded_plan(session)
    assert purchase.category_id is not None
    payment = await AccountService(session).create(
        AccountDraft(
            name="撤销依赖账户",
            kind=AccountKind.DEBIT,
            opening_balance_minor=1_000_000,
        )
    )
    service = InstallmentService(session)
    settled = await service.settle_early(
        plan.id,
        InstallmentSettlementRequest(
            expected_version=plan.version,
            payment_account_id=payment.id,
            target_statement_date=date(2026, 8, 10),
            occurred_at=datetime(2026, 7, 15, 2, tzinfo=UTC),
        ),
        uuid4(),
    )
    extra = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=200,
            occurred_at=datetime(2026, 7, 15, 3, tzinfo=UTC),
            title="结清后新消费",
            account_id=account.id,
            category_id=purchase.category_id,
        ),
        uuid4(),
    )
    await TransactionService(session).create_ai_text(
        TransactionDraft(
            kind=TransactionKind.REPAYMENT,
            amount_minor=100,
            occurred_at=datetime(2026, 7, 15, 4, tzinfo=UTC),
            title="后续通用还款",
            account_id=payment.id,
            destination_account_id=account.id,
            credit_cycle_id=extra.credit_cycle_id,
        ),
        uuid4(),
    )
    reverse = InstallmentActionRequest(
        expected_version=settled.plan.version,
        occurred_at=datetime(2026, 7, 15, 5, tzinfo=UTC),
    )
    with pytest.raises(APIError) as preview_error:
        await service.reverse_settlement_preview(plan.id, reverse)
    with pytest.raises(APIError) as action_error:
        await service.reverse_settlement(plan.id, reverse, uuid4())
    assert preview_error.value.code == "installment_settlement_in_use"
    assert action_error.value.code == "installment_settlement_in_use"


async def test_sql_rejects_wrong_refund_identity_and_settlement_amount(
    session: AsyncSession,
) -> None:
    _account, _purchase, plan = await seeded_plan(session)
    cancelled = await InstallmentService(session).cancel_future(
        plan.id,
        InstallmentActionRequest(
            expected_version=plan.version,
            occurred_at=datetime(2026, 7, 15, 4, tzinfo=UTC),
        ),
        uuid4(),
    )
    refund_id = cancelled.refund_transactions[0].id
    wrong_category = await CategoryService(session).create(
        CategoryDraft(
            name="错误退款分类",
            direction=CategoryDirection.EXPENSE,
            icon="xmark",
            color_hex="#BB5500",
        )
    )
    await session.execute(
        text("UPDATE transactions SET category_id=:category_id WHERE id=:id"),
        {"id": refund_id, "category_id": wrong_category.id},
    )
    with pytest.raises(DBAPIError):
        await session.commit()
    await session.rollback()


async def test_sql_rejects_settlement_repayment_amount_mismatch(
    session: AsyncSession,
) -> None:
    _account, _purchase, plan = await seeded_plan(session)
    payment = await AccountService(session).create(
        AccountDraft(
            name="SQL 结清账户",
            kind=AccountKind.DEBIT,
            opening_balance_minor=1_000_000,
        )
    )
    settled = await InstallmentService(session).settle_early(
        plan.id,
        InstallmentSettlementRequest(
            expected_version=plan.version,
            payment_account_id=payment.id,
            target_statement_date=date(2026, 8, 10),
            occurred_at=datetime(2026, 7, 15, 2, tzinfo=UTC),
        ),
        uuid4(),
    )
    repayment_id = settled.repayment_transaction.id
    await session.execute(
        text(
            "UPDATE postings SET amount_minor=CASE WHEN role='source' "
            "THEN amount_minor-1 ELSE amount_minor+1 END WHERE transaction_id=:id"
        ),
        {"id": repayment_id},
    )
    with pytest.raises(DBAPIError, match="settlement destination or amount"):
        await session.commit()
    await session.rollback()


async def test_existing_plan_options_locked_suffix_edit_and_settlement_preview(
    session: AsyncSession,
) -> None:
    account, purchase, plan = await seeded_plan(session)
    payment = await AccountService(session).create(
        AccountDraft(
            name="锁定后缀付款账户",
            kind=AccountKind.DEBIT,
            opening_balance_minor=1_000_000,
        )
    )
    first = plan.periods[0]
    await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.REPAYMENT,
            amount_minor=first.amount_due_minor,
            occurred_at=datetime(2026, 7, 15, 3, tzinfo=UTC),
            title="锁定首期",
            account_id=payment.id,
            destination_account_id=account.id,
            credit_cycle_id=first.effective_cycle_id,
        ),
        uuid4(),
    )
    service = InstallmentService(session)
    options = await service.options(purchase.id, 7)
    assert len(options) == 7
    replacement = InstallmentReplacement(
        expected_version=plan.version,
        purchase=InstallmentPurchaseReplacement(
            amount_minor=plan.principal_minor,
            occurred_at=purchase.occurred_at,
            title="锁定后编辑",
            note=None,
            account_id=account.id,
            category_id=purchase.category_id,
        ),
        installment_count=7,
        total_fee_minor=plan.fee_minor,
        fee_category_id=plan.fee_category_id,
        fee_occurred_at=plan.fee_occurred_at,
        start_statement_date=plan.start_statement_date,
    )
    preview = await service.preview_update(plan.id, replacement)
    assert preview.proposed_plan.locked_count == 1
    updated = await service.update(plan.id, replacement)
    assert updated.periods[0].id == first.id
    assert updated.installment_count == 7
    settlement = await service.settlement_preview(
        plan.id,
        InstallmentSettlementRequest(
            expected_version=updated.version,
            payment_account_id=payment.id,
            target_statement_date=date(2026, 9, 10),
            occurred_at=datetime(2026, 7, 15, 4, tzinfo=UTC),
        ),
    )
    assert settlement.amount_minor == updated.future_scheduled_gross_minor


async def test_existing_plan_options_roll_forward_past_historical_window(
    session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    _account, purchase, _plan = await seeded_plan(session)
    monkeypatch.setattr(InstallmentService, "_today", staticmethod(lambda: date(2026, 9, 1)))
    options = await InstallmentService(session).options(purchase.id, 3)
    assert options[0].statement_date == date(2026, 9, 10)
    assert all(item.eligible for item in options)


async def test_over_sixty_month_purchase_keeps_future_options_and_settlement_preview(
    session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    account = await AccountService(session).create(
        AccountDraft(
            name="超长历史分期卡",
            kind=AccountKind.CREDIT,
            opening_balance_minor=0,
            credit_limit_minor=100_000,
            statement_day=10,
            due_day=20,
        )
    )
    payment = await AccountService(session).create(
        AccountDraft(
            name="超长历史付款账户",
            kind=AccountKind.DEBIT,
            opening_balance_minor=100_000,
        )
    )
    category = await CategoryService(session).create(
        CategoryDraft(
            name="超长历史分类",
            direction=CategoryDirection.EXPENSE,
            icon="clock",
            color_hex="#CC5500",
        )
    )
    purchase = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=6_000,
            occurred_at=datetime(2026, 7, 15, 0, tzinfo=UTC),
            title="六十个月前消费",
            account_id=account.id,
            category_id=category.id,
        ),
        uuid4(),
    )
    plan = await InstallmentService(session).create(
        InstallmentCreate(
            purchase_transaction_id=purchase.id,
            installment_count=60,
            total_fee_minor=0,
            start_statement_date=date(2027, 8, 10),
        ),
        uuid4(),
    )
    fake_today = date(2031, 8, 1)
    for period in plan.periods:
        if period.effective_statement_date >= fake_today:
            continue
        await TransactionService(session).create(
            TransactionDraft(
                kind=TransactionKind.REPAYMENT,
                amount_minor=period.amount_due_minor,
                occurred_at=datetime(2031, 7, 31, 0, tzinfo=UTC),
                title=f"历史期次 {period.sequence}",
                account_id=payment.id,
                destination_account_id=account.id,
                credit_cycle_id=period.effective_cycle_id,
            ),
            uuid4(),
        )
    monkeypatch.setattr(InstallmentService, "_today", staticmethod(lambda: fake_today))
    service = InstallmentService(session)
    options = await service.options(purchase.id, 60)
    assert options[0].statement_date == date(2031, 8, 10)
    assert options[-1].statement_date == date(2036, 7, 10)
    assert all(item.eligible for item in options)
    preview = await service.settlement_preview(
        plan.id,
        InstallmentSettlementRequest(
            expected_version=plan.version,
            payment_account_id=payment.id,
            target_statement_date=date(2031, 8, 10),
            occurred_at=datetime(2031, 8, 1, 0, tzinfo=UTC),
        ),
    )
    assert preview.amount_minor > 0
    assert preview.proposed_plan.start_statement_date == date(2027, 8, 10)
