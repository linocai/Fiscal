from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from os import environ
from pathlib import Path
from typing import TypeVar
from uuid import UUID, uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p31_schemas import (
    CategoryMergeCommitRequest,
    CategoryMergePreviewRequest,
    MerchantDraft,
    MerchantMappingReceipt,
    MerchantMappingRequest,
)
from fiscal_api.core.config import get_settings
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import AccountKind, CategoryDirection, TransactionKind
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.repositories.merchants import MerchantRepository
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.archive import ArchiveService
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.merchants import MerchantService
from fiscal_api.services.transactions import TransactionService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")

T = TypeVar("T")

_IDENTIFIERS_SQL = text(
    "SELECT id::text, merchant_id::text, normalized_key, display_value, kind "
    "FROM merchant_identifiers ORDER BY id"
)
_MAPPING_SQL = text(
    "SELECT id::text, transaction_id::text, merchant_id::text, version "
    "FROM transaction_merchant_mappings ORDER BY id"
)
_RECEIPTS_SQL = text(
    "SELECT id::text, idempotency_key::text, request_hash, action, receipt::text "
    "FROM merchant_operations ORDER BY id"
)
_DATA_REVISION_SQL = text("SELECT revision FROM data_revision WHERE id = 1")
_BALANCES_FINGERPRINT_SQL = text(
    "SELECT coalesce(string_agg(id::text || ':' || current_balance::text, ',' ORDER BY id), '') "
    "FROM (SELECT a.id, a.opening_balance_minor + coalesce(sum(p.amount_minor), 0) "
    "AS current_balance FROM accounts a LEFT JOIN postings p ON p.account_id = a.id "
    "GROUP BY a.id, a.opening_balance_minor) balances"
)
_TRANSACTIONS_FINGERPRINT_SQL = text(
    "SELECT coalesce(string_agg(id::text || ':' || category_id::text || ':' || "
    "version::text, ',' ORDER BY id), '') FROM transactions"
)
_PREVIEWS_COUNT_SQL = text("SELECT count(*) FROM category_transform_previews")
_OPERATIONS_COUNT_SQL = text("SELECT count(*) FROM category_transform_operations")


def _alembic_config() -> Config:
    return Config(str(Path(__file__).parents[1] / "alembic.ini"))


async def _create_database(name: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(
        make_url(TEST_DATABASE_URL).set(database="postgres").render_as_string(hide_password=False),
        isolation_level="AUTOCOMMIT",
    )
    try:
        async with engine.connect() as connection:
            await connection.execute(text(f'CREATE DATABASE "{name}"'))
    finally:
        await engine.dispose()


async def _drop_database(name: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(
        make_url(TEST_DATABASE_URL).set(database="postgres").render_as_string(hide_password=False),
        isolation_level="AUTOCOMMIT",
    )
    try:
        async with engine.connect() as connection:
            await connection.execute(
                text(
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                    "WHERE datname = :name AND pid <> pg_backend_pid()"
                ),
                {"name": name},
            )
            await connection.execute(text(f'DROP DATABASE IF EXISTS "{name}"'))
    finally:
        await engine.dispose()


async def _base_ledger(session: AsyncSession) -> tuple[UUID, UUID, UUID]:
    account = await AccountService(session).create(
        AccountDraft(
            name=f"P31 concurrent account {uuid4().hex}",
            kind=AccountKind.DEBIT,
            opening_balance_minor=0,
        )
    )
    category = await CategoryService(session).create(
        CategoryDraft(
            name=f"P31 concurrent category {uuid4().hex}",
            direction=CategoryDirection.EXPENSE,
            icon="tag",
            color_hex="#123456",
        )
    )
    transaction = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.EXPENSE,
            amount_minor=1_234,
            occurred_at="2026-08-14T10:00:00+08:00",  # type: ignore[arg-type]
            title="P31 concurrent evidence",
            account_id=account.id,
            category_id=category.id,
        ),
        uuid4(),
    )
    return account.id, category.id, transaction.id


def _synchronize_initial_operation_reads(
    monkeypatch: pytest.MonkeyPatch,
) -> Callable[[], int]:
    """Force both sessions past the pre-lock read before either can acquire the lock."""

    original = MerchantRepository.operation
    arrived = 0
    released = asyncio.Event()
    post_lock_reads = 0

    async def synchronized(self: MerchantRepository, key: UUID):
        nonlocal arrived, post_lock_reads
        if not getattr(self, "_p31_initial_operation_read", False):
            self._p31_initial_operation_read = True
            arrived += 1
            if arrived == 2:
                released.set()
            await released.wait()
        else:
            post_lock_reads += 1
        return await original(self, key)

    monkeypatch.setattr(MerchantRepository, "operation", synchronized)
    return lambda: post_lock_reads


def _synchronize_initial_transform_reads(
    monkeypatch: pytest.MonkeyPatch,
) -> Callable[[], int]:
    """Make both merge commits observe the empty operation table before locking."""

    original = CategoryService._transform_operation
    arrived = 0
    released = asyncio.Event()
    post_lock_reads = 0

    async def synchronized(
        self: CategoryService, idempotency_key: UUID, request_hash: str
    ) -> object:
        nonlocal arrived, post_lock_reads
        if not getattr(self, "_p31_initial_transform_read", False):
            self._p31_initial_transform_read = True
            arrived += 1
            if arrived == 2:
                released.set()
            await released.wait()
        else:
            post_lock_reads += 1
        return await original(self, idempotency_key, request_hash)

    monkeypatch.setattr(CategoryService, "_transform_operation", synchronized)
    return lambda: post_lock_reads


async def test_p31_concurrent_idempotency_rechecks_after_global_lock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    try:
        async with factory() as setup:
            _account_id, _category_id, transaction_id = await _base_ledger(setup)
            merchants = MerchantService(setup)
            first_merchant = await merchants.create(
                MerchantDraft(name=f"P31 first {uuid4().hex}", aliases=["P31 first alias"])
            )
            second_merchant = await merchants.create(
                MerchantDraft(name=f"P31 second {uuid4().hex}", aliases=[])
            )

        async def concurrently(
            request: MerchantMappingRequest,
            key: UUID,
            *,
            release: bool = False,
        ) -> tuple[MerchantMappingReceipt, MerchantMappingReceipt, int]:
            post_lock_reads = _synchronize_initial_operation_reads(monkeypatch)

            async def call() -> MerchantMappingReceipt:
                async with factory() as session:
                    service = MerchantService(session)
                    if release:
                        assert request.expected_mapping_version is not None
                        return await service.release_mapping(
                            transaction_id, request.expected_mapping_version, key
                        )
                    return await service.confirm_mapping(transaction_id, request, key)

            first, second = await asyncio.gather(call(), call())
            return first, second, post_lock_reads()

        confirm_key = uuid4()
        confirmed, confirm_replay, confirm_checks = await concurrently(
            MerchantMappingRequest(merchant_id=first_merchant.id), confirm_key
        )
        assert confirmed == confirm_replay
        assert confirm_checks >= 2
        assert confirmed.mapping is not None
        assert confirmed.mapping.mapping_version == 1

        correct_key = uuid4()
        corrected, correct_replay, correct_checks = await concurrently(
            MerchantMappingRequest(
                merchant_id=second_merchant.id,
                expected_mapping_version=confirmed.mapping.mapping_version,
            ),
            correct_key,
        )
        assert corrected == correct_replay
        assert correct_checks >= 2
        assert corrected.mapping is not None
        assert corrected.mapping.mapping_version == 2

        release_key = uuid4()
        released, release_replay, release_checks = await concurrently(
            MerchantMappingRequest(
                merchant_id=second_merchant.id,
                expected_mapping_version=corrected.mapping.mapping_version,
            ),
            release_key,
            release=True,
        )
        assert released == release_replay
        assert release_checks >= 2
        assert released.mapping is None

        async with factory() as verify:
            assert await verify.scalar(text("SELECT count(*) FROM merchant_operations")) == 3
            assert (
                await verify.scalar(text("SELECT count(*) FROM transaction_merchant_mappings")) == 0
            )
            with pytest.raises(APIError) as reused:
                await MerchantService(verify).confirm_mapping(
                    transaction_id,
                    MerchantMappingRequest(merchant_id=second_merchant.id),
                    confirm_key,
                )
            assert reused.value.code == "idempotency_key_reused"
    finally:
        await engine.dispose()


async def test_p31_merchant_rejects_invalid_utf8_before_any_database_write() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    try:
        async with factory() as session:
            with pytest.raises(APIError) as rejected:
                await MerchantService(session).create(MerchantDraft(name="\ud800", aliases=[]))
            assert rejected.value.code == "merchant_identifier_invalid"
            assert rejected.value.details == {"field": "name", "reason": "invalid_utf8"}
        async with factory() as verify:
            assert await verify.scalar(text("SELECT count(*) FROM merchants")) == 0
    finally:
        await engine.dispose()


async def test_p31_category_merge_commit_is_concurrently_replayable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    try:
        async with factory() as setup:
            account_id, _category_id, _transaction_id = await _base_ledger(setup)
            categories = CategoryService(setup)
            source = await categories.create(
                CategoryDraft(
                    name=f"P31 merge source {uuid4().hex}",
                    direction=CategoryDirection.EXPENSE,
                    icon="tag",
                    color_hex="#123456",
                )
            )
            target = await categories.create(
                CategoryDraft(
                    name=f"P31 merge target {uuid4().hex}",
                    direction=CategoryDirection.EXPENSE,
                    icon="tag",
                    color_hex="#123456",
                )
            )
            transaction = await TransactionService(setup).create(
                TransactionDraft(
                    kind=TransactionKind.EXPENSE,
                    amount_minor=987,
                    occurred_at="2026-08-14T10:00:00+08:00",  # type: ignore[arg-type]
                    title="P31 merge evidence",
                    account_id=account_id,
                    category_id=source.id,
                ),
                uuid4(),
            )
            preview = await categories.merge_preview(
                source.id,
                CategoryMergePreviewRequest(
                    target_id=target.id,
                    source_expected_version=source.version,
                    target_expected_version=target.version,
                ),
            )

        key = uuid4()
        request = CategoryMergeCommitRequest(preview_token=preview.preview_token)
        post_lock_reads = _synchronize_initial_transform_reads(monkeypatch)

        async def commit() -> object:
            async with factory() as session:
                return await CategoryService(session).merge_commit(source.id, request, key)

        first, second = await asyncio.gather(commit(), commit())
        assert first == second
        assert post_lock_reads() >= 2
        async with factory() as verify:
            assert (
                await verify.scalar(text("SELECT count(*) FROM category_transform_operations")) == 1
            )
            assert (
                await verify.scalar(
                    text("SELECT category_id FROM transactions WHERE id = :id"),
                    {"id": transaction.id},
                )
                == target.id
            )
            with pytest.raises(APIError) as reused:
                await CategoryService(verify).merge_commit(uuid4(), request, key)
            assert reused.value.code == "idempotency_key_reused"
    finally:
        await engine.dispose()


def test_p31_archive_restores_merchant_facts_into_independent_empty_database(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None
    source_name = f"fiscal_p31_archive_source_{uuid4().hex}"
    target_name = f"fiscal_p31_archive_target_{uuid4().hex}"
    source_url = (
        make_url(TEST_DATABASE_URL).set(database=source_name).render_as_string(hide_password=False)
    )
    target_url = (
        make_url(TEST_DATABASE_URL).set(database=target_name).render_as_string(hide_password=False)
    )

    def migrate(database_url: str) -> None:
        monkeypatch.setenv("FISCAL_DATABASE_URL", database_url)
        get_settings.cache_clear()
        command.upgrade(_alembic_config(), "head")

    async def formal(
        factory: async_sessionmaker[AsyncSession], action: Callable[[AsyncSession], Awaitable[T]]
    ) -> T:
        async with factory() as session:
            session.info["data_revision_scopes"] = ("ledger", "reports", "attention")
            return await action(session)

    async def source_fixture() -> tuple[dict[str, tuple[object, ...]], dict[str, object]]:
        source_engine = create_engine(source_url)
        factory = create_session_factory(source_engine)
        try:
            account = await formal(
                factory,
                lambda session: AccountService(session).create(
                    AccountDraft(
                        name="P31 archive debit",
                        kind=AccountKind.DEBIT,
                        opening_balance_minor=20_000,
                    )
                ),
            )
            source_category = await formal(
                factory,
                lambda session: CategoryService(session).create(
                    CategoryDraft(
                        name="P31 archive source",
                        direction=CategoryDirection.EXPENSE,
                        icon="tag",
                        color_hex="#123456",
                    )
                ),
            )
            target_category = await formal(
                factory,
                lambda session: CategoryService(session).create(
                    CategoryDraft(
                        name="P31 archive target",
                        direction=CategoryDirection.EXPENSE,
                        icon="tag",
                        color_hex="#123456",
                    )
                ),
            )
            transaction = await formal(
                factory,
                lambda session: TransactionService(session).create(
                    TransactionDraft(
                        kind=TransactionKind.EXPENSE,
                        amount_minor=1_234,
                        occurred_at="2026-08-14T10:00:00+08:00",  # type: ignore[arg-type]
                        title="P31 archive immutable evidence",
                        account_id=account.id,
                        category_id=source_category.id,
                    ),
                    uuid4(),
                ),
            )
            first_merchant = await formal(
                factory,
                lambda session: MerchantService(session).create(
                    MerchantDraft(name="P31 Archive Merchant", aliases=["P31 Archive Alias"])
                ),
            )
            second_merchant = await formal(
                factory,
                lambda session: MerchantService(session).create(
                    MerchantDraft(name="P31 Archive Corrected", aliases=[])
                ),
            )
            confirmed = await formal(
                factory,
                lambda session: MerchantService(session).confirm_mapping(
                    transaction.id,
                    MerchantMappingRequest(merchant_id=first_merchant.id),
                    uuid4(),
                ),
            )
            assert confirmed.mapping is not None
            corrected = await formal(
                factory,
                lambda session: MerchantService(session).confirm_mapping(
                    transaction.id,
                    MerchantMappingRequest(
                        merchant_id=second_merchant.id,
                        expected_mapping_version=confirmed.mapping.mapping_version,
                    ),
                    uuid4(),
                ),
            )
            assert corrected.mapping is not None and corrected.mapping.mapping_version == 2
            preview = await formal(
                factory,
                lambda session: CategoryService(session).merge_preview(
                    source_category.id,
                    CategoryMergePreviewRequest(
                        target_id=target_category.id,
                        source_expected_version=source_category.version,
                        target_expected_version=target_category.version,
                    ),
                ),
            )
            await formal(
                factory,
                lambda session: CategoryService(session).merge_commit(
                    source_category.id,
                    CategoryMergeCommitRequest(preview_token=preview.preview_token),
                    uuid4(),
                ),
            )
            password = f"p31-archive-{uuid4().hex}"
            async with factory() as session:
                archive, manifest = await ArchiveService(session).export(
                    password=password, include_ai_raw=False
                )
            opened_manifest, payload = ArchiveService.open(archive, password=password)
            assert opened_manifest == manifest
            assert (
                ArchiveService.dry_run_report(opened_manifest, payload)["relationship_errors"] == 0
            )
            assert "category_transform_previews" not in payload["entities"]
            assert "category_transform_operations" not in payload["entities"]
            async with source_engine.connect() as connection:
                expected = {
                    "identifiers": (await connection.execute(_IDENTIFIERS_SQL)).all(),
                    "mapping": (await connection.execute(_MAPPING_SQL)).all(),
                    "receipts": (await connection.execute(_RECEIPTS_SQL)).all(),
                    "data_revision": (await connection.scalar(_DATA_REVISION_SQL),),
                    "financial": (
                        await connection.scalar(_BALANCES_FINGERPRINT_SQL),
                        await connection.scalar(_TRANSACTIONS_FINGERPRINT_SQL),
                    ),
                }
            return expected, {"manifest": opened_manifest, "payload": payload}
        finally:
            await source_engine.dispose()

    async def restore_and_compare(
        expected: dict[str, tuple[object, ...]], archive_data: dict[str, object]
    ) -> None:
        target_engine = create_engine(target_url)
        try:
            async with target_engine.begin() as connection:
                await ArchiveService.restore_empty_target(
                    connection,
                    manifest=archive_data["manifest"],  # type: ignore[arg-type]
                    payload=archive_data["payload"],  # type: ignore[arg-type]
                )
                actual = {
                    "identifiers": (await connection.execute(_IDENTIFIERS_SQL)).all(),
                    "mapping": (await connection.execute(_MAPPING_SQL)).all(),
                    "receipts": (await connection.execute(_RECEIPTS_SQL)).all(),
                    "data_revision": (await connection.scalar(_DATA_REVISION_SQL),),
                    "financial": (
                        await connection.scalar(_BALANCES_FINGERPRINT_SQL),
                        await connection.scalar(_TRANSACTIONS_FINGERPRINT_SQL),
                    ),
                }
                assert actual == expected
                assert await connection.scalar(_PREVIEWS_COUNT_SQL) == 0
                assert await connection.scalar(_OPERATIONS_COUNT_SQL) == 0
        finally:
            await target_engine.dispose()

    asyncio.run(_create_database(source_name))
    asyncio.run(_create_database(target_name))
    try:
        migrate(source_url)
        expected, archive_data = asyncio.run(source_fixture())
        migrate(target_url)
        asyncio.run(restore_and_compare(expected, archive_data))
    finally:
        asyncio.run(_drop_database(target_name))
        asyncio.run(_drop_database(source_name))
        monkeypatch.setenv("FISCAL_DATABASE_URL", TEST_DATABASE_URL)
        get_settings.cache_clear()
