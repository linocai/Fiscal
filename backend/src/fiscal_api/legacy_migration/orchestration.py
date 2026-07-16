from __future__ import annotations

import os
from collections import Counter, defaultdict
from collections.abc import Mapping
from dataclasses import asdict
from pathlib import Path
from typing import Any, Final
from uuid import UUID

from pydantic import SecretStr
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import selectinload

from fiscal_api.core.time import BUSINESS_TIMEZONE
from fiscal_api.db.models import (
    Account,
    LedgerTransaction,
    MigrationObjectLink,
    Posting,
    ReimbursementAllocation,
    ReimbursementReceipt,
    ReimbursementReceiptAllocation,
)
from fiscal_api.legacy_migration.apply import LegacyManifest, LegacyShadowApplier
from fiscal_api.legacy_migration.manifest import load_resolved_manifest
from fiscal_api.legacy_migration.planning import (
    SourceConnection,
    audit_source,
    build_dry_run_plan,
    legacy_source,
    write_report,
)
from fiscal_api.legacy_migration.reconciliation import (
    Aggregate,
    MonthlySummary,
    ReimbursementSummary,
    combine_reports,
    reconcile_account_balances,
    reconcile_credit_liabilities,
    reconcile_monthly_reports,
    reconcile_reimbursements,
    reconcile_transaction_aggregates,
)
from fiscal_api.legacy_migration.transform import yuan_to_minor

TARGET_DSN_ENV: Final = "FISCAL_DATABASE_URL"
CODE_REVISION_ENV: Final = "FISCAL_MIGRATION_CODE_REVISION"


def target_dsn(environ: Mapping[str, str]) -> SecretStr:
    value = environ.get(TARGET_DSN_ENV, "").strip()
    if not value:
        raise RuntimeError(f"{TARGET_DSN_ENV} must be set")
    return SecretStr(value)


def resolved_plan(manifest: LegacyManifest) -> dict[str, Any]:
    create = {
        "accounts": len(manifest.accounts),
        "categories": len(manifest.categories),
        "transactions": len(manifest.transactions),
        "reimbursement_claims": len(manifest.claims),
        "reimbursement_receipts": len(manifest.receipts),
    }
    skipped = Counter(item.reason for item in manifest.skipped)
    return {
        "schema_version": 1,
        "mode": "resolved_plan",
        "writes_fiscal_business_tables": False,
        "source_database_fingerprint": manifest.source_database_fingerprint,
        "selection_scope": manifest.selection_scope,
        "create_summary": create,
        "skip_summary": dict(sorted(skipped.items())),
        "conflicts": [],
        "ready_for_apply": True,
    }


async def apply_shadow(
    connection: SourceConnection,
    session: AsyncSession,
    *,
    code_revision: str,
) -> dict[str, Any]:
    database = await _require_shadow_database(session)
    await _require_approved_source(connection)
    manifest = await load_resolved_manifest(connection)
    result = await LegacyShadowApplier(session).apply(manifest, code_revision=code_revision)
    return {
        "schema_version": 1,
        "mode": "shadow_apply",
        "target_database": database,
        "source_database_fingerprint": manifest.source_database_fingerprint,
        "run_id": str(result.run_id),
        "created": result.created,
        "unchanged": result.unchanged,
        "skipped": result.skipped,
        "status": "succeeded",
    }


async def reconcile_shadow(
    connection: SourceConnection,
    session: AsyncSession,
) -> dict[str, Any]:
    database = await _require_shadow_database(session)
    await _require_approved_source(connection)
    manifest = await load_resolved_manifest(connection)
    expected_assets, expected_credit = await _source_closing_balances(connection)
    actual_assets, actual_credit = await _target_closing_balances(session, manifest)
    expected_transactions = _expected_transaction_aggregates(manifest)
    transaction_ids, receipt_transaction_ids = await _linked_transaction_ids(session, manifest)
    actual_transactions, actual_monthly = await _target_transaction_summaries(
        session, transaction_ids | receipt_transaction_ids
    )
    expected_reimbursements = ReimbursementSummary(
        claim_count=len(manifest.claims),
        expected_minor=sum(item.amount_minor for item in manifest.claims),
        received_minor=sum(item.amount_minor for item in manifest.receipts),
        outstanding_minor=sum(item.amount_minor for item in manifest.claims)
        - sum(item.amount_minor for item in manifest.receipts),
    )
    actual_reimbursements = await _target_reimbursement_summary(session, manifest)
    expected_monthly = _expected_monthly(manifest)
    report = combine_reports(
        reconcile_account_balances(expected_assets, actual_assets),
        reconcile_credit_liabilities(expected_credit, actual_credit),
        reconcile_transaction_aggregates(expected_transactions, actual_transactions),
        reconcile_reimbursements(expected_reimbursements, actual_reimbursements),
        reconcile_monthly_reports(expected_monthly, actual_monthly),
    )
    return {
        "schema_version": 1,
        "mode": "shadow_reconciliation",
        "target_database": database,
        "source_database_fingerprint": manifest.source_database_fingerprint,
        "passed": report.passed,
        "mismatch_count": report.mismatch_count,
        "checks": [asdict(item) for item in report.checks],
    }


async def run_target_command(
    command: str,
    source_dsn: SecretStr,
    target: SecretStr,
    output: Path | None,
    environ: Mapping[str, str],
) -> bool:
    engine = create_async_engine(target.get_secret_value(), pool_pre_ping=True)
    try:
        async with legacy_source(source_dsn) as connection, AsyncSession(
            engine, expire_on_commit=False
        ) as session:
            if command == "apply":
                payload = await apply_shadow(
                    connection,
                    session,
                    code_revision=environ.get(CODE_REVISION_ENV, "workspace").strip()
                    or "workspace",
                )
            else:
                payload = await reconcile_shadow(connection, session)
        write_report(payload, output)
        return command != "reconcile" or bool(payload["passed"])
    finally:
        await engine.dispose()


async def _require_shadow_database(session: AsyncSession) -> str:
    database = str(await session.scalar(text("SELECT current_database()")))
    normalized = database.casefold()
    if "shadow" not in normalized and "drill" not in normalized:
        raise RuntimeError(
            "P12 apply/reconcile is restricted to a target database whose name contains "
            "'shadow' or 'drill'; production apply is not enabled"
        )
    return database


async def _require_approved_source(connection: SourceConnection) -> None:
    preflight = build_dry_run_plan(await audit_source(connection))
    if not preflight["ready_for_transform_planning"]:
        conflicts = preflight["conflicts"]
        raise RuntimeError(f"Legacy source differs from the approved P12 audit: {conflicts}")


async def _source_closing_balances(
    connection: SourceConnection,
) -> tuple[dict[str, int], dict[str, int]]:
    rows = await connection.fetch(
        """SELECT name,type,current_balance,current_liability
             FROM accounts
            WHERE name = ANY($1::text[]) ORDER BY name""",
        ["农业4873", "工商3495", "杭联0519", "工商3576", "白条", "花呗", "车贷"],
    )
    assets: dict[str, int] = {}
    credit: dict[str, int] = {}
    for row in rows:
        name = str(row["name"])
        if str(row["type"]) == "credit":
            credit[name] = yuan_to_minor(row["current_liability"], field=f"{name} liability")  # type: ignore[arg-type]
        else:
            assets[name] = yuan_to_minor(row["current_balance"], field=f"{name} balance")  # type: ignore[arg-type]
    return assets, credit


async def _target_closing_balances(
    session: AsyncSession, manifest: LegacyManifest
) -> tuple[dict[str, int], dict[str, int]]:
    fingerprint = manifest.source_database_fingerprint
    rows = await session.execute(
        select(Account, func.coalesce(func.sum(Posting.amount_minor), 0))
        .join(
            MigrationObjectLink,
            (MigrationObjectLink.target_object_id == Account.id)
            & (MigrationObjectLink.target_object_type == "account"),
        )
        .outerjoin(Posting, Posting.account_id == Account.id)
        .outerjoin(LedgerTransaction, LedgerTransaction.id == Posting.transaction_id)
        .where(MigrationObjectLink.source_database_fingerprint == fingerprint)
        .where((LedgerTransaction.id.is_(None)) | (LedgerTransaction.voided_at.is_(None)))
        .group_by(Account.id)
    )
    assets: dict[str, int] = {}
    credit: dict[str, int] = {}
    for account, impact in rows.all():
        if account.kind == "credit":
            credit[account.name] = account.opening_balance_minor - int(impact)
        else:
            assets[account.name] = account.opening_balance_minor + int(impact)
    return assets, credit


def _expected_transaction_aggregates(manifest: LegacyManifest) -> dict[str, Aggregate]:
    values: dict[str, list[int]] = defaultdict(list)
    for item in manifest.transactions:
        values[item.kind].append(item.amount_minor)
    for item in manifest.receipts:
        values["reimbursement_receipt"].append(item.amount_minor)
    return {
        kind: Aggregate(count=len(amounts), amount_minor=sum(amounts))
        for kind, amounts in values.items()
    }


async def _linked_transaction_ids(
    session: AsyncSession, manifest: LegacyManifest
) -> tuple[set[UUID], set[UUID]]:
    fingerprint = manifest.source_database_fingerprint
    transaction_ids = set(
        (
            await session.scalars(
                select(MigrationObjectLink.target_object_id).where(
                    MigrationObjectLink.source_database_fingerprint == fingerprint,
                    MigrationObjectLink.target_object_type == "transaction",
                )
            )
        ).all()
    )
    receipt_ids = list(
        (
            await session.scalars(
                select(MigrationObjectLink.target_object_id).where(
                    MigrationObjectLink.source_database_fingerprint == fingerprint,
                    MigrationObjectLink.target_object_type == "reimbursement_receipt",
                )
            )
        ).all()
    )
    receipt_transaction_ids = set(
        (
            await session.scalars(
                select(ReimbursementReceipt.transaction_id).where(
                    ReimbursementReceipt.id.in_(receipt_ids)
                )
            )
        ).all()
        if receipt_ids
        else []
    )
    return transaction_ids, receipt_transaction_ids


async def _target_transaction_summaries(
    session: AsyncSession, transaction_ids: set[UUID]
) -> tuple[dict[str, Aggregate], dict[str, MonthlySummary]]:
    if not transaction_ids:
        return {}, {}
    transactions = list(
        (
            await session.scalars(
                select(LedgerTransaction)
                .where(
                    LedgerTransaction.id.in_(transaction_ids),
                    LedgerTransaction.voided_at.is_(None),
                )
                .options(selectinload(LedgerTransaction.postings))
            )
        ).unique()
    )
    account_ids = {posting.account_id for item in transactions for posting in item.postings}
    account_kinds: dict[UUID, str] = {}
    rows = await session.execute(
        select(Account.id, Account.kind).where(Account.id.in_(account_ids))
    )
    for account_id, kind in rows.all():
        account_kinds[account_id] = kind
    aggregates: dict[str, list[int]] = defaultdict(list)
    monthly: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for transaction in transactions:
        amount = max(abs(posting.amount_minor) for posting in transaction.postings)
        aggregates[transaction.kind].append(amount)
        month = transaction.occurred_at.astimezone(BUSINESS_TIMEZONE).strftime("%Y-%m")
        bucket = monthly[month]
        if transaction.kind == "income":
            bucket["income_minor"] += amount
        if transaction.kind in {"expense", "credit_purchase"}:
            bucket["spending_minor"] += amount
        if transaction.kind == "reimbursement_receipt":
            bucket["reimbursement_received_minor"] += amount
        for posting in transaction.postings:
            if account_kinds.get(posting.account_id) not in {"cash", "debit"}:
                continue
            if posting.amount_minor > 0:
                bucket["cash_inflow_minor"] += posting.amount_minor
            else:
                bucket["cash_outflow_minor"] += -posting.amount_minor
    return (
        {
            kind: Aggregate(count=len(amounts), amount_minor=sum(amounts))
            for kind, amounts in aggregates.items()
        },
        {month: _monthly_summary(values) for month, values in monthly.items()},
    )


async def _target_reimbursement_summary(
    session: AsyncSession, manifest: LegacyManifest
) -> ReimbursementSummary:
    fingerprint = manifest.source_database_fingerprint
    claim_ids = list(
        (
            await session.scalars(
                select(MigrationObjectLink.target_object_id).where(
                    MigrationObjectLink.source_database_fingerprint == fingerprint,
                    MigrationObjectLink.target_object_type == "reimbursement_claim",
                )
            )
        ).all()
    )
    if not claim_ids:
        return ReimbursementSummary(0, 0, 0, 0)
    expected = int(
        await session.scalar(
            select(func.coalesce(func.sum(ReimbursementAllocation.amount_minor), 0)).where(
                ReimbursementAllocation.claim_id.in_(claim_ids)
            )
        )
        or 0
    )
    received = int(
        await session.scalar(
            select(func.coalesce(func.sum(ReimbursementReceiptAllocation.amount_minor), 0))
            .join(
                ReimbursementReceipt,
                ReimbursementReceipt.id == ReimbursementReceiptAllocation.receipt_id,
            )
            .where(ReimbursementReceipt.claim_id.in_(claim_ids))
        )
        or 0
    )
    return ReimbursementSummary(len(claim_ids), expected, received, expected - received)


def _expected_monthly(manifest: LegacyManifest) -> dict[str, MonthlySummary]:
    account_kinds = {item.source.object_id: item.kind for item in manifest.accounts}
    monthly: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for item in manifest.transactions:
        month = item.occurred_at.astimezone(BUSINESS_TIMEZONE).strftime("%Y-%m")
        bucket = monthly[month]
        if item.kind == "income":
            bucket["income_minor"] += item.amount_minor
        if item.kind in {"expense", "credit_purchase"}:
            bucket["spending_minor"] += item.amount_minor
        if item.kind == "income" and account_kinds[item.account_source_id] in {"cash", "debit"}:
            bucket["cash_inflow_minor"] += item.amount_minor
        elif item.kind == "expense" and account_kinds[item.account_source_id] in {
            "cash",
            "debit",
        }:
            bucket["cash_outflow_minor"] += item.amount_minor
        elif item.kind in {"transfer", "repayment"}:
            bucket["cash_outflow_minor"] += item.amount_minor
            if (
                item.kind == "transfer"
                and item.destination_account_source_id is not None
                and account_kinds[item.destination_account_source_id] in {"cash", "debit"}
            ):
                bucket["cash_inflow_minor"] += item.amount_minor
    for item in manifest.receipts:
        month = item.received_at.astimezone(BUSINESS_TIMEZONE).strftime("%Y-%m")
        bucket = monthly[month]
        bucket["cash_inflow_minor"] += item.amount_minor
        bucket["reimbursement_received_minor"] += item.amount_minor
    return {month: _monthly_summary(values) for month, values in monthly.items()}


def _monthly_summary(values: Mapping[str, int]) -> MonthlySummary:
    return MonthlySummary(
        income_minor=values.get("income_minor", 0),
        spending_minor=values.get("spending_minor", 0),
        cash_inflow_minor=values.get("cash_inflow_minor", 0),
        cash_outflow_minor=values.get("cash_outflow_minor", 0),
        reimbursement_received_minor=values.get("reimbursement_received_minor", 0),
    )


async def plan_from_source(source_dsn: SecretStr, output: Path | None) -> None:
    async with legacy_source(source_dsn) as connection:
        manifest = await load_resolved_manifest(connection)
    write_report(resolved_plan(manifest), output)


def current_environ() -> Mapping[str, str]:
    return os.environ
