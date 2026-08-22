from __future__ import annotations

import argparse
import asyncio
import json
import os
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from typing import Any, Final, cast
from uuid import NAMESPACE_URL, uuid5

from pydantic import SecretStr
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine

from fiscal_api.api.p13_schemas import CashFlowDraft
from fiscal_api.db.models import (
    Account,
    CashFlowDirection,
    CashFlowItem,
    CashFlowRecurrence,
    CashFlowSource,
    Category,
)
from fiscal_api.legacy_migration.planning import SourceConnection, legacy_source
from fiscal_api.services.cash_flow import CashFlowService

SOURCE_DSN_ENV: Final = "FISCAL_LEGACY_DATABASE_URL"
TARGET_DSN_ENV: Final = "FISCAL_DATABASE_URL"
PRODUCTION_CONFIRM_ENV: Final = "FISCAL_CASH_FLOW_RECOVERY_CONFIRM"
PRODUCTION_CONFIRM_VALUE: Final = "RECOVER_7_MANUAL_PLANS"
SALARY_KEY: Final = uuid5(NAMESPACE_URL, "fiscal:p13-recovery:salary-series:v1")
RENT_KEY: Final = uuid5(NAMESPACE_URL, "fiscal:p13-recovery:september-rent:v1")
EXPECTED_SALARY_DATES: Final = tuple(date(2026, month, 21) for month in range(7, 13))


@dataclass(frozen=True)
class LegacyCashFlow:
    source_id: str
    title: str
    direction: str
    cash_flow_type: str
    amount_minor: int
    expected_date: date
    status: str
    account_name: str | None
    category_name: str | None
    recurrence_rule: str | None
    note: str | None


def _minor(value: object) -> int:
    amount = value if isinstance(value, Decimal) else Decimal(str(value))
    minor = amount * 100
    if minor != minor.to_integral_value():
        raise RuntimeError("Legacy cash flow amount has more than two decimal places")
    return int(minor)


def parse_rows(rows: Sequence[Mapping[str, object]]) -> list[LegacyCashFlow]:
    values: list[LegacyCashFlow] = []
    for row in rows:
        expected_date = row["expected_date"]
        if not isinstance(expected_date, date):
            raise RuntimeError("Legacy cash flow date is invalid")
        values.append(
            LegacyCashFlow(
                source_id=str(row["id"]),
                title=str(row["title"]),
                direction=str(row["direction"]),
                cash_flow_type=str(row["cash_flow_type"]),
                amount_minor=_minor(row["amount"]),
                expected_date=expected_date,
                status=str(row["status"]),
                account_name=str(row["account_name"]) if row["account_name"] else None,
                category_name=str(row["category_name"]) if row["category_name"] else None,
                recurrence_rule=(str(row["recurrence_rule"]) if row["recurrence_rule"] else None),
                note=str(row["note"]) if row["note"] else None,
            )
        )
    return values


async def load_active_source(connection: SourceConnection) -> list[LegacyCashFlow]:
    rows = await connection.fetch(
        """
        SELECT c.id, c.title, c.direction, c.cash_flow_type, c.amount,
               c.expected_date, c.status, a.name AS account_name,
               k.name AS category_name, c.recurrence_rule, c.note
        FROM cash_flow_items c
        LEFT JOIN accounts a ON a.id = c.account_id
        LEFT JOIN categories k ON k.id = c.category_id
        WHERE c.status IN ('expected', 'confirmed')
        ORDER BY c.expected_date, c.id
        """
    )
    return parse_rows(rows)


def select_recoverable(
    rows: Sequence[LegacyCashFlow],
) -> tuple[list[LegacyCashFlow], LegacyCashFlow, list[LegacyCashFlow]]:
    salaries = sorted(
        (item for item in rows if item.cash_flow_type == "salary"),
        key=lambda item: item.expected_date,
    )
    rents = [item for item in rows if item.cash_flow_type == "rent_income"]
    repayments = [item for item in rows if item.cash_flow_type == "credit_repayment"]
    if len(rows) != 24 or len(salaries) != 6 or len(rents) != 1 or len(repayments) != 17:
        raise RuntimeError(
            "Legacy active cash flow inventory no longer matches the audited 7+17 set"
        )
    if tuple(item.expected_date for item in salaries) != EXPECTED_SALARY_DATES:
        raise RuntimeError("Legacy salary occurrence dates differ from the audited series")
    if any(
        item.title != "工资"
        or item.direction != "inflow"
        or item.amount_minor != 500_000
        or item.status != "expected"
        or item.account_name != "农业4873"
        or item.category_name != "工资"
        or item.recurrence_rule != "FREQ=MONTHLY;UNTIL=2026-12-21"
        for item in salaries
    ):
        raise RuntimeError("Legacy salary series differs from the audited values")
    rent = rents[0]
    if (
        rent.title != "9月房租"
        or rent.direction != "inflow"
        or rent.amount_minor != 630_000
        or rent.expected_date != date(2026, 9, 30)
        or rent.status != "expected"
        or rent.account_name != "工商3495"
        or rent.category_name is not None
        or rent.recurrence_rule is not None
    ):
        raise RuntimeError("Legacy September rent differs from the audited values")
    if any(item.status != "confirmed" for item in repayments):
        raise RuntimeError("Legacy credit repayment inventory differs from the audited values")
    return salaries, rent, repayments


async def _target_reference(
    session: AsyncSession, model: type[Account] | type[Category], name: str
) -> Account | Category:
    values = list(
        await session.scalars(select(model).where(model.name == name, model.archived_at.is_(None)))
    )
    if len(values) != 1:
        raise RuntimeError(
            f"Target requires exactly one active {model.__name__.lower()} named {name}"
        )
    return values[0]


async def _audit_target(session: AsyncSession, source_ids: set[str]) -> dict[str, object]:
    database = str(await session.scalar(text("SELECT current_database()")))
    existing = list(
        await session.scalars(
            select(CashFlowItem)
            .where(CashFlowItem.legacy_source_id.in_(source_ids))
            .order_by(CashFlowItem.expected_date)
        )
    )
    return {
        "database": database,
        "recovered_count": len(existing),
        "recovered_minor": sum(item.planned_amount_minor for item in existing),
        "legacy_source_ids": sorted(
            item.legacy_source_id for item in existing if item.legacy_source_id
        ),
    }


async def run(command: str, source_dsn: SecretStr, target_dsn: SecretStr) -> dict[str, Any]:
    engine = create_async_engine(target_dsn.get_secret_value(), pool_pre_ping=True)
    try:
        async with (
            legacy_source(source_dsn) as source,
            AsyncSession(engine, expire_on_commit=False) as session,
        ):
            active = await load_active_source(source)
            salaries, rent, repayments = select_recoverable(active)
            salary_account = await _target_reference(session, Account, "农业4873")
            salary_category = await _target_reference(session, Category, "工资")
            rent_account = await _target_reference(session, Account, "工商3495")
            if not isinstance(salary_account, Account) or not isinstance(rent_account, Account):
                raise RuntimeError("Target account resolution failed")
            if not isinstance(salary_category, Category):
                raise RuntimeError("Target category resolution failed")
            source_ids = {item.source_id for item in salaries} | {rent.source_id}
            before = await _audit_target(session, source_ids)
            payload: dict[str, Any] = {
                "schema_version": 1,
                "mode": command,
                "source_active_count": len(active),
                "selected_manual_count": len(source_ids),
                "selected_manual_minor": 3_630_000,
                "excluded_credit_repayment_count": len(repayments),
                "target_before": before,
                "ready": True,
            }
            if command == "dry-run":
                return payload
            database = str(before["database"])
            if command == "production-apply":
                if database != "fiscal":
                    raise RuntimeError(
                        "Production recovery requires the exact target database fiscal"
                    )
                if os.environ.get(PRODUCTION_CONFIRM_ENV) != PRODUCTION_CONFIRM_VALUE:
                    raise RuntimeError(
                        f"{PRODUCTION_CONFIRM_ENV} must equal {PRODUCTION_CONFIRM_VALUE}"
                    )
            elif command == "shadow-apply":
                if "shadow" not in database.casefold() and "drill" not in database.casefold():
                    raise RuntimeError("Shadow recovery target name must contain shadow or drill")
            elif command != "reconcile":
                raise RuntimeError(f"Unsupported command: {command}")

            if command != "reconcile":
                service = CashFlowService(session)
                await service.create(
                    CashFlowDraft(
                        title="工资",
                        direction=CashFlowDirection.INFLOW,
                        planned_amount_minor=500_000,
                        expected_date=EXPECTED_SALARY_DATES[0],
                        account_id=salary_account.id,
                        category_id=salary_category.id,
                        recurrence=CashFlowRecurrence.MONTHLY,
                        recurrence_end_date=EXPECTED_SALARY_DATES[-1],
                    ),
                    SALARY_KEY,
                    source=CashFlowSource.LEGACY_IMPORT,
                    legacy_source_ids=[item.source_id for item in salaries],
                    commit=False,
                )
                await service.create(
                    CashFlowDraft(
                        title=rent.title,
                        note=rent.note,
                        direction=CashFlowDirection.INFLOW,
                        planned_amount_minor=rent.amount_minor,
                        expected_date=rent.expected_date,
                        account_id=rent_account.id,
                    ),
                    RENT_KEY,
                    source=CashFlowSource.LEGACY_IMPORT,
                    legacy_source_ids=[rent.source_id],
                    commit=False,
                )
                await session.commit()

            after = await _audit_target(session, source_ids)
            if after["recovered_count"] != 7 or after["recovered_minor"] != 3_630_000:
                raise RuntimeError("Recovered cash flow reconciliation failed")
            if set(cast(list[str], after["legacy_source_ids"])) != source_ids:
                raise RuntimeError("Recovered source provenance does not match the audited 7 items")
            payload["target_after"] = after
            payload["passed"] = True
            return payload
    except BaseException:
        await engine.dispose()
        raise
    finally:
        await engine.dispose()


def main() -> None:
    parser = argparse.ArgumentParser(description="Recover the audited seven P13 cash flow plans")
    parser.add_argument(
        "command", choices=("dry-run", "shadow-apply", "production-apply", "reconcile")
    )
    arguments = parser.parse_args()
    source_value = os.environ.get(SOURCE_DSN_ENV, "").strip()
    target_value = os.environ.get(TARGET_DSN_ENV, "").strip()
    if not source_value or not target_value:
        raise RuntimeError(f"{SOURCE_DSN_ENV} and {TARGET_DSN_ENV} must be set")
    payload = asyncio.run(run(arguments.command, SecretStr(source_value), SecretStr(target_value)))
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
