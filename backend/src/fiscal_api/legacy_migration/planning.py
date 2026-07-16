from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import stat
import sys
from collections.abc import AsyncGenerator, Mapping
from contextlib import asynccontextmanager
from dataclasses import asdict, dataclass
from datetime import date
from pathlib import Path
from typing import Any, Final, Protocol, cast

import asyncpg
from pydantic import SecretStr
from sqlalchemy.exc import SQLAlchemyError

SOURCE_DSN_ENV: Final = "FISCAL_LEGACY_DATABASE_URL"
STATEMENT_TIMEOUT_MS: Final = 15_000
ALLOWED_MOVEMENT_TYPES: Final = frozenset(
    {
        "balance_in",
        "balance_out",
        "credit_charge",
        "credit_repayment",
        "transfer_in",
        "transfer_out",
    }
)


class SourceTransaction(Protocol):
    async def start(self) -> None: ...

    async def commit(self) -> None: ...

    async def rollback(self) -> None: ...


class SourceConnection(Protocol):
    def transaction(self, **kwargs: object) -> SourceTransaction: ...

    async def fetchval(self, query: str, *args: object) -> object: ...

    async def fetch(self, query: str, *args: object) -> list[Mapping[str, object]]: ...

    async def close(self) -> None: ...


@dataclass(frozen=True)
class AccountPlan:
    source_name: str
    target_kind: str
    opening_balance_minor: int | None = None


@dataclass(frozen=True)
class MigrationPolicy:
    period_start: date
    period_end: date
    timezone: str
    occurrence_hour: int
    accounts: tuple[AccountPlan, ...]
    expense_categories: Mapping[str, str]
    income_categories: Mapping[str, str]
    reimbursement_party_aliases: Mapping[str, str]
    orphan_repayment_treatment: str
    abandoned_claim_treatment: str
    cash_flow_treatment: str
    excluded_account_names: tuple[str, ...]


P12_POLICY: Final = MigrationPolicy(
    period_start=date(2026, 5, 16),
    period_end=date(2026, 7, 14),
    timezone="Asia/Shanghai",
    occurrence_hour=12,
    accounts=(
        AccountPlan("农业4873", "debit", 0),
        AccountPlan("工商3495", "debit", 2_624_949),
        AccountPlan("杭联0519", "debit", 0),
        AccountPlan("工商3576", "credit", 433_727),
        AccountPlan("白条", "credit", 400_297),
        # Five otherwise-confirmed charges total 49_392 fen but belong to a voided
        # legacy cycle and are excluded from the shadow plan. The opening therefore
        # absorbs only eligible debt and still reconciles to the 109_047-fen close.
        AccountPlan("花呗", "credit", 111_577),
        AccountPlan("车贷", "credit", 1_773_100),
    ),
    expense_categories={
        "吃饭": "餐饮",
        "超市": "日用",
        "生活用品": "日用",
        "买衣服": "服饰",
        "猫猫": "宠物",
        "社交": "社交",
        "游戏": "娱乐",
        "电子产品": "数码",
        "健身专项": "健康",
        "月付": "固定支出",
        "AI专项": "AI工具",
        "公司自费": "工作垫付",
        "报销": "工作垫付",
        "其他支出": "其他支出",
        "意外": "其他支出",
        "平账": "平账",
        "理财": "理财",
    },
    income_categories={
        "工资": "工资",
        "房租": "房租",
        "意外": "其他收入",
    },
    reimbursement_party_aliases={"company": "公司", "公司": "公司", "111": "公司"},
    orphan_repayment_treatment="opening_liability_adjustment_without_cash_flow",
    abandoned_claim_treatment="migrate_expense_without_claim",
    cash_flow_treatment="skip_all_rebuild_from_fiscal_ledger",
    excluded_account_names=("Crypto", "Funds", "Stock", "USDT", "工商5438"),
)


def _source_dsn(environ: Mapping[str, str]) -> SecretStr:
    value = environ.get(SOURCE_DSN_ENV, "").strip()
    if not value:
        raise RuntimeError(f"{SOURCE_DSN_ENV} must be set")
    return SecretStr(value)


@asynccontextmanager
async def legacy_source(dsn: SecretStr) -> AsyncGenerator[SourceConnection]:
    connection = cast(
        SourceConnection,
        await asyncpg.connect(dsn=dsn.get_secret_value()),  # pyright: ignore[reportUnknownMemberType]
    )
    transaction = connection.transaction(isolation="repeatable_read", readonly=True)
    try:
        await transaction.start()
        await connection.fetchval(
            "SELECT set_config('statement_timeout', $1, true)",
            f"{STATEMENT_TIMEOUT_MS}ms",
        )
        yield connection
        await transaction.commit()
    except BaseException:
        await transaction.rollback()
        raise
    finally:
        await connection.close()


async def audit_source(connection: SourceConnection) -> dict[str, Any]:
    inventory_rows = await connection.fetch(
        """
        SELECT 'accounts' AS object_name, count(*) AS row_count FROM accounts
        UNION ALL SELECT 'categories', count(*) FROM categories
        UNION ALL SELECT 'financial_entries', count(*) FROM financial_entries
        UNION ALL SELECT 'entry_category_lines', count(*) FROM entry_category_lines
        UNION ALL SELECT 'account_movements', count(*) FROM account_movements
        UNION ALL SELECT 'account_adjustments', count(*) FROM account_adjustments
        UNION ALL SELECT 'cash_flow_items', count(*) FROM cash_flow_items
        UNION ALL SELECT 'credit_statement_cycles', count(*) FROM credit_statement_cycles
        UNION ALL SELECT 'installment_plans', count(*) FROM installment_plans
        UNION ALL SELECT 'reimbursement_claims', count(*) FROM reimbursement_claims
        UNION ALL SELECT 'attachments', count(*) FROM attachments
        """
    )
    inventory: dict[str, int] = {}
    for row in inventory_rows:
        object_name = row["object_name"]
        row_count = row["row_count"]
        if not isinstance(object_name, str) or not isinstance(row_count, int):
            raise RuntimeError("Legacy source returned an invalid inventory row")
        inventory[object_name] = row_count

    account_rows = await connection.fetch(
        """
        SELECT payload->>'name' AS name,
               payload->>'currency' AS currency,
               COALESCE(payload->>'account_type', payload->>'type', payload->>'kind') AS kind
          FROM (SELECT to_jsonb(a) AS payload FROM accounts a) source_accounts
         WHERE payload->>'name' = ANY($1::text[])
         ORDER BY payload->>'name'
        """,
        [plan.source_name for plan in P12_POLICY.accounts]
        + list(P12_POLICY.excluded_account_names),
    )
    movement_rows = await connection.fetch(
        "SELECT DISTINCT movement_type FROM account_movements ORDER BY movement_type"
    )
    movement_types = sorted(str(row["movement_type"]) for row in movement_rows)
    object_rows = await connection.fetch(
        """
        SELECT object_type, payload->>'id' AS source_id, payload::text AS source_payload,
               payload->>'name' AS name, payload->>'status' AS status,
               payload->>'entry_type' AS entry_type,
               payload->>'movement_type' AS movement_type
          FROM (
            SELECT 'accounts' AS object_type, to_jsonb(t) AS payload FROM accounts t
            UNION ALL SELECT 'categories', to_jsonb(t) FROM categories t
            UNION ALL SELECT 'financial_entries', to_jsonb(t) FROM financial_entries t
            UNION ALL SELECT 'entry_category_lines', to_jsonb(t) FROM entry_category_lines t
            UNION ALL SELECT 'account_movements', to_jsonb(t) FROM account_movements t
            UNION ALL SELECT 'account_adjustments', to_jsonb(t) FROM account_adjustments t
            UNION ALL SELECT 'cash_flow_items', to_jsonb(t) FROM cash_flow_items t
            UNION ALL SELECT 'credit_statement_cycles', to_jsonb(t)
              FROM credit_statement_cycles t
            UNION ALL SELECT 'installment_plans', to_jsonb(t) FROM installment_plans t
            UNION ALL SELECT 'reimbursement_claims', to_jsonb(t) FROM reimbursement_claims t
            UNION ALL SELECT 'attachments', to_jsonb(t) FROM attachments t
          ) source_objects
         ORDER BY object_type, source_id
        """
    )
    source_objects = [_source_object(row) for row in object_rows]
    session: dict[str, object] = {
        "transaction_read_only": await connection.fetchval("SHOW transaction_read_only"),
        "transaction_isolation": await connection.fetchval("SHOW transaction_isolation"),
        "statement_timeout": await connection.fetchval("SHOW statement_timeout"),
        "database": await connection.fetchval("SELECT current_database()"),
        "server_version": await connection.fetchval("SHOW server_version"),
    }
    return {
        "schema_version": 1,
        "mode": "audit",
        "source_session": session,
        "inventory": inventory,
        "accounts": [dict(row) for row in account_rows],
        "movement_types": movement_types,
        "source_objects": source_objects,
    }


def _source_object(row: Mapping[str, object]) -> dict[str, str | None]:
    object_type = row["object_type"]
    source_id = row["source_id"]
    source_payload = row["source_payload"]
    if (
        not isinstance(object_type, str)
        or not isinstance(source_id, str)
        or not isinstance(source_payload, str)
    ):
        raise RuntimeError("Legacy source object has no stable identity")
    identity = f"{object_type}:{source_id}"
    digest = hashlib.sha256(f"{identity}:{source_payload}".encode()).hexdigest()
    return {
        "source_identity": identity,
        "source_row_hash": digest,
        "hash_scope": "row_only_not_apply_provenance",
        "object_type": object_type,
        "name": _optional_string(row.get("name")),
        "status": _optional_string(row.get("status")),
        "entry_type": _optional_string(row.get("entry_type")),
        "movement_type": _optional_string(row.get("movement_type")),
    }


def _optional_string(value: object) -> str | None:
    return value if isinstance(value, str) else None


def build_dry_run_plan(audit: Mapping[str, Any]) -> dict[str, Any]:
    account_names = {str(row["name"]) for row in audit.get("accounts", [])}
    required_names = {account.source_name for account in P12_POLICY.accounts}
    missing_accounts = sorted(required_names - account_names)
    inventory = audit.get("inventory", {})
    expected_inventory = {
        "accounts": 12,
        "categories": 21,
        "financial_entries": 133,
        "entry_category_lines": 120,
        "account_movements": 145,
        "account_adjustments": 33,
        "cash_flow_items": 43,
        "credit_statement_cycles": 25,
        "installment_plans": 0,
        "reimbursement_claims": 7,
        "attachments": 0,
    }
    inventory_conflicts = {
        table: {"expected": expected, "actual": inventory.get(table)}
        for table, expected in expected_inventory.items()
        if inventory.get(table) != expected
    }
    observed_movements = {str(value) for value in audit.get("movement_types", [])}
    unknown_movements = sorted(observed_movements - ALLOWED_MOVEMENT_TYPES)
    object_plan = [_plan_source_object(row) for row in audit.get("source_objects", [])]
    return {
        "schema_version": 1,
        "mode": "dry_run_plan",
        "writes_fiscal_business_tables": False,
        "policy": asdict(P12_POLICY),
        "source_inventory": inventory,
        "baseline_inventory": expected_inventory,
        "candidate_summary": {
            "accounts": 7,
            "confirmed_cny_single_entries": 112,
            "confirmed_cny_transfers_or_repayments": 9,
            "received_reimbursements": 6,
            "abandoned_reimbursements": 1,
        },
        "skip_summary": {
            "excluded_accounts": 5,
            "voided_entries": 5,
            "account_adjustments": 33,
            "cash_flow_items": 43,
            "attachments": 0,
        },
        "conflicts": {
            "missing_selected_accounts": missing_accounts,
            "inventory_changed_since_approved_audit": inventory_conflicts,
            "unknown_movement_types": unknown_movements,
        },
        "object_plan": object_plan,
        "ready_for_transform_planning": (
            not missing_accounts and not inventory_conflicts and not unknown_movements
        ),
        "ready_for_apply": False,
    }


def _plan_source_object(source: Mapping[str, Any]) -> dict[str, Any]:
    object_type = str(source.get("object_type"))
    name = source.get("name")
    status = source.get("status")
    action = "dependency"
    reason = "validated_with_parent_aggregate"
    if object_type == "accounts":
        if name in {account.source_name for account in P12_POLICY.accounts}:
            action, reason = "create", "selected_account"
        else:
            action, reason = "skip", "excluded_account"
    elif object_type == "financial_entries":
        if status == "voided":
            action, reason = "skip", "voided_entry"
        else:
            action, reason = "candidate", "pending_complete_aggregate_transform_validation"
    elif object_type == "reimbursement_claims":
        if status == "abandoned":
            action, reason = "skip", "abandoned_claim_expense_only"
        else:
            action, reason = "create", "received_claim"
    elif object_type in {
        "categories",
        "account_adjustments",
        "cash_flow_items",
        "credit_statement_cycles",
        "attachments",
    }:
        action, reason = "skip", f"excluded_{object_type}"
    elif object_type == "installment_plans":
        action, reason = "create", "selected_installment"
    return {**source, "action": action, "reason": reason}


def _json_default(value: object) -> str:
    if isinstance(value, date):
        return value.isoformat()
    raise TypeError(f"Unsupported report value: {type(value).__name__}")


def _write_report(payload: Mapping[str, Any], output: Path | None) -> None:
    serialized = json.dumps(
        payload,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
        default=_json_default,
    ) + "\n"
    if output is None:
        sys.stdout.write(serialized)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(serialized)
    output.chmod(stat.S_IRUSR | stat.S_IWUSR)


def write_report(payload: Mapping[str, Any], output: Path | None) -> None:
    """Write a credential-free owner-only migration report."""
    _write_report(payload, output)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Audit, plan, apply, and reconcile the LinoFinance to Fiscal migration"
    )
    parser.add_argument("command", choices=("audit", "plan", "apply", "reconcile"))
    parser.add_argument("--output", type=Path, help="write a credential-free JSON report")
    return parser


async def _run(command: str, output: Path | None, environ: Mapping[str, str]) -> None:
    dsn = _source_dsn(environ)
    if command in {"apply", "reconcile"}:
        from fiscal_api.legacy_migration.orchestration import run_target_command, target_dsn

        passed = await run_target_command(command, dsn, target_dsn(environ), output, environ)
        if not passed:
            raise SystemExit(2)
        return
    async with legacy_source(dsn) as connection:
        if command == "audit":
            payload = await audit_source(connection)
        else:
            from fiscal_api.legacy_migration.manifest import load_resolved_manifest
            from fiscal_api.legacy_migration.orchestration import resolved_plan

            preflight = build_dry_run_plan(await audit_source(connection))
            payload = (
                resolved_plan(await load_resolved_manifest(connection))
                if preflight["ready_for_transform_planning"]
                else preflight
            )
    _write_report(payload, output)


def main() -> None:
    args = _parser().parse_args()
    try:
        asyncio.run(_run(args.command, args.output, os.environ))
    except (RuntimeError, asyncpg.PostgresError, SQLAlchemyError, OSError) as error:
        # Never include a DSN in our own diagnostics. asyncpg connection failures are
        # intentionally collapsed because their messages can echo host/user details.
        if isinstance(error, asyncpg.PostgresError):
            raise SystemExit("Legacy source audit failed") from error
        if isinstance(error, SQLAlchemyError):
            raise SystemExit("Fiscal shadow database operation failed") from error
        raise SystemExit(str(error)) from error
