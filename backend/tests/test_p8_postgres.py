from collections.abc import AsyncIterator
from datetime import UTC, datetime
from os import environ
from uuid import UUID, uuid4

import pytest
import pytest_asyncio
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft
from fiscal_api.api.p3_schemas import MAX_MINOR_UNITS, TransactionDraft
from fiscal_api.api.p8_schemas import (
    AIFieldConfidences,
    AIParseRequest,
    AIProposalCreate,
    AIProviderResult,
    AIProviderSettingsReplace,
    AISettingsReplace,
)
from fiscal_api.core.config import Settings
from fiscal_api.core.errors import APIError
from fiscal_api.core.provider_credentials import ProviderCredentialCipher
from fiscal_api.db.models import (
    AccountKind,
    AIProposal,
    AISettings,
    CashFlowItem,
    CategoryDirection,
    LedgerTransaction,
    TransactionKind,
    TransactionRevision,
)
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.ai import AIService
from fiscal_api.services.ai_provider import AIProvider, DisabledAIProvider
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.security import AuthenticatedDevice
from fiscal_api.services.transactions import TransactionService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


class FakeProvider(AIProvider):
    configured = True
    provider_id = "fake"
    model_id = "p8-test"

    def __init__(
        self,
        *,
        amount: int = 2_000,
        confidence: int = 9_500,
        kind: TransactionKind = TransactionKind.EXPENSE,
        failures: int = 0,
        occurred_at: datetime | None = None,
    ) -> None:
        self.amount = amount
        self.confidence = confidence
        self.kind = kind
        self.failures = failures
        self.occurred_at = occurred_at or datetime(2026, 7, 16, 4, tzinfo=UTC)
        self.calls = 0

    async def parse(self, request: AIParseRequest) -> AIProviderResult:
        self.calls += 1
        if self.calls <= self.failures:
            raise APIError(status_code=503, code="ai_provider_unavailable", message="暂时不可用")
        account = next(item for item in request.accounts if item.kind == "debit")
        category = next(
            (item for item in request.categories if item.direction == self.kind.value), None
        )
        destination = next((item for item in request.accounts if item.kind == "credit"), None)
        confidence = self.confidence
        return AIProviderResult(
            kind=self.kind,
            amount_minor=self.amount,
            occurred_at=self.occurred_at,
            title="AI 午餐" if self.kind is TransactionKind.EXPENSE else "AI 收入",
            account_id=account.id,
            category_id=category.id if category is not None else None,
            destination_account_id=(
                destination.id if self.kind is TransactionKind.REPAYMENT and destination else None
            ),
            confidences=AIFieldConfidences(
                kind=confidence,
                amount_minor=confidence,
                occurred_at=confidence,
                title=confidence,
                account_id=confidence,
                category_id=confidence,
            ),
            overall_confidence_bps=confidence,
            missing_fields=[],
        )


@pytest_asyncio.fixture
async def session() -> AsyncIterator[AsyncSession]:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE ai_proposals, ai_settings, cash_flow_item_revisions, cash_flow_items, "
                "cash_flow_series, reimbursement_operations, "
                "reimbursement_receipt_revisions, reimbursement_claim_revisions, "
                "reimbursement_receipt_allocations, reimbursement_receipts, "
                "reimbursement_allocations, reimbursement_parties, reimbursement_claims, "
                "installment_plan_revisions, installment_ledger_links, installment_operations, "
                "installment_periods, installment_plans, transaction_revisions, postings, "
                "transactions, credit_cycles, categories, accounts CASCADE"
            )
        )
        await connection.execute(
            text(
                "INSERT INTO ai_settings "
                "(id,auto_execute_enabled,ocr_source_enabled,shortcut_text_source_enabled,"
                "auto_execute_limit_minor,minimum_confidence_bps,"
                "version,created_at,updated_at) "
                "VALUES (1,false,false,false,100000,9000,1,now(),now())"
            )
        )
    async with factory() as value:
        yield value
    await engine.dispose()


async def test_active_device_updates_encrypted_provider_configuration(
    session: AsyncSession,
) -> None:
    await seed(session)
    cipher = ProviderCredentialCipher("test-provider-root-secret-at-least-32-bytes")
    service = AIService(
        session,
        DisabledAIProvider(),
        runtime_settings=Settings(environment="test"),
        credential_cipher=cipher,
    )
    current = await service.get_provider_settings()
    device = AuthenticatedDevice(
        id=uuid4(), label="iPhone", role="device", status="active", version=1
    )
    replacement = AIProviderSettingsReplace(
        base_url="https://api.example.com/v1",
        model="provider-model",
        api_key="secret-provider-key",
        expected_version=current.version,
    )
    configured = await service.update_provider_settings(replacement, device)
    assert configured.api_key_configured
    assert configured.base_url == "https://api.example.com/v1"
    row = await session.get(AISettings, 1)
    assert row is not None and row.provider_api_key_ciphertext is not None
    assert "secret-provider-key" not in row.provider_api_key_ciphertext
    assert cipher.decrypt(row.provider_api_key_ciphertext, row.provider_key_version or 0) == (
        "secret-provider-key"
    )
    assert (await service.get_settings()).provider_configured

    retained = await service.update_provider_settings(
        AIProviderSettingsReplace(
            base_url="https://api.example.com/v1",
            model="provider-model-v2",
            expected_version=configured.version,
        ),
        device,
    )
    assert retained.api_key_configured and retained.model == "provider-model-v2"


async def seed(session: AsyncSession, *, opening: int = 100_000) -> tuple[UUID, UUID, UUID]:
    account = await AccountService(session).create(
        AccountDraft(name="P8 储蓄卡", kind=AccountKind.DEBIT, opening_balance_minor=opening)
    )
    expense = await CategoryService(session).create(
        CategoryDraft(
            name="P8 餐饮",
            direction=CategoryDirection.EXPENSE,
            icon="fork.knife",
            color_hex="#334455",
        )
    )
    income = await CategoryService(session).create(
        CategoryDraft(
            name="P8 工资",
            direction=CategoryDirection.INCOME,
            icon="banknote",
            color_hex="#225544",
        )
    )
    return account.id, expense.id, income.id


async def test_pending_idempotency_edit_execute_and_undo(session: AsyncSession) -> None:
    account_id, expense_id, _income_id = await seed(session)
    provider = FakeProvider()
    service = AIService(session, provider)
    key = uuid4()
    created, replay = await service.create(AIProposalCreate(source="text", text="午餐 20 元"), key)
    assert not replay and created.status == "pending" and provider.calls == 1
    same, replay = await service.create(AIProposalCreate(source="text", text="午餐 20 元"), key)
    assert replay and same.id == created.id and provider.calls == 1
    with pytest.raises(APIError, match="幂等"):
        await service.create(AIProposalCreate(source="text", text="午餐 21 元"), key)

    edited = await service.edit(
        created.id,
        TransactionDraft(
            kind=TransactionKind.EXPENSE,
            amount_minor=2_100,
            occurred_at=datetime(2026, 7, 16, 5, tzinfo=UTC),
            title="修正午餐",
            account_id=account_id,
            category_id=expense_id,
        ),
        created.version,
    )
    assert edited.status == "pending" and edited.amount_minor == 2_100
    executed = await service.execute(edited.id, edited.version)
    assert executed.proposal.status == "executed"
    assert executed.transaction is not None and executed.transaction.source == "ai_text"
    creation_revisions = await session.scalar(
        select(text("count(*)")).select_from(TransactionRevision)
    )
    repeated_execute = await service.execute(edited.id, edited.version)
    assert repeated_execute.proposal == executed.proposal
    assert repeated_execute.transaction is not None
    assert repeated_execute.transaction.id == executed.transaction.id
    assert (
        await session.scalar(select(text("count(*)")).select_from(TransactionRevision))
        == creation_revisions
    )
    assert (await AccountService(session).get(account_id)).current_balance_minor == 97_900

    changed = await TransactionService(session).update(
        executed.transaction.id,
        TransactionDraft(
            kind=TransactionKind.EXPENSE,
            amount_minor=2_200,
            occurred_at=datetime(2026, 7, 16, 5, tzinfo=UTC),
            title="普通编辑",
            account_id=account_id,
            category_id=expense_id,
        ),
        executed.transaction.version,
    )
    with pytest.raises(APIError) as stale_undo:
        await service.undo(
            executed.proposal.id,
            executed.proposal.version,
            executed.transaction.version,
        )
    assert stale_undo.value.code == "ai_undo_transaction_changed"
    assert (await AccountService(session).get(account_id)).current_balance_minor == 97_800

    await TransactionService(session).void(changed.id, changed.version)
    assert (await AccountService(session).get(account_id)).current_balance_minor == 100_000


async def test_unedited_ai_undo_is_exactly_replayable(session: AsyncSession) -> None:
    account_id, expense_id, _income_id = await seed(session)
    service = AIService(session, FakeProvider())
    created, _ = await service.create(
        AIProposalCreate(source="text", text="可撤销午餐 20 元"), uuid4()
    )
    edited = await service.edit(
        created.id,
        TransactionDraft(
            kind=TransactionKind.EXPENSE,
            amount_minor=2_100,
            occurred_at=datetime(2026, 7, 16, 5, tzinfo=UTC),
            title="可撤销午餐",
            account_id=account_id,
            category_id=expense_id,
        ),
        created.version,
    )
    executed = await service.execute(edited.id, edited.version)
    assert executed.transaction is not None
    undone = await service.undo(
        executed.proposal.id,
        executed.proposal.version,
        executed.transaction.version,
    )
    assert undone.proposal.status == "undone"
    assert undone.transaction is not None
    revisions_before = await session.scalar(
        select(text("count(*)")).select_from(TransactionRevision)
    )
    repeated = await service.undo(
        executed.proposal.id,
        executed.proposal.version,
        executed.transaction.version,
    )
    revisions_after = await session.scalar(
        select(text("count(*)")).select_from(TransactionRevision)
    )
    assert repeated.proposal == undone.proposal
    assert revisions_after == revisions_before


async def test_p9_sources_require_settings_and_replay_after_disable(
    session: AsyncSession,
) -> None:
    await seed(session)
    service = AIService(session, FakeProvider())
    with pytest.raises(APIError) as disabled:
        await service.create(AIProposalCreate(source="ocr", text="午餐 20 元"), uuid4())
    assert disabled.value.code == "ai_source_disabled"

    settings = await service.get_settings()
    enabled = await service.update_settings(
        AISettingsReplace(
            auto_execute_enabled=True,
            ocr_source_enabled=True,
            shortcut_text_source_enabled=True,
            auto_execute_limit_minor=100_000,
            minimum_confidence_bps=9_000,
            expected_version=settings.version,
        )
    )
    ocr_key = uuid4()
    ocr, replay = await service.create(AIProposalCreate(source="ocr", text="午餐 20 元"), ocr_key)
    shortcut, _ = await service.create(
        AIProposalCreate(source="shortcut_text", text="午餐 20 元"), uuid4()
    )
    assert not replay
    assert ocr.content_fingerprint != shortcut.content_fingerprint
    assert ocr.status == "executed" and ocr.transaction_id is not None
    ocr_transaction = await session.get(LedgerTransaction, ocr.transaction_id)
    assert ocr_transaction is not None and ocr_transaction.source == "ocr"

    await service.update_settings(
        AISettingsReplace(
            auto_execute_enabled=False,
            ocr_source_enabled=False,
            shortcut_text_source_enabled=False,
            auto_execute_limit_minor=100_000,
            minimum_confidence_bps=9_000,
            expected_version=enabled.version,
        )
    )
    same, replay = await service.create(AIProposalCreate(source="ocr", text="午餐 20 元"), ocr_key)
    assert replay and same.id == ocr.id
    with pytest.raises(APIError) as newly_disabled:
        await service.create(AIProposalCreate(source="ocr", text="晚餐 30 元"), uuid4())
    assert newly_disabled.value.code == "ai_source_disabled"


async def test_ignore_and_failed_retry_state_machine(session: AsyncSession) -> None:
    await seed(session)
    failed_provider = FakeProvider(failures=1)
    service = AIService(session, failed_provider)
    with pytest.raises(APIError) as failure:
        await service.create(AIProposalCreate(source="text", text="失败后重试"), uuid4())
    assert failure.value.code == "ai_provider_unavailable"
    proposal = await session.scalar(select(AIProposal).where(AIProposal.status == "failed"))
    assert proposal is not None
    retried = await service.retry(proposal.id, proposal.version)
    assert retried.status == "pending" and failed_provider.calls == 2
    ignored = await service.ignore(retried.id, retried.version)
    assert ignored.status == "ignored"
    with pytest.raises(APIError) as conflict:
        await service.execute(ignored.id, ignored.version)
    assert conflict.value.code == "ai_proposal_state_conflict"
    assert await service.get(ignored.id) == ignored


@pytest.mark.parametrize(
    ("amount", "confidence", "expected"),
    [
        (99_999, 9_000, "executed"),
        (100_000, 9_000, "executed"),
        (100_001, 9_001, "pending"),
        (99_999, 8_999, "pending"),
    ],
)
async def test_automatic_execution_boundaries(
    session: AsyncSession, amount: int, confidence: int, expected: str
) -> None:
    await seed(session, opening=200_000)
    service = AIService(session, FakeProvider(amount=amount, confidence=confidence))
    settings = await service.get_settings()
    await service.update_settings(
        AISettingsReplace(
            auto_execute_enabled=True,
            ocr_source_enabled=False,
            shortcut_text_source_enabled=False,
            auto_execute_limit_minor=100_000,
            minimum_confidence_bps=9_000,
            expected_version=settings.version,
        )
    )
    proposal, _replay = await service.create(
        AIProposalCreate(source="text", text=f"边界 {amount}"), uuid4()
    )
    assert proposal.status == expected
    count = await session.scalar(select(text("count(*)")).select_from(LedgerTransaction))
    assert count == (1 if expected == "executed" else 0)


async def test_ledger_auto_validation_failure_preserves_full_pending_draft(
    session: AsyncSession,
) -> None:
    await seed(session, opening=MAX_MINOR_UNITS)
    service = AIService(
        session,
        FakeProvider(amount=1, confidence=9_500, kind=TransactionKind.INCOME),
    )
    settings = await service.get_settings()
    await service.update_settings(
        AISettingsReplace(
            auto_execute_enabled=True,
            ocr_source_enabled=False,
            shortcut_text_source_enabled=False,
            auto_execute_limit_minor=100_000,
            minimum_confidence_bps=9_000,
            expected_version=settings.version,
        )
    )
    proposal, _replay = await service.create(
        AIProposalCreate(source="text", text="收入一分钱"), uuid4()
    )
    assert proposal.status == "pending"
    assert proposal.kind is TransactionKind.INCOME
    assert proposal.amount_minor == 1
    assert proposal.account_id is not None and proposal.category_id is not None
    assert "ledger_validation_failed" in proposal.reason_codes
    assert await session.scalar(select(text("count(*)")).select_from(LedgerTransaction)) == 0


async def test_repayment_requires_human_cycle_edit_then_executes_as_ai_text(
    session: AsyncSession,
) -> None:
    debit_id, expense_id, _income_id = await seed(session, opening=100_000)
    credit = await AccountService(session).create(
        AccountDraft(
            name="P8 信用卡",
            kind=AccountKind.CREDIT,
            opening_balance_minor=0,
            credit_limit_minor=100_000,
            statement_day=10,
            due_day=22,
        )
    )
    purchase = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=5_000,
            occurred_at=datetime(2026, 7, 16, 4, tzinfo=UTC),
            title="待还消费",
            account_id=credit.id,
            category_id=expense_id,
        ),
        uuid4(),
    )
    assert purchase.credit_cycle_id is not None
    service = AIService(
        session,
        FakeProvider(amount=1_000, confidence=9_900, kind=TransactionKind.REPAYMENT),
    )
    pending, _replay = await service.create(
        AIProposalCreate(source="text", text="还信用卡 10 元"), uuid4()
    )
    assert pending.status == "pending" and pending.credit_cycle_id is None
    with pytest.raises(APIError) as incomplete:
        await service.execute(pending.id, pending.version)
    assert incomplete.value.code == "invalid_transaction_configuration"
    preserved = await service.get(pending.id)
    assert preserved.status == "pending" and preserved.transaction_id is None
    edited = await service.edit(
        pending.id,
        TransactionDraft(
            kind=TransactionKind.REPAYMENT,
            amount_minor=1_000,
            occurred_at=datetime(2026, 7, 16, 5, tzinfo=UTC),
            title="确认还款",
            account_id=debit_id,
            destination_account_id=credit.id,
            credit_cycle_id=purchase.credit_cycle_id,
        ),
        pending.version,
    )
    assert edited.credit_cycle_id == purchase.credit_cycle_id
    executed = await service.execute(edited.id, edited.version)
    assert executed.transaction is not None
    assert executed.transaction.kind is TransactionKind.REPAYMENT
    assert executed.transaction.source == "ai_text"


async def test_future_ai_proposal_requires_confirmation_and_creates_only_cash_flow(
    session: AsyncSession,
) -> None:
    await seed(session)
    service = AIService(
        session,
        FakeProvider(occurred_at=datetime(2026, 8, 1, 4, tzinfo=UTC)),
    )
    settings = await service.get_settings()
    await service.update_settings(
        AISettingsReplace(
            auto_execute_enabled=True,
            ocr_source_enabled=False,
            shortcut_text_source_enabled=False,
            auto_execute_limit_minor=100_000,
            minimum_confidence_bps=9_000,
            expected_version=settings.version,
        )
    )

    pending, _replay = await service.create(
        AIProposalCreate(source="text", text="计划 8 月 1 日午餐 20 元"), uuid4()
    )
    assert pending.target == "cash_flow"
    assert pending.status == "pending"
    assert pending.transaction_id is None
    assert "future_cash_flow_requires_confirmation" in pending.reason_codes

    executed = await service.execute(pending.id, pending.version)
    assert executed.transaction is None
    assert executed.cash_flow_item is not None
    assert executed.cash_flow_item.status == "expected"
    assert executed.proposal.cash_flow_item_id is not None
    assert await session.scalar(select(text("count(*)")).select_from(LedgerTransaction)) == 0

    undone = await service.undo(executed.proposal.id, executed.proposal.version, None)
    assert undone.cash_flow_item is not None
    assert undone.cash_flow_item.status == "cancelled"
    assert await session.scalar(select(text("count(*)")).select_from(CashFlowItem)) == 1
