"""Read-only 0041 audit before the irreversible 0042 migration."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import sqlalchemy as sa
from alembic.config import Config
from alembic.operations import Operations
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import text
from sqlalchemy.engine import Connection

from fiscal_api.core.config import Settings
from fiscal_api.db.session import create_engine

BACKEND_ROOT = Path(__file__).resolve().parents[3]


def _audit(connection: Connection) -> dict[str, Any]:
    revision = connection.scalar(text("SELECT version_num FROM alembic_version"))
    if revision != "20260922_0041":
        return {"revision": revision, "eligible": False, "blocker": "requires 0041"}
    script = ScriptDirectory.from_config(Config(str(BACKEND_ROOT / "alembic.ini")))
    migration = script.get_revision("20260926_0042").module
    statement_counts = {
        table: int(connection.scalar(sa.select(sa.func.count()).select_from(sa.table(table))) or 0)
        for table in migration.STATEMENT_TABLES
    }
    counts = {
        "claims": int(connection.scalar(text("SELECT count(*) FROM reimbursement_claims")) or 0),
        "single_party_claims": int(
            connection.scalar(
                text("""
            SELECT count(*) FROM (
              SELECT claim_id FROM reimbursement_parties GROUP BY claim_id HAVING count(*)=1
            ) c
        """)
            )
            or 0
        ),
        "multi_party_claims": int(
            connection.scalar(
                text("""
            SELECT count(*) FROM (
              SELECT claim_id FROM reimbursement_parties GROUP BY claim_id HAVING count(*)>1
            ) c
        """)
            )
            or 0
        ),
        "expense_allocated_minor": int(
            connection.scalar(
                text("SELECT COALESCE(sum(amount_minor),0) FROM reimbursement_allocations")
            )
            or 0
        ),
        "receipt_allocated_minor": int(
            connection.scalar(
                text("SELECT COALESCE(sum(amount_minor),0) FROM reimbursement_receipt_allocations")
            )
            or 0
        ),
        "reimbursement_overrides": int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM cash_flow_system_overrides "
                    "WHERE system_kind='reimbursement'"
                )
            )
            or 0
        ),
    }
    try:
        with Operations.context(MigrationContext.configure(connection)):
            migration._guard()
    except RuntimeError as error:
        return {
            "revision": revision,
            "eligible": False,
            "blocker": str(error),
            "statement_counts": statement_counts,
            "counts": counts,
        }
    return {
        "revision": revision,
        "eligible": True,
        "statement_counts": statement_counts,
        "counts": counts,
    }


async def _run() -> dict[str, Any]:
    engine = create_engine(Settings().database_url)
    try:
        async with engine.connect() as connection:
            await connection.execute(text("SET TRANSACTION READ ONLY"))
            return await connection.run_sync(_audit)
    finally:
        await engine.dispose()


def main() -> None:
    report = asyncio.run(_run())
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    if not report["eligible"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
