import asyncio
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from os import environ
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy import func, select, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p6_schemas import (
    ReimbursementAllocationDraft,
    ReimbursementClaimDraft,
    ReimbursementClaimReplace,
    ReimbursementReceiptDraft,
    ReimbursementReceiptReplace,
)
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import (
    AccountKind,
    CategoryDirection,
    ReimbursementClaimStatus,
    ReimbursementOperation,
    ReimbursementPreview,
    TransactionKind,
)
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.reimbursements import ReimbursementService
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
                "reimbursement_receipts, reimbursement_allocations, "
                "reimbursement_claims, installment_plan_revisions, installment_ledger_links, "
                "installment_operations, installment_periods, installment_plans, "
                "transaction_revisions, postings, transactions, credit_cycles, categories, "
                "accounts CASCADE"
            )
        )
    async with factory() as database_session:
        yield database_session
    await engine.dispose()


async def seed(session: AsyncSession):  # type: ignore[no-untyped-def]
    accounts = AccountService(session)
    categories = CategoryService(session)
    ledger = TransactionService(session)
    bank = await accounts.create(
        AccountDraft(name="银行", kind=AccountKind.DEBIT, opening_balance_minor=100_000)
    )
    category = await categories.create(
        CategoryDraft(
            name="差旅", direction=CategoryDirection.EXPENSE, icon="airplane", color_hex="#445566"
        )
    )
    expenses = []
    for index, amount in enumerate((10_000, 20_000, 30_000)):
        expenses.append(
            await ledger.create(
                TransactionDraft(
                    kind=TransactionKind.EXPENSE,
                    amount_minor=amount,
                    occurred_at=datetime(2026, 7, 10 + index, tzinfo=UTC),
                    title=f"垫付 {index}",
                    account_id=bank.id,
                    category_id=category.id,
                ),
                uuid4(),
            )
        )
    return bank, expenses


async def test_matrix_partial_receipts_and_income_exclusion(session: AsyncSession) -> None:
    bank, expenses = await seed(session)
    service = ReimbursementService(session)
    claim = await service.create(
        ReimbursementClaimDraft(
            title="差旅报销",
            counterparty_name="公司",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=10000),
                ReimbursementAllocationDraft(transaction_id=expenses[1].id, amount_minor=15000),
                ReimbursementAllocationDraft(transaction_id=expenses[2].id, amount_minor=20000),
            ],
        ),
        uuid4(),
    )
    assert claim.total_claimed_minor == 45_000
    assert claim.status.value == "draft"
    receipt_draft = ReimbursementReceiptDraft(
        expected_claim_version=claim.version,
        amount_minor=18000,
        received_at=datetime.now(UTC) - timedelta(seconds=1),
        destination_account_id=bank.id,
        title="公司首笔回款",
    )
    receipt_key = uuid4()
    receipt = await service.create_receipt(claim.id, receipt_draft, receipt_key)
    assert await service.create_receipt(claim.id, receipt_draft, receipt_key) == receipt
    with pytest.raises(APIError) as receipt_reused:
        await service.create_receipt(
            claim.id,
            receipt_draft.model_copy(update={"amount_minor": 17_999}),
            receipt_key,
        )
    assert receipt_reused.value.code == "idempotency_key_reused"
    assert [item.amount_minor for item in receipt.allocations] == [10_000, 8_000]
    updated = await service.get(claim.id)
    assert updated.status.value == "partial_received"
    assert updated.received_minor == 18_000
    assert (
        await TransactionService(session).summary(date_from=None, date_to=None)
    ).income_minor == 0
    summary = await service.summary(date_from=None, date_to=None)
    assert summary.expected_reimbursement_minor == 45_000
    assert summary.received_reimbursement_minor == 18_000


async def test_global_cap_and_generic_guards(session: AsyncSession) -> None:
    _bank, expenses = await seed(session)
    service = ReimbursementService(session)
    first = await service.create(
        ReimbursementClaimDraft(
            title="一",
            counterparty_name="甲",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=7000)
            ],
        ),
        uuid4(),
    )
    with pytest.raises(APIError) as caught:
        await service.create(
            ReimbursementClaimDraft(
                title="二",
                counterparty_name="乙",
                expenses=[
                    ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=4000)
                ],
            ),
            uuid4(),
        )
    assert caught.value.code == "reimbursement_expense_overallocated"
    with pytest.raises(APIError) as caught:
        await TransactionService(session).void(expenses[0].id, expenses[0].version)
    assert caught.value.code == "reimbursement_claim_in_use"
    assert first.total_claimed_minor == 7_000


async def test_receipt_replace_soft_void_restore_and_versions(session: AsyncSession) -> None:
    bank, expenses = await seed(session)
    service = ReimbursementService(session)
    claim = await service.create(
        ReimbursementClaimDraft(
            title="纠错",
            counterparty_name="公司",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=10000),
                ReimbursementAllocationDraft(transaction_id=expenses[1].id, amount_minor=10000),
            ],
        ),
        uuid4(),
    )
    receipt = await service.create_receipt(
        claim.id,
        ReimbursementReceiptDraft(
            expected_claim_version=claim.version,
            amount_minor=8000,
            received_at=datetime.now(UTC) - timedelta(seconds=3),
            destination_account_id=bank.id,
            title="首笔",
        ),
        uuid4(),
    )
    bank = await AccountService(session).archive(bank.id, bank.version)
    claim = await service.get(claim.id)
    replacement = ReimbursementReceiptReplace(
        expected_claim_version=claim.version,
        expected_receipt_version=receipt.version,
        amount_minor=12000,
        received_at=datetime.now(UTC) - timedelta(seconds=2),
        destination_account_id=bank.id,
        title="更正回款",
    )
    replaced = await service.replace_receipt(receipt.id, replacement)
    assert [item.amount_minor for item in replaced.allocations] == [10_000, 2_000]
    claim = await service.get(claim.id)
    stale_replacement = replacement.model_copy(update={"expected_claim_version": claim.version})
    with pytest.raises(APIError) as stale_preview:
        await service.receipt_preview(claim.id, stale_replacement, exclude_receipt=receipt.id)
    with pytest.raises(APIError) as stale_action:
        await service.replace_receipt(receipt.id, stale_replacement)
    assert stale_preview.value.code == stale_action.value.code == "resource_version_conflict"
    voided = await service.receipt_lifecycle(receipt.id, claim.version, replaced.version, "void")
    assert voided.voided_at is not None
    assert len(voided.transaction.postings) == 1
    assert voided.allocations == []
    assert (await service.get(claim.id)).received_minor == 0
    claim = await service.get(claim.id)
    second = claim.expenses[1]
    claim = await service.update(
        claim.id,
        ReimbursementClaimReplace(
            expected_version=claim.version,
            title=claim.title,
            counterparty_name=claim.counterparty_name,
            expenses=[
                ReimbursementAllocationDraft(
                    id=second.id, transaction_id=second.transaction_id, amount_minor=20000
                )
            ],
        ),
    )
    restored = await service.receipt_lifecycle(receipt.id, claim.version, voided.version, "restore")
    assert restored.voided_at is None
    assert restored.transaction.version == voided.transaction.version + 1
    assert [item.allocation_id for item in restored.allocations] == [second.id]
    claim = await service.get(claim.id)
    assert claim.received_minor == 12_000
    cancelled = await service.lifecycle(claim.id, claim.version, "cancel_outstanding")
    archived = await service.lifecycle(cancelled.id, cancelled.version, "archive")
    assert archived.archived_at is not None
    unarchived = await service.lifecycle(archived.id, archived.version, "unarchive")
    assert unarchived.archived_at is None


async def test_receipt_edit_keeps_expense_attribution_after_reorder_and_other_receipts(
    session: AsyncSession,
) -> None:
    bank, expenses = await seed(session)
    service = ReimbursementService(session)
    claim = await service.create(
        ReimbursementClaimDraft(
            title="稳定回款归属",
            counterparty_name="公司",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=10_000),
                ReimbursementAllocationDraft(transaction_id=expenses[1].id, amount_minor=10_000),
            ],
        ),
        uuid4(),
    )
    a_id, b_id = (expense.id for expense in claim.expenses)

    async def create_receipt(amount: int, title: str):  # type: ignore[no-untyped-def]
        current = await service.get(claim.id)
        return await service.create_receipt(
            claim.id,
            ReimbursementReceiptDraft(
                expected_claim_version=current.version,
                amount_minor=amount,
                received_at=datetime.now(UTC) - timedelta(seconds=2),
                destination_account_id=bank.id,
                title=title,
            ),
            uuid4(),
        )

    first = await create_receipt(6_000, "首笔")
    assert [(item.allocation_id, item.amount_minor) for item in first.allocations] == [
        (a_id, 6_000)
    ]
    second = await create_receipt(5_000, "第二笔")
    assert [(item.allocation_id, item.amount_minor) for item in second.allocations] == [
        (a_id, 4_000),
        (b_id, 1_000),
    ]
    claim = await service.get(claim.id)
    claim = await service.update(
        claim.id,
        ReimbursementClaimReplace(
            expected_version=claim.version,
            title=claim.title,
            counterparty_name=claim.counterparty_name,
            expenses=[
                ReimbursementAllocationDraft(
                    id=b_id, transaction_id=expenses[1].id, amount_minor=10_000
                ),
                ReimbursementAllocationDraft(
                    id=a_id, transaction_id=expenses[0].id, amount_minor=10_000
                ),
            ],
        ),
    )

    def replacement(receipt, amount: int, title: str) -> ReimbursementReceiptReplace:  # type: ignore[no-untyped-def]
        return ReimbursementReceiptReplace(
            expected_claim_version=claim.version,
            expected_receipt_version=receipt.version,
            amount_minor=amount,
            received_at=receipt.received_at,
            destination_account_id=bank.id,
            title=title,
        )

    unchanged = await service.replace_receipt(first.id, replacement(first, 6_000, "改备注"))
    assert [(item.allocation_id, item.amount_minor) for item in unchanged.allocations] == [
        (a_id, 6_000)
    ]
    claim = await service.get(claim.id)
    reduced = await service.replace_receipt(unchanged.id, replacement(unchanged, 3_000, "调减"))
    assert [(item.allocation_id, item.amount_minor) for item in reduced.allocations] == [
        (a_id, 3_000)
    ]
    claim = await service.get(claim.id)
    increased = await service.replace_receipt(reduced.id, replacement(reduced, 7_000, "调增"))
    assert [(item.allocation_id, item.amount_minor) for item in increased.allocations] == [
        (a_id, 3_000),
        (b_id, 4_000),
    ]
    # The original 3,000 remains on A; only the extra 4,000 follows the
    # current expense order. The other receipt still owns A 4,000 / B 1,000.
    claim = await service.get(claim.id)
    received = {expense.id: expense.received_minor for expense in claim.expenses}
    assert received == {b_id: 5_000, a_id: 7_000}
    voided = await service.receipt_lifecycle(second.id, claim.version, second.version, "void")
    assert voided.allocations == []
    claim = await service.get(claim.id)
    restored = await service.receipt_lifecycle(second.id, claim.version, voided.version, "restore")
    assert sum(item.amount_minor for item in restored.allocations) == 5_000
    claim = await service.get(claim.id)
    assert sum(expense.received_minor for expense in claim.expenses) == 12_000


async def test_preview_filters_lifecycle_and_idempotency(session: AsyncSession) -> None:
    _bank, expenses = await seed(session)
    service = ReimbursementService(session)
    key = uuid4()
    draft = ReimbursementClaimDraft(
        title="可搜索差旅",
        note="七月项目",
        counterparty_name="原主体",
        expenses=[ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=5000)],
    )
    claim = await service.create(draft, key)
    assert await service.create(draft, key) == claim
    with pytest.raises(APIError) as reused:
        await service.create(draft.model_copy(update={"title": "另一张"}), key)
    assert reused.value.code == "idempotency_key_reused"
    proposed = ReimbursementClaimReplace(
        expected_version=claim.version,
        title="可搜索差旅 · 更正",
        note=claim.note,
        counterparty_name="新主体",
        expenses=[
            ReimbursementAllocationDraft(
                id=claim.expenses[0].id, transaction_id=expenses[0].id, amount_minor=6000
            )
        ],
    )
    preview = await service.preview(claim.id, proposed)
    assert preview.proposed.counterparty_name == "新主体"
    assert preview.proposed.expenses[0].amount_minor == 6_000
    queried = await service.list(
        cursor=None,
        limit=1,
        status=ReimbursementClaimStatus.DRAFT,
        query="搜索",
        expense_transaction_id=expenses[0].id,
        include_archived=False,
        include_voided=False,
    )
    assert [item.id for item in queried.items] == [claim.id]
    submitted = await service.lifecycle(claim.id, claim.version, "submit")
    with pytest.raises(APIError) as stale:
        await service.lifecycle(claim.id, claim.version, "retract_submission")
    assert stale.value.code == "resource_version_conflict"
    cancelled = await service.lifecycle(claim.id, submitted.version, "cancel_outstanding")
    assert cancelled.status is ReimbursementClaimStatus.CANCELLED
    reopened = await service.lifecycle(claim.id, cancelled.version, "reopen")
    assert reopened.status is ReimbursementClaimStatus.PENDING


async def test_deferred_move_validates_old_claim(session: AsyncSession) -> None:
    _bank, expenses = await seed(session)
    service = ReimbursementService(session)
    claims = []
    for index in range(2):
        claims.append(
            await service.create(
                ReimbursementClaimDraft(
                    title=f"移动 {index}",
                    counterparty_name=f"主体 {index}",
                    expenses=[
                        ReimbursementAllocationDraft(
                            transaction_id=expenses[index].id, amount_minor=5000
                        )
                    ],
                ),
                uuid4(),
            )
        )
    source, destination = claims
    await session.execute(
        text("UPDATE reimbursement_allocations SET position=1 WHERE id=:id"),
        {"id": source.expenses[0].id},
    )
    await session.execute(
        text("UPDATE reimbursement_allocations SET claim_id=:target WHERE id=:id"),
        {"target": destination.id, "id": source.expenses[0].id},
    )
    with pytest.raises(DBAPIError, match="reimbursement claim requires expenses"):
        await session.commit()
    await session.rollback()


async def test_concurrent_claims_cannot_overallocate_final_capacity(
    session: AsyncSession,
) -> None:
    _bank, expenses = await seed(session)
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)

    async def create_claim(name: str) -> str:
        async with factory() as concurrent:
            try:
                await ReimbursementService(concurrent).create(
                    ReimbursementClaimDraft(
                        title=name,
                        counterparty_name=name,
                        expenses=[
                            ReimbursementAllocationDraft(
                                transaction_id=expenses[0].id, amount_minor=7000
                            )
                        ],
                    ),
                    uuid4(),
                )
                return "created"
            except APIError as error:
                return error.code

    results = await asyncio.gather(create_claim("并发甲"), create_claim("并发乙"))
    assert sorted(results) == ["created", "reimbursement_expense_overallocated"]
    await engine.dispose()


async def test_receipt_create_preview_action_validation_parity(
    session: AsyncSession,
) -> None:
    bank, expenses = await seed(session)
    service = ReimbursementService(session)

    async def claim_for(expense_index: int, title: str):  # type: ignore[no-untyped-def]
        return await service.create(
            ReimbursementClaimDraft(
                title=title,
                counterparty_name="公司",
                expenses=[
                    ReimbursementAllocationDraft(
                        transaction_id=expenses[expense_index].id, amount_minor=5000
                    )
                ],
            ),
            uuid4(),
        )

    async def assert_same_error(claim, draft, code: str) -> None:  # type: ignore[no-untyped-def]
        with pytest.raises(APIError) as preview_error:
            await service.receipt_preview(claim.id, draft)
        with pytest.raises(APIError) as action_error:
            await service.create_receipt(claim.id, draft, uuid4())
        assert preview_error.value.code == action_error.value.code == code

    live = await claim_for(0, "校验")
    base = ReimbursementReceiptDraft(
        expected_claim_version=live.version,
        amount_minor=1000,
        received_at=datetime.now(UTC) - timedelta(seconds=1),
        destination_account_id=bank.id,
        title="回款",
    )
    await assert_same_error(
        live,
        base.model_copy(update={"received_at": datetime.now(UTC) + timedelta(days=1)}),
        "invalid_received_at",
    )
    credit = await AccountService(session).create(
        AccountDraft(
            name="错误信用账户",
            kind=AccountKind.CREDIT,
            opening_balance_minor=0,
            credit_limit_minor=10_000,
            statement_day=10,
            due_day=20,
        )
    )
    await assert_same_error(
        live,
        base.model_copy(update={"destination_account_id": credit.id}),
        "invalid_transaction_configuration",
    )
    voided = await service.lifecycle(live.id, live.version, "void")
    await assert_same_error(
        voided,
        base.model_copy(update={"expected_claim_version": voided.version}),
        "reimbursement_invalid_status_transition",
    )
    cancelled = await claim_for(1, "取消")
    cancelled = await service.lifecycle(cancelled.id, cancelled.version, "submit")
    cancelled = await service.lifecycle(cancelled.id, cancelled.version, "cancel_outstanding")
    cancelled_draft = base.model_copy(
        update={
            "expected_claim_version": cancelled.version,
            "party_id": cancelled.id,
        }
    )
    await assert_same_error(cancelled, cancelled_draft, "reimbursement_claim_cancelled")
    archived = await service.lifecycle(cancelled.id, cancelled.version, "archive")
    await assert_same_error(
        archived,
        cancelled_draft.model_copy(update={"expected_claim_version": archived.version}),
        "reimbursement_claim_archived",
    )


async def test_p33_preview_tokens_bind_reimbursement_mutations(session: AsyncSession) -> None:
    """Every reimbursement action with a preview rejects stale/tampered/reused input."""
    bank, expenses = await seed(session)
    service = ReimbursementService(session)
    claim = await service.create(
        ReimbursementClaimDraft(
            title="P33 claim",
            counterparty_name="公司",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=8000)
            ],
        ),
        uuid4(),
    )
    replacement = ReimbursementClaimReplace(
        expected_version=claim.version,
        title="P33 claim updated",
        counterparty_name="公司",
        expenses=[
            ReimbursementAllocationDraft(
                id=claim.expenses[0].id, transaction_id=expenses[0].id, amount_minor=8000
            )
        ],
    )
    preview = await service.preview(claim.id, replacement)
    assert preview.input_digest and preview.claim_version == claim.version
    update_key = uuid4()
    updated = await service.update(
        claim.id,
        replacement,
        preview_token=preview.preview_token,
        idempotency_key=update_key,
    )
    assert updated.title == replacement.title
    assert (
        await service.update(
            claim.id,
            replacement,
            preview_token=preview.preview_token,
            idempotency_key=update_key,
        )
    ) == updated
    with pytest.raises(APIError) as replayed_token:
        await service.update(
            claim.id,
            replacement,
            preview_token=preview.preview_token,
            idempotency_key=uuid4(),
        )
    assert replayed_token.value.code == "reimbursement_preview_consumed"

    changed_preview = await service.preview(
        claim.id, replacement.model_copy(update={"expected_version": updated.version})
    )
    with pytest.raises(APIError) as crossed_operation:
        await service.lifecycle(
            claim.id,
            updated.version,
            "cancel_outstanding",
            preview_token=changed_preview.preview_token,
            idempotency_key=uuid4(),
        )
    assert crossed_operation.value.code == "reimbursement_preview_input_mismatch"
    with pytest.raises(APIError) as tampered:
        await service.update(
            claim.id,
            replacement.model_copy(
                update={"expected_version": updated.version, "title": "tampered"}
            ),
            preview_token=changed_preview.preview_token,
            idempotency_key=uuid4(),
        )
    assert tampered.value.code == "reimbursement_preview_input_mismatch"

    submitted = await service.lifecycle(claim.id, updated.version, "submit")
    cancellation = await service.cancel_preview(claim.id, submitted.version)
    cancelled = await service.lifecycle(
        claim.id,
        submitted.version,
        "cancel_outstanding",
        preview_token=cancellation.preview_token,
        idempotency_key=uuid4(),
    )
    assert cancelled.status is ReimbursementClaimStatus.CANCELLED
    reopened = await service.lifecycle(claim.id, cancelled.version, "reopen")
    assert reopened.status is ReimbursementClaimStatus.PENDING

    receipt_claim = await service.create(
        ReimbursementClaimDraft(
            title="P33 receipt",
            counterparty_name="客户",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[1].id, amount_minor=10000)
            ],
        ),
        uuid4(),
    )
    receipt_draft = ReimbursementReceiptDraft(
        expected_claim_version=receipt_claim.version,
        amount_minor=4000,
        received_at=datetime.now(UTC) - timedelta(seconds=1),
        destination_account_id=bank.id,
        title="P33 first receipt",
    )
    receipt_preview = await service.receipt_preview(receipt_claim.id, receipt_draft)
    assert receipt_preview.claim_after.received_minor == 4_000
    receipt_key = uuid4()
    receipt = await service.create_receipt(
        receipt_claim.id,
        receipt_draft,
        receipt_key,
        preview_token=receipt_preview.preview_token,
    )
    assert [allocation.amount_minor for allocation in receipt.allocations] == [4_000]
    assert [allocation.id for allocation in receipt.allocations] == [
        allocation.id for allocation in receipt_preview.persisted_allocations
    ]
    assert (
        await service.create_receipt(
            receipt_claim.id,
            receipt_draft,
            receipt_key,
            preview_token=receipt_preview.preview_token,
        )
    ) == receipt
    refreshed = await service.get(receipt_claim.id)
    replace_draft = ReimbursementReceiptReplace(
        expected_claim_version=refreshed.version,
        expected_receipt_version=receipt.version,
        amount_minor=5000,
        received_at=receipt_draft.received_at,
        destination_account_id=bank.id,
        title="P33 corrected receipt",
    )
    replace_preview = await service.receipt_preview(
        refreshed.id, replace_draft, exclude_receipt=receipt.id
    )
    assert replace_preview.receipt_version == receipt.version
    replaced = await service.replace_receipt(
        receipt.id,
        replace_draft,
        preview_token=replace_preview.preview_token,
        idempotency_key=uuid4(),
    )
    assert replaced.amount_minor == 5_000
    assert [allocation.id for allocation in replaced.allocations] == [
        allocation.id for allocation in replace_preview.persisted_allocations
    ]

    after_replacement = await service.get(receipt_claim.id)
    expired_draft = replace_draft.model_copy(
        update={
            "expected_claim_version": after_replacement.version,
            "expected_receipt_version": replaced.version,
        }
    )
    stale_preview = await service.receipt_preview(
        after_replacement.id, expired_draft, exclude_receipt=receipt.id
    )
    await session.execute(
        text(
            "UPDATE reimbursement_previews "
            "SET expires_at = now() - interval '1 second' WHERE id=:id"
        ),
        {"id": stale_preview.preview_token},
    )
    await session.commit()
    with pytest.raises(APIError) as expired:
        await service.replace_receipt(
            receipt.id,
            expired_draft,
            preview_token=stale_preview.preview_token,
            idempotency_key=uuid4(),
        )
    assert expired.value.code == "reimbursement_preview_expired"


async def test_p33_concurrent_preview_sessions_allow_only_one_commit(
    session: AsyncSession,
) -> None:
    """Two independently previewed claim updates cannot both cross the global lock."""
    _bank, expenses = await seed(session)
    claim = await ReimbursementService(session).create(
        ReimbursementClaimDraft(
            title="P33 concurrent",
            counterparty_name="公司",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=6000)
            ],
        ),
        uuid4(),
    )
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)

    def draft_for(title: str) -> ReimbursementClaimReplace:
        return ReimbursementClaimReplace(
            expected_version=claim.version,
            title=title,
            counterparty_name="公司",
            expenses=[
                ReimbursementAllocationDraft(
                    id=claim.expenses[0].id, transaction_id=expenses[0].id, amount_minor=6000
                )
            ],
        )

    async def preview(title: str):  # type: ignore[no-untyped-def]
        async with factory() as concurrent:
            service = ReimbursementService(concurrent)
            return await service.preview(claim.id, draft_for(title))

    first_preview, second_preview = await asyncio.gather(
        preview("P33 first"), preview("P33 second")
    )

    async def commit(title: str, token):  # type: ignore[no-untyped-def]
        async with factory() as concurrent:
            try:
                response = await ReimbursementService(concurrent).update(
                    claim.id,
                    draft_for(title),
                    preview_token=token,
                    idempotency_key=uuid4(),
                )
                return response.title
            except APIError as error:
                return error.code

    results = await asyncio.gather(
        commit("P33 first", first_preview.preview_token),
        commit("P33 second", second_preview.preview_token),
    )
    assert sorted(results) == ["P33 first", "reimbursement_preview_stale"] or sorted(results) == [
        "P33 second",
        "reimbursement_preview_stale",
    ]
    await engine.dispose()


async def test_p33_claim_matrix_preview_commit_validation_parity_and_zero_writes(
    session: AsyncSession,
) -> None:
    bank, expenses = await seed(session)
    service = ReimbursementService(session)

    async def assert_parity(
        claim_id,
        draft: ReimbursementClaimReplace,
        code: str,  # type: ignore[no-untyped-def]
    ) -> None:
        before = (await service.get(claim_id)).model_dump(mode="json")
        with pytest.raises(APIError) as preview_error:
            await service.preview(claim_id, draft)
        with pytest.raises(APIError) as commit_error:
            await service.update(claim_id, draft)
        assert preview_error.value.code == commit_error.value.code == code
        assert (await service.get(claim_id)).model_dump(mode="json") == before

    def replacement(claim, *, amount: int | None = None):  # type: ignore[no-untyped-def]
        return ReimbursementClaimReplace(
            expected_version=claim.version,
            title=claim.title,
            note=claim.note,
            counterparty_name=claim.counterparty_name,
            expected_date=claim.expected_date,
            expenses=[
                ReimbursementAllocationDraft(
                    id=allocation.id,
                    transaction_id=allocation.transaction_id,
                    amount_minor=(amount if amount is not None else allocation.amount_minor),
                )
                for allocation in claim.expenses
            ],
        )

    voidable = await service.create(
        ReimbursementClaimDraft(
            title="P33 voided",
            counterparty_name="公司",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=5000)
            ],
        ),
        uuid4(),
    )
    voided = await service.lifecycle(voidable.id, voidable.version, "void")
    await assert_parity(voided.id, replacement(voided), "reimbursement_invalid_status_transition")

    cancelled = await service.create(
        ReimbursementClaimDraft(
            title="P33 cancelled",
            counterparty_name="公司",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[1].id, amount_minor=5000)
            ],
        ),
        uuid4(),
    )
    cancelled = await service.lifecycle(cancelled.id, cancelled.version, "submit")
    cancelled = await service.lifecycle(cancelled.id, cancelled.version, "cancel_outstanding")
    await assert_parity(
        cancelled.id,
        replacement(cancelled, amount=4_999),
        "reimbursement_claim_cancelled",
    )
    archived = await service.lifecycle(cancelled.id, cancelled.version, "archive")
    await assert_parity(archived.id, replacement(archived), "reimbursement_claim_archived")

    locked = await service.create(
        ReimbursementClaimDraft(
            title="P33 locked",
            counterparty_name="甲",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=5000),
                ReimbursementAllocationDraft(transaction_id=expenses[2].id, amount_minor=5000),
            ],
        ),
        uuid4(),
    )
    await service.create_receipt(
        locked.id,
        ReimbursementReceiptDraft(
            expected_claim_version=locked.version,
            amount_minor=1000,
            received_at=datetime.now(UTC) - timedelta(seconds=1),
            destination_account_id=bank.id,
            title="P33 lock receipt",
        ),
        uuid4(),
    )
    locked = await service.get(locked.id)
    await assert_parity(
        locked.id,
        replacement(locked, amount=999),
        "reimbursement_allocation_locked",
    )
    second_expense = locked.expenses[1]
    removal = ReimbursementClaimReplace(
        expected_version=locked.version,
        title=locked.title,
        counterparty_name=locked.counterparty_name,
        expenses=[
            ReimbursementAllocationDraft(
                id=second_expense.id,
                transaction_id=second_expense.transaction_id,
                amount_minor=second_expense.amount_minor,
            )
        ],
    )
    await assert_parity(locked.id, removal, "reimbursement_allocation_locked")


async def test_p33_preview_external_dependencies_stale_without_consuming_token(
    session: AsyncSession,
) -> None:
    bank, expenses = await seed(session)
    service = ReimbursementService(session)
    claim = await service.create(
        ReimbursementClaimDraft(
            title="P33 external claim",
            counterparty_name="公司",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=5000)
            ],
        ),
        uuid4(),
    )
    draft = ReimbursementClaimReplace(
        expected_version=claim.version,
        title="P33 external claim renamed",
        counterparty_name=claim.counterparty_name,
        expenses=[
            ReimbursementAllocationDraft(
                id=claim.expenses[0].id, transaction_id=expenses[0].id, amount_minor=5000
            )
        ],
    )
    capacity_preview = await service.preview(claim.id, draft)
    await service.create(
        ReimbursementClaimDraft(
            title="P33 competing claim",
            counterparty_name="客户",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=1000)
            ],
        ),
        uuid4(),
    )
    before = (await service.get(claim.id)).model_dump(mode="json")
    operations_before = await session.scalar(select(func.count(ReimbursementOperation.id)))
    with pytest.raises(APIError) as capacity_stale:
        await service.update(
            claim.id,
            draft,
            preview_token=capacity_preview.preview_token,
            idempotency_key=uuid4(),
        )
    assert capacity_stale.value.code == "reimbursement_preview_stale"
    assert (await service.get(claim.id)).model_dump(mode="json") == before
    assert await session.scalar(select(func.count(ReimbursementOperation.id))) == operations_before
    assert (
        await session.scalar(
            select(ReimbursementPreview.consumed_at).where(
                ReimbursementPreview.id == capacity_preview.preview_token
            )
        )
        is None
    )

    fresh = await service.get(claim.id)
    fresh_draft = draft.model_copy(update={"expected_version": fresh.version})
    unaffected_preview = await service.preview(claim.id, fresh_draft)
    await AccountService(session).create(
        AccountDraft(name="P33 unrelated", kind=AccountKind.CASH, opening_balance_minor=0)
    )
    updated = await service.update(
        claim.id,
        fresh_draft,
        preview_token=unaffected_preview.preview_token,
        idempotency_key=uuid4(),
    )
    assert updated.title == fresh_draft.title

    receipt_claim = await service.create(
        ReimbursementClaimDraft(
            title="P33 external receipt",
            counterparty_name="公司",
            expenses=[
                ReimbursementAllocationDraft(transaction_id=expenses[1].id, amount_minor=5000)
            ],
        ),
        uuid4(),
    )
    receipt_draft = ReimbursementReceiptDraft(
        expected_claim_version=receipt_claim.version,
        amount_minor=1000,
        received_at=datetime.now(UTC) - timedelta(seconds=1),
        destination_account_id=bank.id,
        title="P33 external account receipt",
    )
    account_preview = await service.receipt_preview(receipt_claim.id, receipt_draft)
    bank = await AccountService(session).archive(bank.id, bank.version)
    receipt_before = (await service.get(receipt_claim.id)).model_dump(mode="json")
    operations_before = await session.scalar(select(func.count(ReimbursementOperation.id)))
    with pytest.raises(APIError) as account_stale:
        await service.create_receipt(
            receipt_claim.id,
            receipt_draft,
            uuid4(),
            preview_token=account_preview.preview_token,
        )
    assert account_stale.value.code == "reimbursement_preview_stale"
    assert (await service.get(receipt_claim.id)).model_dump(mode="json") == receipt_before
    assert await session.scalar(select(func.count(ReimbursementOperation.id))) == operations_before
    assert (
        await session.scalar(
            select(ReimbursementPreview.consumed_at).where(
                ReimbursementPreview.id == account_preview.preview_token
            )
        )
        is None
    )
