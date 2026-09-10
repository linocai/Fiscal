"""Exercise original 0038 tools and both recovery paths in the one disposable DB."""

from __future__ import annotations

import asyncio
import hashlib
import io
import json
import subprocess
import sys
import tarfile
from os import environ
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text

from fiscal_api.db.session import create_engine
from fiscal_api.services.archive import ArchiveCompatibilityError, ArchiveService

URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(URL is None, reason="requires isolated PostgreSQL")
BASELINE = "5a4991fc65e3326e411fcc96c9abfd7ec4b9bde4"
BACKEND = Path(__file__).parents[1]


async def _reset():
    engine = create_engine(URL)
    try:
        async with engine.begin() as connection:
            await connection.execute(text("DROP SCHEMA public CASCADE"))
            await connection.execute(text("CREATE SCHEMA public"))
    finally:
        await engine.dispose()


async def _fingerprint():
    engine = create_engine(URL)
    try:
        async with engine.connect() as connection:
            return {
                "revision": await connection.scalar(
                    text("SELECT version_num FROM alembic_version")
                ),
                "balance": await connection.scalar(text("SELECT sum(amount_minor) FROM postings")),
                "generation": await connection.scalar(
                    text("SELECT merchant_mapping_generation FROM transactions")
                ),
                "mapping": await connection.scalar(
                    text("SELECT version FROM transaction_merchant_mappings")
                ),
                "receipt": await connection.scalar(text("SELECT receipt FROM merchant_operations")),
            }
    finally:
        await engine.dispose()


def test_original_0038_archive_native_restore_upgrade_and_allowlisted_adapter(
    tmp_path, monkeypatch
):
    assert URL
    monkeypatch.setenv("FISCAL_DATABASE_URL", URL)
    config = Config(str(BACKEND / "alembic.ini"))
    source = subprocess.run(  # noqa: S603
        ["git", "archive", BASELINE, "Backend"],  # noqa: S607
        cwd=BACKEND.parent,
        check=True,
        capture_output=True,
    )
    with tarfile.open(fileobj=io.BytesIO(source.stdout)) as bundle:
        bundle.extractall(tmp_path / "baseline", filter="data")
    old_backend = tmp_path / "baseline" / "Backend"
    archive_path = tmp_path / "original-0038.far"
    password = uuid4().hex
    environment = {**environ, "PYTHONPATH": str(old_backend / "src")}
    asyncio.run(_reset())
    command.upgrade(config, "20260831_0038")
    seed = """
import asyncio, os
from datetime import datetime, UTC
from pathlib import Path
from uuid import uuid4
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.db.models import (
    Account, LedgerTransaction, Posting, Merchant, TransactionMerchantMapping, MerchantOperation
)
from fiscal_api.services.archive import ArchiveService
async def main():
    engine = create_engine(os.environ['FISCAL_DATABASE_URL'])
    try:
        async with create_session_factory(engine)() as session:
            account = Account(name='legacy fixture', kind='debit', opening_balance_minor=1000)
            merchant = Merchant(name='legacy merchant')
            session.add_all([account, merchant]); await session.flush()
            tx = LedgerTransaction(kind='income', title='legacy fixture',
                occurred_at=datetime(2026,9,1,tzinfo=UTC),
                idempotency_key=uuid4(), request_hash='0'*64)
            session.add(tx); await session.flush()
            session.add(Posting(transaction_id=tx.id, account_id=account.id,
                role='account', amount_minor=123, position=0))
            session.add(TransactionMerchantMapping(
                transaction_id=tx.id, merchant_id=merchant.id, version=1))
            session.add(MerchantOperation(idempotency_key=uuid4(), request_hash='0'*64,
                action='confirm', receipt={'mapping': {
                    'transaction_id': str(tx.id), 'mapping_version': 7}}))
            await session.commit()
            archive, _ = await ArchiveService(session).export(
                password=PASSWORD, include_ai_raw=False)
            Path(ARCHIVE).write_bytes(archive)
    finally:
        await engine.dispose()
asyncio.run(main())
"""
    seed = f"PASSWORD={password!r}\nARCHIVE={str(archive_path)!r}\n" + seed
    subprocess.run([sys.executable, "-c", seed], cwd=old_backend, env=environment, check=True)  # noqa: S603
    original = archive_path.read_bytes()
    original_hash = hashlib.sha256(original).hexdigest()
    manifest, payload = ArchiveService.open(original, password=password)
    source_snapshot = json.dumps([manifest, payload], sort_keys=True)
    report = ArchiveService.dry_run_report(manifest, payload)
    assert report["conversion"]["source_database_revision"] == "20260831_0038"
    assert report["conversion"]["added_fields"] == ["transactions.merchant_mapping_generation"]
    assert json.dumps([manifest, payload], sort_keys=True) == source_snapshot

    # Emergency path: unmodified baseline CLI restores its own original archive,
    # then current Alembic upgrades the restored data without a downgrade.
    asyncio.run(_reset())
    command.upgrade(config, "20260831_0038")
    for flags in (["--dry-run"], ["--apply", "--confirm-empty-target"]):
        subprocess.run(  # noqa: S603
            [sys.executable, "-m", "fiscal_api.cli.archive", str(archive_path), *flags],
            cwd=old_backend,
            env=environment,
            input=password + "\n",
            text=True,
            check=True,
        )
    command.upgrade(config, "head")
    native = asyncio.run(_fingerprint())
    assert native["revision"] == "20260910_0039"
    assert native["generation"] == native["mapping"] == 8
    assert native["balance"] == 123

    # Supported current path: exact source schema validation, deterministic
    # adaptation, and restore only into a freshly migrated current head.
    asyncio.run(_reset())
    command.upgrade(config, "head")
    current_environment = {**environ, "PYTHONPATH": str(BACKEND / "src")}
    for flags in (["--dry-run"], ["--apply", "--confirm-empty-target"]):
        subprocess.run(  # noqa: S603
            [sys.executable, "-m", "fiscal_api.cli.archive", str(archive_path), *flags],
            cwd=BACKEND,
            env=current_environment,
            input=password + "\n",
            text=True,
            check=True,
        )
    assert asyncio.run(_fingerprint()) == native
    assert hashlib.sha256(archive_path.read_bytes()).hexdigest() == original_hash
    unsupported = {**manifest, "database_revision": "20260811_0022"}
    with pytest.raises(ArchiveCompatibilityError, match="20260811_0022"):
        ArchiveService.dry_run_report(unsupported, payload)
    invalid = json.loads(json.dumps(payload))
    invalid["entities"]["transactions"][0]["unexpected_field"] = 1
    with pytest.raises(ValueError, match="row fields"):
        ArchiveService.dry_run_report(manifest, invalid)
