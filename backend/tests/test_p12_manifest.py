from __future__ import annotations

import asyncio
from copy import deepcopy
from datetime import date
from decimal import Decimal

from fiscal_api.legacy_migration.manifest import build_resolved_manifest


class SnapshotConnection:
    def __init__(self, fixture: dict[str, list[dict[str, object]]]) -> None:
        self.fixture = fixture

    async def fetch(self, query: str, *args: object) -> list[dict[str, object]]:
        del args
        if "FROM accounts ORDER BY id" in query:
            return self.fixture["accounts"]
        if "FROM categories ORDER BY id" in query:
            return self.fixture["categories"]
        if "FROM financial_entries ORDER BY date, id" in query:
            return self.fixture["entries"]
        if "FROM entry_category_lines l" in query:
            return self.fixture["lines"]
        if "FROM account_movements m" in query:
            return self.fixture["movements"]
        if "FROM reimbursement_claims ORDER BY id" in query:
            return self.fixture["claims"]
        if "FROM account_adjustments t" in query:
            return self.fixture["supplemental"]
        raise AssertionError(query)

    async def fetchval(self, query: str, *args: object) -> object:
        del args
        if query == "SELECT current_database()":
            return "linofinance"
        raise AssertionError(query)


def _account(
    account_id: str,
    name: str,
    kind: str,
    *,
    limit: str | None = None,
    statement_day: int | None = None,
    due_day: int | None = None,
) -> dict[str, object]:
    return {
        "id": account_id,
        "name": name,
        "type": kind,
        "currency": "CNY",
        "current_balance": Decimal("0"),
        "current_liability": Decimal("0"),
        "credit_limit": Decimal(limit) if limit else None,
        "statement_day": statement_day,
        "due_day": due_day,
        "status": "active",
    }


def _snapshot() -> dict[str, list[dict[str, object]]]:
    accounts: list[dict[str, object]] = [
        _account("a-agri", "农业4873", "balance"),
        _account("a-icbc", "工商3495", "balance"),
        _account("a-hl", "杭联0519", "balance"),
        _account("a-3576", "工商3576", "credit", limit="10000", statement_day=25, due_day=12),
        _account("a-bt", "白条", "credit", limit="42000", statement_day=1, due_day=11),
        _account("a-hb", "花呗", "credit", limit="13000", statement_day=1, due_day=8),
        _account("a-car", "车贷", "credit", limit="200000", statement_day=20, due_day=22),
        _account("a-stock", "Stock", "investment"),
    ]
    categories: list[dict[str, object]] = [
        {
            "id": "c-food",
            "name": "吃饭",
            "type": "expense",
            "parent_id": None,
            "is_active": True,
            "display_order": 1,
        },
        {
            "id": "c-reimb",
            "name": "报销",
            "type": "income",
            "parent_id": None,
            "is_active": True,
            "display_order": 2,
        },
    ]
    entries: list[dict[str, object]] = []
    lines: list[dict[str, object]] = []
    movements: list[dict[str, object]] = []
    claims: list[dict[str, object]] = []

    def entry(entry_id: str, title: str, entry_type: str = "single") -> None:
        entries.append(
            {
                "id": entry_id,
                "title": title,
                "entry_type": entry_type,
                "date": date(2026, 6, 1),
                "status": "confirmed",
                "note": None,
                "created_by": "user",
                "created_at": "fixture-created",
                "updated_at": "fixture-updated",
            }
        )

    def line(entry_id: str, *, direction: str = "expense", category: str = "吃饭") -> None:
        lines.append(
            {
                "id": f"l-{entry_id}",
                "entry_id": entry_id,
                "category_id": "c-food" if direction == "expense" else "c-reimb",
                "direction": direction,
                "amount": Decimal("1"),
                "currency": "CNY",
                "converted_cny_amount": Decimal("1"),
                "reimbursable_flag": False,
                "reimbursement_payer": None,
                "reimbursement_expected_date": None,
                "reimbursement_status": None,
                "note": None,
                "category_name": category,
                "category_type": direction,
            }
        )

    def movement(
        entry_id: str,
        movement_type: str,
        account_id: str,
        amount: str,
        *,
        cycle_status: str | None = None,
    ) -> None:
        account = next(row for row in accounts if row["id"] == account_id)
        movements.append(
            {
                "id": f"m-{entry_id}-{movement_type}",
                "entry_id": entry_id,
                "account_id": account_id,
                "statement_cycle_id": "cycle" if cycle_status else None,
                "movement_type": movement_type,
                "amount": Decimal(amount),
                "currency": "CNY",
                "converted_cny_amount": Decimal(amount),
                "note": None,
                "account_name": account["name"],
                "account_type": account["type"],
                "account_currency": "CNY",
                "cycle_start_date": date(2026, 5, 2) if cycle_status else None,
                "cycle_end_date": date(2026, 6, 1) if cycle_status else None,
                "statement_cycle_status": cycle_status,
            }
        )

    # 100 ordinary entries, with the first six serving as reimbursement expenses.
    for index in range(100):
        entry_id = f"expense-{index:03d}"
        entry(entry_id, f"消费 {index}")
        line(entry_id)
        movement(entry_id, "balance_out", "a-agri", "1")

    for index in range(4):
        entry_id = f"transfer-{index}"
        entry(entry_id, "转账", "transfer")
        movement(entry_id, "transfer_out", "a-agri", "1")
        movement(entry_id, "transfer_in", "a-icbc", "1")

    repayment_specs = [
        ("repay-3576-a", "a-3576", "1039.93"),
        ("repay-3576-b", "a-3576", "1499.67"),
        ("repay-car", "a-car", "2533.00"),
        ("repay-bt", "a-bt", "4216.07"),
        ("repay-hb", "a-hb", "1510.93"),
    ]
    for entry_id, credit_id, amount in repayment_specs:
        entry(entry_id, "信用还款", "transfer")
        movement(entry_id, "transfer_out", "a-icbc", amount)
        movement(entry_id, "credit_repayment", credit_id, amount)

    entry("orphan", "白条提前还款")
    movement("orphan", "credit_repayment", "a-bt", "1410.64")

    for index in range(6):
        entry_id = f"receipt-income-{index}"
        entry(entry_id, "报销收入")
        line(entry_id, direction="income", category="报销")
        movement(entry_id, "balance_in", "a-agri", "1")
        claims.append(
            {
                "id": f"claim-{index}",
                "linked_entry_id": f"expense-{index:03d}",
                "linked_entry_line_id": f"l-expense-{index:03d}",
                "amount": Decimal("1"),
                "currency": "CNY",
                "converted_cny_amount": Decimal("1"),
                "payer": ("company", "公司", "111")[index % 3],
                "expected_date": date(2026, 6, 1),
                "actual_received_date": date(2026, 6, 2),
                "received_account_id": "a-agri",
                "received_entry_id": entry_id,
                "status": "received",
                "note": None,
                "created_at": "fixture-created",
                "updated_at": "fixture-updated",
            }
        )

    # These are raw CNY/account candidates, but semantic cycle evidence excludes them.
    for index in range(5):
        entry_id = f"void-cycle-{index}"
        entry(entry_id, "花呗旧账")
        line(entry_id)
        movement(entry_id, "credit_charge", "a-hb", "1", cycle_status="voided")

    # An aggregate may never be partially imported across the excluded boundary.
    entry("cross-boundary", "证券划转", "transfer")
    movement("cross-boundary", "transfer_out", "a-agri", "1")
    movement("cross-boundary", "transfer_in", "a-stock", "1")

    supplemental: list[dict[str, object]] = [
        {"object_type": "cash_flow_items", "source_id": f"cf-{index}", "payload": "{}"}
        for index in range(43)
    ]
    return {
        "accounts": accounts,
        "categories": categories,
        "entries": entries,
        "lines": lines,
        "movements": movements,
        "claims": claims,
        "supplemental": supplemental,
    }


def test_real_shape_snapshot_resolves_121_candidates_without_duplicate_income() -> None:
    manifest = asyncio.run(build_resolved_manifest(SnapshotConnection(_snapshot())))  # type: ignore[arg-type]

    assert manifest.selection_scope["raw_candidate_entries"] == 121
    assert len(manifest.accounts) == 7
    assert len(manifest.transactions) == 111
    assert len(manifest.receipts) == 6
    assert len(manifest.transactions) + len(manifest.receipts) == 117
    assert len(manifest.claims) == 6
    assert {receipt.party_name for receipt in manifest.claims} == {"公司"}
    assert not any(
        transaction.source.object_id.startswith("receipt-income-")
        for transaction in manifest.transactions
    )
    assert (
        sum(
            transaction.amount_minor
            for transaction in manifest.transactions
            if transaction.kind == "repayment"
        )
        == 1_079_960
    )
    assert (
        sum(
            1
            for transaction in manifest.transactions
            if "#repayment_part_" in transaction.source.object_id
        )
        == 4
    )

    reasons = {item.source.object_id: item.reason for item in manifest.skipped}
    assert reasons["cross-boundary"] == "aggregate_touches_excluded_account"
    assert reasons["orphan"] == "opening_liability_adjustment_without_cash_flow"
    assert {reasons[f"void-cycle-{index}"] for index in range(5)} == {
        "confirmed_entry_on_voided_credit_cycle"
    }
    assert (
        sum(
            reason == "cash_flow_rebuilt_from_fiscal_ledger"
            for reason in reasons.values()
        )
        == 43
    )

    huabei = next(account for account in manifest.accounts if account.name == "花呗")
    assert huabei.opening_balance_minor == 111_577
    assert huabei.opening_due_date == date(2026, 8, 8)


def test_manifest_hashes_include_ordered_dependencies_and_are_reproducible() -> None:
    snapshot = _snapshot()
    first = asyncio.run(build_resolved_manifest(SnapshotConnection(snapshot)))  # type: ignore[arg-type]
    replay = asyncio.run(build_resolved_manifest(SnapshotConnection(deepcopy(snapshot))))  # type: ignore[arg-type]
    assert first == replay

    changed_snapshot = deepcopy(snapshot)
    changed_movement = next(
        row for row in changed_snapshot["movements"] if row["entry_id"] == "expense-099"
    )
    changed_movement["note"] = "dependency changed"
    changed = asyncio.run(
        build_resolved_manifest(SnapshotConnection(changed_snapshot))  # type: ignore[arg-type]
    )
    assert changed.source_database_fingerprint == first.source_database_fingerprint
    original_tx = next(
        item for item in first.transactions if item.source.object_id == "expense-099"
    )
    changed_tx = next(
        item for item in changed.transactions if item.source.object_id == "expense-099"
    )
    assert changed_tx.source.content_hash != original_tx.source.content_hash

    added_excluded = deepcopy(snapshot)
    added_excluded["accounts"].append(_account("a-extra", "新投资账户", "investment"))
    changed_inventory = asyncio.run(
        build_resolved_manifest(SnapshotConnection(added_excluded))  # type: ignore[arg-type]
    )
    assert changed_inventory.source_database_fingerprint == first.source_database_fingerprint
