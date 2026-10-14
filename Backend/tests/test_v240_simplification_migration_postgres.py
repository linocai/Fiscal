"""0041 financial rows survive 0042, while unsupported data fails atomically."""

from __future__ import annotations

import asyncio
import hashlib
import io
import json
import subprocess
import sys
import tarfile
import tempfile
from os import environ
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import text

from fiscal_api.cli.v240_preflight import _audit
from fiscal_api.db.session import create_engine
from fiscal_api.services.archive import ArchiveCompatibilityError, ArchiveService

URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(URL is None, reason="requires isolated PostgreSQL")


def _config() -> Config:
    return Config(str(Path(__file__).parents[1] / "alembic.ini"))


async def _seed_0041(*, variant: str = "single") -> dict[str, UUID]:
    assert URL is not None
    ids = {
        key: uuid4()
        for key in (
            "account",
            "expense_a",
            "expense_b",
            "receipt_tx_a",
            "receipt_tx_b",
            "claim",
            "party",
            "party_b",
            "allocation_a",
            "allocation_b",
            "receipt_a",
            "receipt_b",
            "receipt_allocation_a",
            "receipt_allocation_b",
            "claim_revision",
            "receipt_revision",
            "override",
            "override_b",
            "pdf",
        )
    }
    engine = create_engine(URL)
    try:
        async with engine.begin() as db:
            await db.execute(
                text("""
                INSERT INTO accounts(id,name,kind,opening_balance_minor,sort_order,usage_count,
                    version,created_at,updated_at)
                VALUES (:id,'0041 synthetic debit','debit',0,0,0,1,now(),now())
            """),
                {"id": ids["account"]},
            )
            for key, kind, source, amount in (
                ("expense_a", "expense", "manual", -700),
                ("expense_b", "expense", "manual", -500),
                ("receipt_tx_a", "reimbursement_receipt", "system", 400),
                ("receipt_tx_b", "reimbursement_receipt", "system", 300),
            ):
                await db.execute(
                    text("""
                    INSERT INTO transactions(id,kind,occurred_at,title,source,idempotency_key,
                        request_hash,version,created_at,updated_at,merchant_mapping_generation)
                    VALUES (:id,:kind,now(),:title,:source,:key,:hash,1,now(),now(),0)
                """),
                    {
                        "id": ids[key],
                        "kind": kind,
                        "title": key,
                        "source": source,
                        "key": uuid4(),
                        "hash": "0" * 64,
                    },
                )
                await db.execute(
                    text("""
                    INSERT INTO postings(id,transaction_id,account_id,role,amount_minor,position)
                    VALUES (:id,:transaction_id,:account_id,'account',:amount,0)
                """),
                    {
                        "id": uuid4(),
                        "transaction_id": ids[key],
                        "account_id": ids["account"],
                        "amount": amount,
                    },
                )
            await db.execute(
                text("""
                INSERT INTO reimbursement_claims(id,title,note,submitted_at,
                    create_idempotency_key,create_request_hash,version,created_at,updated_at)
                VALUES (:id,'0041 claim','claim note',now(),:key,:hash,3,now(),now())
            """),
                {"id": ids["claim"], "key": uuid4(), "hash": "0" * 64},
            )
            await db.execute(
                text("""
                INSERT INTO reimbursement_parties(id,claim_id,name,expected_date,note,position)
                VALUES (:id,:claim_id,'company','2026-10-01','party note',0)
            """),
                {"id": ids["party"], "claim_id": ids["claim"]},
            )
            if variant == "multi_party":
                await db.execute(
                    text("""
                    INSERT INTO reimbursement_parties(id,claim_id,name,position)
                    VALUES (:id,:claim_id,'second company',1)
                """),
                    {"id": ids["party_b"], "claim_id": ids["claim"]},
                )
            for position, suffix, amount in ((0, "a", 700), (1, "b", 500)):
                await db.execute(
                    text("""
                    INSERT INTO reimbursement_allocations(id,claim_id,party_id,
                        transaction_id,amount_minor,position)
                    VALUES (:id,:claim_id,:party_id,:transaction_id,:amount,:position)
                """),
                    {
                        "id": ids[f"allocation_{suffix}"],
                        "claim_id": ids["claim"],
                        "party_id": ids["party"],
                        "transaction_id": ids[f"expense_{suffix}"],
                        "amount": amount,
                        "position": position,
                    },
                )
            for _position, suffix, amount in ((0, "a", 400), (1, "b", 300)):
                await db.execute(
                    text("""
                    INSERT INTO reimbursement_receipts(id,claim_id,party_id,transaction_id,
                        version,created_at,updated_at)
                    VALUES (:id,:claim_id,:party_id,:transaction_id,1,now(),now())
                """),
                    {
                        "id": ids[f"receipt_{suffix}"],
                        "claim_id": ids["claim"],
                        "party_id": ids["party"],
                        "transaction_id": ids[f"receipt_tx_{suffix}"],
                    },
                )
                await db.execute(
                    text("""
                    INSERT INTO reimbursement_receipt_allocations(id,receipt_id,
                        allocation_id,amount_minor,position)
                    VALUES (:id,:receipt_id,:allocation_id,:amount,0)
                """),
                    {
                        "id": ids[f"receipt_allocation_{suffix}"],
                        "receipt_id": ids[f"receipt_{suffix}"],
                        "allocation_id": ids[f"allocation_{suffix}"],
                        "amount": amount,
                    },
                )
            await db.execute(
                text(
                    """
                INSERT INTO reimbursement_claim_revisions(
                    id,claim_id,version,event,snapshot,created_at)
                VALUES (:id,:claim_id,3,'submitted',CAST(:snapshot AS jsonb),now())
            """
                ),
                {
                    "id": ids["claim_revision"],
                    "claim_id": ids["claim"],
                    "snapshot": '{"legacy_party_count":1,"amount_minor":1200}',
                },
            )
            await db.execute(
                text("""
                INSERT INTO reimbursement_receipt_revisions(
                    id,receipt_id,version,event,snapshot,created_at)
                VALUES (:id,:receipt_id,1,'created',CAST(:snapshot AS jsonb),now())
            """),
                {
                    "id": ids["receipt_revision"],
                    "receipt_id": ids["receipt_a"],
                    "snapshot": '{"legacy_party_amount_minor":400}',
                },
            )
            if variant in {"override", "override_collision", "orphan_override"}:
                reference = ids["party"] if variant != "orphan_override" else uuid4()
                await db.execute(
                    text("""
                    INSERT INTO cash_flow_system_overrides(id,system_kind,system_reference_id,
                        title,direction,expected_date,status,version,created_at,updated_at)
                    VALUES (:id,'reimbursement',:reference,'override','inflow','2026-10-01',
                        'confirmed',1,now(),now())
                """),
                    {"id": ids["override"], "reference": reference},
                )
                if variant == "override_collision":
                    await db.execute(
                        text("""
                        INSERT INTO cash_flow_system_overrides(id,system_kind,system_reference_id,
                            title,direction,expected_date,status,version,created_at,updated_at)
                        VALUES (:id,'reimbursement',:reference,'collision','inflow',
                            '2026-10-01','confirmed',1,now(),now())
                    """),
                        {"id": ids["override_b"], "reference": ids["claim"]},
                    )
            if variant == "pdf":
                await db.execute(
                    text("""
                    INSERT INTO statement_imports(id,document_sha256,byte_size,page_count,
                        mime_type,display_name,created_at,updated_at)
                    VALUES (:id,:hash,1,1,'application/pdf','statement.pdf',now(),now())
                """),
                    {"id": ids["pdf"], "hash": "a" * 64},
                )
        if variant in {"over_capacity", "receipt_mismatch"}:
            table = (
                "reimbursement_allocations"
                if variant == "over_capacity"
                else "reimbursement_receipt_allocations"
            )
            target = (
                ids["allocation_a"] if variant == "over_capacity" else ids["receipt_allocation_a"]
            )
            async with engine.begin() as db:
                await db.execute(text(f"ALTER TABLE {table} DISABLE TRIGGER USER"))
                update_sql = (
                    "UPDATE reimbursement_allocations SET amount_minor=amount_minor+1 WHERE id=:id"
                    if variant == "over_capacity"
                    else "UPDATE reimbursement_receipt_allocations "
                    "SET amount_minor=amount_minor+1 WHERE id=:id"
                )
                await db.execute(text(update_sql), {"id": target})
                await db.execute(text(f"ALTER TABLE {table} ENABLE TRIGGER USER"))
    finally:
        await engine.dispose()
    return ids


async def _fingerprint() -> tuple[object, ...]:
    assert URL is not None
    engine = create_engine(URL)
    try:
        async with engine.connect() as db:
            values = []
            for query in (
                "SELECT version_num FROM alembic_version",
                "SELECT count(*) FROM reimbursement_parties",
                "SELECT count(*) FROM reimbursement_claims",
                "SELECT count(*) FROM statement_imports",
                "SELECT count(*) FROM cash_flow_system_overrides",
                "SELECT sum(amount_minor) FROM postings",
                "SELECT snapshot::text FROM reimbursement_claim_revisions",
                "SELECT sum(amount_minor) FROM reimbursement_allocations",
                "SELECT sum(amount_minor) FROM reimbursement_receipt_allocations",
            ):
                values.append((await db.execute(text(query))).scalar())
            return tuple(values)
    finally:
        await engine.dispose()


async def _preflight() -> dict[str, object]:
    assert URL is not None
    engine = create_engine(URL)
    try:
        async with engine.connect() as db:
            await db.execute(text("SET TRANSACTION READ ONLY"))
            return await db.run_sync(_audit)
    finally:
        await engine.dispose()


def test_0041_single_counterparty_preserves_financial_identity() -> None:
    command.upgrade(_config(), "20260922_0041")
    ids = asyncio.run(_seed_0041(variant="override"))
    before = asyncio.run(_fingerprint())
    assert before[0] == "20260922_0041"
    report = asyncio.run(_preflight())
    assert report["eligible"] is True
    assert report["counts"]["expense_allocated_minor"] == 1_200
    assert report["counts"]["receipt_allocated_minor"] == 700
    assert asyncio.run(_fingerprint()) == before
    assert URL is not None
    with tempfile.TemporaryDirectory(prefix="fiscal_v240_old_archive_") as temporary:
        root = Path(temporary)
        baseline = subprocess.run(
            ["git", "archive", "2d5cc840c4a558ced3fa5753606a9542c0f92618", "Backend"],  # noqa: S607
            cwd=Path(__file__).parents[2],
            check=True,
            capture_output=True,
        )
        with tarfile.open(fileobj=io.BytesIO(baseline.stdout)) as bundle:
            bundle.extractall(root, filter="data")
        archive_path = root / "0041.far"
        password = uuid4().hex + uuid4().hex
        exporter = """
import asyncio, os
from pathlib import Path
from fiscal_api.db.session import create_engine, create_session_factory
from fiscal_api.services.archive import ArchiveService
async def run():
    engine=create_engine(os.environ['FISCAL_DATABASE_URL'])
    try:
        async with create_session_factory(engine)() as session:
            archive,_=await ArchiveService(session).export(password=PASSWORD, include_ai_raw=False)
            Path(OUTPUT).write_bytes(archive)
    finally:
        await engine.dispose()
asyncio.run(run())
"""
        env = {**environ, "FISCAL_DATABASE_URL": URL, "PYTHONPATH": str(root / "Backend" / "src")}
        subprocess.run(  # noqa: S603
            [
                sys.executable,
                "-c",
                f"PASSWORD={password!r}\nOUTPUT={str(archive_path)!r}\n" + exporter,
            ],
            cwd=root / "Backend",
            env=env,
            check=True,
        )
        original = archive_path.read_bytes()
        original_hash = hashlib.sha256(original).hexdigest()
        manifest, payload = ArchiveService.open(original, password=password)
        original_snapshot = json.dumps([manifest, payload], sort_keys=True)
        converted_manifest, converted_payload, conversion = ArchiveService.adapt_to_current(
            manifest, payload
        )
        assert conversion["source_database_revision"] == "20260922_0041"
        assert conversion["original_archive_unchanged"] is True
        assert converted_manifest["database_revision"] == "20261010_0043"
        claim = next(
            row
            for row in converted_payload["entities"]["reimbursement_claims"]
            if row["id"] == str(ids["claim"])
        )
        assert claim["counterparty_name"] == "company"
        assert claim["expected_date"] == "2026-10-01"
        assert json.dumps([manifest, payload], sort_keys=True) == original_snapshot
        rejected = json.loads(json.dumps(payload))
        rejected["entities"]["reimbursement_parties"].append(
            {
                "id": str(uuid4()),
                "claim_id": str(ids["claim"]),
                "name": "second",
                "expected_date": None,
                "note": None,
                "position": 1,
            }
        )
        changed_manifest = dict(manifest)
        changed_manifest["entity_counts"] = dict(manifest["entity_counts"])
        changed_manifest["entity_counts"]["reimbursement_parties"] += 1
        with pytest.raises(ArchiveCompatibilityError, match="multi-counterparty"):
            ArchiveService.adapt_to_current(changed_manifest, rejected)
        assert hashlib.sha256(archive_path.read_bytes()).hexdigest() == original_hash
    command.upgrade(_config(), "head")

    async def verify() -> None:
        assert URL is not None
        engine = create_engine(URL)
        try:
            async with engine.connect() as db:
                claim = (
                    await db.execute(
                        text("""
                    SELECT counterparty_name,expected_date,note FROM reimbursement_claims
                    WHERE id=:id
                """),
                        {"id": ids["claim"]},
                    )
                ).one()
                assert claim.counterparty_name == "company"
                assert str(claim.expected_date) == "2026-10-01"
                assert claim.note == "claim note\nparty note"
                assert (
                    await db.scalar(text("SELECT count(*) FROM reimbursement_allocations"))
                ) == 2
                assert (await db.scalar(text("SELECT count(*) FROM reimbursement_receipts"))) == 2
                assert (
                    await db.scalar(text("SELECT count(*) FROM reimbursement_receipt_allocations"))
                ) == 2
                assert (await db.scalar(text("SELECT sum(amount_minor) FROM postings"))) == before[
                    5
                ]
                assert (
                    await db.scalar(
                        text("SELECT snapshot::text FROM reimbursement_claim_revisions")
                    )
                ) == before[6]
                assert (
                    await db.scalar(
                        text("SELECT system_reference_id FROM cash_flow_system_overrides")
                    )
                ) == ids["claim"]
                assert (
                    await db.scalar(text("SELECT to_regclass('reimbursement_parties')"))
                ) is None
        finally:
            await engine.dispose()

    asyncio.run(verify())

    async def reset_and_restore() -> None:
        assert URL is not None
        engine = create_engine(URL)
        try:
            async with engine.begin() as db:
                await db.execute(text("DROP SCHEMA public CASCADE"))
                await db.execute(text("CREATE SCHEMA public"))
        finally:
            await engine.dispose()

    asyncio.run(reset_and_restore())
    command.upgrade(_config(), "head")

    async def restore() -> None:
        assert URL is not None
        engine = create_engine(URL)
        try:
            async with engine.begin() as db:
                await ArchiveService.restore_empty_target(db, manifest=manifest, payload=payload)
        finally:
            await engine.dispose()

    asyncio.run(restore())
    asyncio.run(verify())


@pytest.mark.parametrize(
    "variant,reason",
    (
        ("multi_party", "multi-party"),
        ("pdf", "nonempty statement_imports"),
        ("override_collision", "collision"),
        ("orphan_override", "orphan"),
        ("over_capacity", "capacity mismatch"),
        ("receipt_mismatch", "allocation mismatch"),
    ),
)
def test_0041_rejection_keeps_original_rows_and_revision(variant: str, reason: str) -> None:
    command.upgrade(_config(), "20260922_0041")
    asyncio.run(_seed_0041(variant=variant))
    before = asyncio.run(_fingerprint())
    report = asyncio.run(_preflight())
    assert report["eligible"] is False
    assert reason in report["blocker"]
    assert asyncio.run(_fingerprint()) == before
    with pytest.raises(RuntimeError, match=reason):
        command.upgrade(_config(), "head")
    assert asyncio.run(_fingerprint()) == before
