import asyncio
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from os import environ
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p6_schemas import (
    ReimbursementAllocationDraft,
    ReimbursementClaimDraft,
    ReimbursementClaimReplace,
    ReimbursementPartyDraft,
    ReimbursementReceiptDraft,
    ReimbursementReceiptReplace,
)
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import (
    AccountKind,
    CategoryDirection,
    ReimbursementClaimStatus,
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
            parties=[
                ReimbursementPartyDraft(
                    name="公司",
                    allocations=[
                        ReimbursementAllocationDraft(
                            transaction_id=expenses[0].id, amount_minor=10_000
                        ),
                        ReimbursementAllocationDraft(
                            transaction_id=expenses[1].id, amount_minor=15_000
                        ),
                    ],
                ),
                ReimbursementPartyDraft(
                    name="客户",
                    allocations=[
                        ReimbursementAllocationDraft(
                            transaction_id=expenses[2].id, amount_minor=20_000
                        )
                    ],
                ),
            ],
        ),
        uuid4(),
    )
    assert claim.total_claimed_minor == 45_000
    assert claim.status.value == "draft"
    receipt_draft = ReimbursementReceiptDraft(
        expected_claim_version=claim.version,
        party_id=claim.parties[0].id,
        amount_minor=18_000,
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
            parties=[
                ReimbursementPartyDraft(
                    name="甲",
                    allocations=[
                        ReimbursementAllocationDraft(
                            transaction_id=expenses[0].id, amount_minor=7_000
                        )
                    ],
                )
            ],
        ),
        uuid4(),
    )
    with pytest.raises(APIError) as caught:
        await service.create(
            ReimbursementClaimDraft(
                title="二",
                parties=[
                    ReimbursementPartyDraft(
                        name="乙",
                        allocations=[
                            ReimbursementAllocationDraft(
                                transaction_id=expenses[0].id, amount_minor=4_000
                            )
                        ],
                    )
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
            parties=[
                ReimbursementPartyDraft(
                    name="公司",
                    allocations=[
                        ReimbursementAllocationDraft(
                            transaction_id=expenses[0].id, amount_minor=10_000
                        ),
                        ReimbursementAllocationDraft(
                            transaction_id=expenses[1].id, amount_minor=10_000
                        ),
                    ],
                )
            ],
        ),
        uuid4(),
    )
    receipt = await service.create_receipt(
        claim.id,
        ReimbursementReceiptDraft(
            expected_claim_version=claim.version,
            party_id=claim.parties[0].id,
            amount_minor=8_000,
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
        party_id=claim.parties[0].id,
        amount_minor=12_000,
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
    second = claim.parties[0].allocations[1]
    claim = await service.update(
        claim.id,
        ReimbursementClaimReplace(
            expected_version=claim.version,
            title=claim.title,
            parties=[
                ReimbursementPartyDraft(
                    id=claim.parties[0].id,
                    name=claim.parties[0].name,
                    allocations=[
                        ReimbursementAllocationDraft(
                            id=second.id,
                            transaction_id=second.transaction_id,
                            amount_minor=20_000,
                        )
                    ],
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


async def test_preview_filters_lifecycle_and_idempotency(session: AsyncSession) -> None:
    _bank, expenses = await seed(session)
    service = ReimbursementService(session)
    key = uuid4()
    draft = ReimbursementClaimDraft(
        title="可搜索差旅",
        note="七月项目",
        parties=[
            ReimbursementPartyDraft(
                name="原主体",
                allocations=[
                    ReimbursementAllocationDraft(transaction_id=expenses[0].id, amount_minor=5_000)
                ],
            )
        ],
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
        parties=[
            ReimbursementPartyDraft(
                id=claim.parties[0].id,
                name="新主体",
                allocations=[
                    ReimbursementAllocationDraft(
                        id=claim.parties[0].allocations[0].id,
                        transaction_id=expenses[0].id,
                        amount_minor=6_000,
                    )
                ],
            )
        ],
    )
    preview = await service.preview(claim.id, proposed)
    assert preview.proposed.parties[0].name == "新主体"
    assert preview.proposed.parties[0].allocations[0].amount_minor == 6_000
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
                    parties=[
                        ReimbursementPartyDraft(
                            name=f"主体 {index}",
                            allocations=[
                                ReimbursementAllocationDraft(
                                    transaction_id=expenses[index].id, amount_minor=5_000
                                )
                            ],
                        )
                    ],
                ),
                uuid4(),
            )
        )
    source, destination = claims
    await session.execute(
        text("UPDATE reimbursement_parties SET position=1 WHERE id=:id"),
        {"id": source.parties[0].id},
    )
    await session.execute(
        text("UPDATE reimbursement_allocations SET position=1 WHERE id=:id"),
        {"id": source.parties[0].allocations[0].id},
    )
    await session.execute(
        text("UPDATE reimbursement_parties SET claim_id=:target WHERE id=:id"),
        {"target": destination.id, "id": source.parties[0].id},
    )
    await session.execute(
        text("UPDATE reimbursement_allocations SET claim_id=:target WHERE id=:id"),
        {"target": destination.id, "id": source.parties[0].allocations[0].id},
    )
    with pytest.raises(DBAPIError, match="reimbursement claim requires matrix rows"):
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
                        parties=[
                            ReimbursementPartyDraft(
                                name=name,
                                allocations=[
                                    ReimbursementAllocationDraft(
                                        transaction_id=expenses[0].id,
                                        amount_minor=7_000,
                                    )
                                ],
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
                parties=[
                    ReimbursementPartyDraft(
                        name="公司",
                        allocations=[
                            ReimbursementAllocationDraft(
                                transaction_id=expenses[expense_index].id,
                                amount_minor=5_000,
                            )
                        ],
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
        party_id=live.parties[0].id,
        amount_minor=1_000,
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
            "party_id": cancelled.parties[0].id,
        }
    )
    await assert_same_error(cancelled, cancelled_draft, "reimbursement_claim_cancelled")
    archived = await service.lifecycle(cancelled.id, cancelled.version, "archive")
    await assert_same_error(
        archived,
        cancelled_draft.model_copy(update={"expected_claim_version": archived.version}),
        "reimbursement_claim_archived",
    )
