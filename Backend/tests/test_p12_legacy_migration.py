import asyncio
import json
import stat
from pathlib import Path

import pytest
from pydantic import SecretStr

from fiscal_api.legacy_migration import planning as legacy_migration


class _Transaction:
    def __init__(self, events: list[object]) -> None:
        self.events = events

    async def start(self) -> None:
        self.events.append("start")

    async def commit(self) -> None:
        self.events.append("commit")

    async def rollback(self) -> None:
        self.events.append("rollback")


class _Connection:
    def __init__(self) -> None:
        self.events: list[object] = []

    def transaction(self, **kwargs: object) -> _Transaction:
        self.events.append(("transaction", kwargs))
        return _Transaction(self.events)

    async def fetchval(self, query: str, *args: object) -> object:
        self.events.append(("fetchval", query, args))
        return None

    async def close(self) -> None:
        self.events.append("close")


def _audit() -> dict[str, object]:
    return {
        "inventory": {
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
        },
        "accounts": [
            {"name": name}
            for name in ("农业4873", "工商3495", "杭联0519", "工商3576", "白条", "花呗", "车贷")
        ],
        "movement_types": sorted(legacy_migration.ALLOWED_MOVEMENT_TYPES),
        "source_objects": [],
    }


def test_source_dsn_is_required_and_wrapped_as_secret() -> None:
    with pytest.raises(RuntimeError, match="FISCAL_LEGACY_DATABASE_URL must be set"):
        legacy_migration._source_dsn({})
    secret = legacy_migration._source_dsn(
        {"FISCAL_LEGACY_DATABASE_URL": "postgresql://secret@example/legacy"}
    )
    assert isinstance(secret, SecretStr)
    assert "secret" not in repr(secret)


def test_source_session_is_repeatable_read_readonly_and_has_timeout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    connection = _Connection()

    async def connect(*, dsn: str) -> _Connection:
        assert dsn == "postgresql://secret@example/legacy"
        return connection

    monkeypatch.setattr(legacy_migration.asyncpg, "connect", connect)

    async def exercise() -> None:
        async with legacy_migration.legacy_source(SecretStr("postgresql://secret@example/legacy")):
            pass

    asyncio.run(exercise())
    assert connection.events[0] == (
        "transaction",
        {"isolation": "repeatable_read", "readonly": True},
    )
    assert connection.events[1] == "start"
    assert connection.events[2] == (
        "fetchval",
        "SELECT set_config('statement_timeout', $1, true)",
        ("15000ms",),
    )
    assert connection.events[-2:] == ["commit", "close"]


def test_confirmed_policy_and_plan_are_frozen_without_business_writes() -> None:
    plan = legacy_migration.build_dry_run_plan(_audit())
    assert plan["writes_fiscal_business_tables"] is False
    assert plan["ready_for_transform_planning"] is True
    assert plan["ready_for_apply"] is False
    assert plan["candidate_summary"] == {
        "accounts": 7,
        "confirmed_cny_single_entries": 112,
        "confirmed_cny_transfers_or_repayments": 9,
        "received_reimbursements": 6,
        "abandoned_reimbursements": 1,
    }
    policy = plan["policy"]
    assert policy["period_start"] == legacy_migration.date(2026, 5, 16)
    assert policy["period_end"] == legacy_migration.date(2026, 7, 14)
    assert policy["timezone"] == "Asia/Shanghai"
    assert policy["occurrence_hour"] == 12
    assert {
        account["source_name"]: account["opening_balance_minor"]
        for account in policy["accounts"]
        if account["target_kind"] == "credit"
    } == {
        "工商3576": 433_727,
        "白条": 400_297,
        "花呗": 111_577,
        "车贷": 1_773_100,
    }
    assert policy["orphan_repayment_treatment"] == (
        "opening_liability_adjustment_without_cash_flow"
    )
    assert policy["reimbursement_party_aliases"] == {
        "company": "公司",
        "公司": "公司",
        "111": "公司",
    }
    assert policy["expense_categories"]["平账"] == "平账"
    assert policy["expense_categories"]["理财"] == "理财"


def test_changed_source_inventory_blocks_object_planning() -> None:
    audit = _audit()
    audit["inventory"]["financial_entries"] = 134  # type: ignore[index]
    plan = legacy_migration.build_dry_run_plan(audit)
    assert plan["ready_for_transform_planning"] is False
    assert plan["conflicts"]["inventory_changed_since_approved_audit"] == {  # type: ignore[index]
        "financial_entries": {"expected": 133, "actual": 134}
    }


def test_unknown_legacy_movement_type_fails_closed() -> None:
    audit = _audit()
    audit["movement_types"] = [*legacy_migration.ALLOWED_MOVEMENT_TYPES, "credit_purchase"]
    plan = legacy_migration.build_dry_run_plan(audit)
    assert plan["ready_for_transform_planning"] is False
    assert plan["conflicts"]["unknown_movement_types"] == ["credit_purchase"]  # type: ignore[index]


def test_source_object_manifest_hashes_payload_without_emitting_it() -> None:
    row = {
        "object_type": "financial_entries",
        "source_id": "entry-1",
        "source_payload": '{"amount":"10.00","id":"entry-1"}',
        "name": None,
        "status": "confirmed",
        "entry_type": "single",
        "movement_type": None,
    }
    source = legacy_migration._source_object(row)
    assert source["source_identity"] == "financial_entries:entry-1"
    assert len(source["source_row_hash"] or "") == 64
    assert source["hash_scope"] == "row_only_not_apply_provenance"
    assert "source_payload" not in source
    planned = legacy_migration._plan_source_object(source)
    assert planned["action"] == "candidate"


def test_report_file_is_json_utf8_and_owner_only(tmp_path: Path) -> None:
    output = tmp_path / "plan.json"
    legacy_migration._write_report({"party": "公司"}, output)
    assert json.loads(output.read_text(encoding="utf-8")) == {"party": "公司"}
    assert stat.S_IMODE(output.stat().st_mode) == 0o600
