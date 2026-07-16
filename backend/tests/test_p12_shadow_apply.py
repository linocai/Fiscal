import asyncio
from datetime import UTC, date, datetime
from os import environ
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from fiscal_api.core.config import get_settings
from fiscal_api.db.models import LedgerTransaction, MigrationObjectLink
from fiscal_api.legacy_migration.apply import (
    AccountImport,
    CategoryImport,
    ClaimImport,
    LegacyApplyConflict,
    LegacyManifest,
    LegacyShadowApplier,
    ReceiptImport,
    SkippedImport,
    SourceIdentity,
    TransactionImport,
)

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
BACKEND_ROOT = Path(__file__).resolve().parents[1]


def _source(object_type: str, object_id: str, marker: str) -> SourceIdentity:
    return SourceIdentity(object_type, object_id, marker * 64)


def _manifest(*, account_hash: str = "a", import_old_income: bool = False) -> LegacyManifest:
    transactions = [
        TransactionImport(
            source=_source("financial_entries", "expense-1", "c"),
            kind="expense",
            amount_minor=500,
            occurred_at=datetime(2026, 6, 1, 4, tzinfo=UTC),
            title="垫付",
            account_source_id="account-1",
            category_source_id="category-1",
        )
    ]
    if import_old_income:
        transactions.append(
            TransactionImport(
                source=_source("financial_entries", "old-income-1", "f"),
                kind="income",
                amount_minor=500,
                occurred_at=datetime(2026, 6, 15, 4, tzinfo=UTC),
                title="旧报销收入",
                account_source_id="account-1",
            )
        )
    return LegacyManifest(
        source_database_fingerprint="1" * 64,
        accounts=(
            AccountImport(
                source=_source("accounts", "account-1", account_hash),
                name="P12 影子卡",
                kind="debit",
                opening_balance_minor=10_000,
                last_four="3495",
            ),
        ),
        categories=(
            CategoryImport(
                source=_source("categories", "category-1", "b"),
                name="工作垫付",
                direction="expense",
            ),
        ),
        transactions=tuple(transactions),
        claims=(
            ClaimImport(
                source=_source("reimbursement_claims", "claim-1", "d"),
                title="公司报销",
                expense_transaction_source_id="expense-1",
                amount_minor=500,
                party_name="公司",
            ),
        ),
        receipts=(
            ReceiptImport(
                source=_source("reimbursement_receipts", "receipt-1", "e"),
                claim_source_id="claim-1",
                destination_account_source_id="account-1",
                amount_minor=500,
                received_at=datetime(2026, 6, 15, 4, tzinfo=UTC),
                title="公司报销到账",
                suppressed_income_source_id="old-income-1",
            ),
        ),
        skipped=(
            SkippedImport(
                source=_source("financial_entries", "orphan-repayment", "9"),
                reason="opening_liability_adjustment_without_cash_flow",
            ),
        ),
        selection_scope={"period_end": date(2026, 7, 14).isoformat()},
    )


def test_manifest_rejects_importing_reimbursement_income_twice() -> None:
    with pytest.raises(LegacyApplyConflict) as raised:
        LegacyShadowApplier._validate(_manifest(import_old_income=True))
    assert raised.value.code == "duplicate_reimbursement_income"


def test_manifest_keeps_orphan_repayment_as_an_explicit_skip() -> None:
    manifest = _manifest()
    LegacyShadowApplier._validate(manifest)
    assert manifest.skipped[0].source.object_id == "orphan-repayment"
    assert manifest.skipped[0].reason == "opening_liability_adjustment_without_cash_flow"


def _config() -> Config:
    result = Config(str(BACKEND_ROOT / "alembic.ini"))
    result.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return result


async def _exercise_shadow_apply() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.execute(
            text(
                "TRUNCATE migration_runs, reimbursement_claims, accounts, categories CASCADE"
            )
        )
    async with session_factory() as session:
        first = await LegacyShadowApplier(session).apply(_manifest(), code_revision="p12-test")
        assert first.created == 5
        assert first.unchanged == 0
        assert first.skipped == 1
    async with session_factory() as session:
        replay = await LegacyShadowApplier(session).apply(_manifest(), code_revision="p12-test")
        assert replay.created == 0
        assert replay.unchanged == 5
        assert replay.skipped == 1
        transaction_count = await session.scalar(
            select(func.count()).select_from(LedgerTransaction)
        )
        link_count = await session.scalar(select(func.count()).select_from(MigrationObjectLink))
        receipt_count = await session.scalar(
            select(func.count())
            .select_from(LedgerTransaction)
            .where(LedgerTransaction.kind == "reimbursement_receipt")
        )
        ordinary_income_count = await session.scalar(
            select(func.count())
            .select_from(LedgerTransaction)
            .where(LedgerTransaction.kind == "income")
        )
        assert transaction_count == 2
        assert link_count == 5
        assert receipt_count == 1
        assert ordinary_income_count == 0
    async with session_factory() as session:
        with pytest.raises(LegacyApplyConflict) as raised:
            await LegacyShadowApplier(session).apply(
                _manifest(account_hash="8"), code_revision="p12-test"
            )
        assert raised.value.code == "source_hash_changed"
    await engine.dispose()


@pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
def test_shadow_apply_rerun_hash_conflict_and_reimbursement_deduplication(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
    get_settings.cache_clear()
    command.upgrade(_config(), "head")
    asyncio.run(_exercise_shadow_apply())
    get_settings.cache_clear()
