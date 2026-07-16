from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from collections.abc import Mapping, Sequence
from datetime import date
from decimal import Decimal
from typing import Any, Final, cast

from fiscal_api.legacy_migration.apply import (
    AccountImport,
    CategoryImport,
    ClaimImport,
    LegacyManifest,
    ReceiptImport,
    SkippedImport,
    SourceIdentity,
    TransactionImport,
)
from fiscal_api.legacy_migration.planning import P12_POLICY, SourceConnection
from fiscal_api.legacy_migration.transform import (
    legacy_date_to_occurred_at,
    mapped_category,
    normalize_reimbursement_party,
    yuan_to_minor,
)

_OPENING_AS_OF: Final = date(2026, 5, 15)
_OPENING_DUE_DATES: Final = {
    "工商3576": date(2026, 8, 12),
    "白条": date(2026, 8, 11),
    "花呗": date(2026, 8, 8),
    "车贷": date(2026, 7, 22),
}
# Five confirmed Huabei charges point at a legacy cycle which was later voided and
# is absent from the authoritative closing liability.  Excluding them changes the
# approved opening liability from the preliminary audit value to CNY 1,115.77.
_OPENING_OVERRIDES: Final = {"花呗": 111_577}
_WHITE_BAR_ORPHAN_AMOUNT: Final = 141_064


class LegacyManifestError(RuntimeError):
    """The source snapshot cannot be resolved without guessing."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


async def build_resolved_manifest(connection: SourceConnection) -> LegacyManifest:
    """Resolve P12 inside the caller's single read-only repeatable-read snapshot."""
    account_rows = await connection.fetch(
        """SELECT id, name, type, currency, current_balance, current_liability,
                  credit_limit, statement_day, due_day, status
             FROM accounts ORDER BY id"""
    )
    category_rows = await connection.fetch(
        """SELECT id, name, type, parent_id, is_active, display_order
             FROM categories ORDER BY id"""
    )
    entry_rows = await connection.fetch(
        """SELECT id, title, entry_type, date, status, note, created_by,
                  created_at, updated_at
             FROM financial_entries ORDER BY date, id"""
    )
    line_rows = await connection.fetch(
        """SELECT l.id, l.entry_id, l.category_id, l.direction, l.amount,
                  l.currency, l.converted_cny_amount, l.reimbursable_flag,
                  l.reimbursement_payer, l.reimbursement_expected_date,
                  l.reimbursement_status, l.note,
                  c.name AS category_name, c.type AS category_type
             FROM entry_category_lines l
             LEFT JOIN categories c ON c.id = l.category_id
            ORDER BY l.entry_id, l.id"""
    )
    movement_rows = await connection.fetch(
        """SELECT m.id, m.entry_id, m.account_id, m.statement_cycle_id,
                  m.movement_type, m.amount, m.currency,
                  m.converted_cny_amount, m.note,
                  a.name AS account_name, a.type AS account_type,
                  a.currency AS account_currency,
                  c.cycle_start_date, c.cycle_end_date,
                  c.status AS statement_cycle_status
             FROM account_movements m
             LEFT JOIN accounts a ON a.id = m.account_id
             LEFT JOIN credit_statement_cycles c ON c.id = m.statement_cycle_id
            ORDER BY m.entry_id, m.id"""
    )
    claim_rows = await connection.fetch(
        """SELECT id, linked_entry_id, linked_entry_line_id, amount, currency,
                  converted_cny_amount, payer, expected_date,
                  actual_received_date, received_account_id,
                  received_entry_id, status, note, created_at, updated_at
             FROM reimbursement_claims ORDER BY id"""
    )
    supplemental_rows = await connection.fetch(
        """SELECT object_type, source_id, payload
             FROM (
               SELECT 'account_adjustments' AS object_type, id AS source_id,
                      to_jsonb(t)::text AS payload FROM account_adjustments t
               UNION ALL SELECT 'cash_flow_items', id, to_jsonb(t)::text
                 FROM cash_flow_items t
               UNION ALL SELECT 'credit_statement_cycles', id, to_jsonb(t)::text
                 FROM credit_statement_cycles t
               UNION ALL SELECT 'installment_plans', id, to_jsonb(t)::text
                 FROM installment_plans t
               UNION ALL SELECT 'attachments', id, to_jsonb(t)::text
                 FROM attachments t
             ) source_objects ORDER BY object_type, source_id"""
    )

    accounts_by_id = {_str(row, "id"): row for row in account_rows}
    selected_by_name = {plan.source_name: plan for plan in P12_POLICY.accounts}
    selected_account_ids = {
        _str(row, "id")
        for row in account_rows
        if _str(row, "name") in selected_by_name
    }
    if {str(row["name"]) for row in account_rows if row["name"] in selected_by_name} != set(
        selected_by_name
    ):
        raise LegacyManifestError("missing_selected_account", "not all approved accounts exist")

    # The database fingerprint identifies one source installation and must remain
    # stable when its rows change. Per-object/manifest hashes carry content changes;
    # mixing content into this fingerprint would bypass the changed-source guard.
    database = str(await connection.fetchval("SELECT current_database()"))
    fingerprint = _digest(
        {
            "source_system": "linofinance",
            "database": database,
            # The seven approved account UUIDs are immutable source anchors. New
            # excluded accounts must change the manifest/preflight, not the source
            # installation identity used by provenance conflict detection.
            "selected_account_ids": sorted(selected_account_ids),
        }
    )

    account_imports: list[AccountImport] = []
    skipped: list[SkippedImport] = []
    for row in account_rows:
        account_id = _str(row, "id")
        name = _str(row, "name")
        source = _source("accounts", account_id, row)
        plan = selected_by_name.get(name)
        if plan is None:
            skipped.append(SkippedImport(source, "excluded_account"))
            continue
        if _str(row, "currency") != "CNY" or _str(row, "status") != "active":
            raise LegacyManifestError("invalid_selected_account", name)
        opening = _OPENING_OVERRIDES.get(name, plan.opening_balance_minor)
        if opening is None:
            raise LegacyManifestError("missing_opening_balance", name)
        is_credit = plan.target_kind == "credit"
        account_imports.append(
            AccountImport(
                source=source,
                name=name,
                kind=cast(Any, plan.target_kind),
                opening_balance_minor=opening,
                last_four=_last_four(name),
                credit_limit_minor=(
                    _money(row, "credit_limit") if is_credit else None
                ),
                statement_day=_optional_int(row.get("statement_day")) if is_credit else None,
                due_day=_optional_int(row.get("due_day")) if is_credit else None,
                opening_balance_as_of_date=_OPENING_AS_OF if is_credit else None,
                opening_due_date=_OPENING_DUE_DATES.get(name) if is_credit else None,
            )
        )

    category_imports = _category_imports(category_rows)
    category_source_ids = {
        (item.direction, item.name): item.source.object_id for item in category_imports
    }
    for row in category_rows:
        skipped.append(
            SkippedImport(
                _source("legacy_categories", _str(row, "id"), row),
                "legacy_category_definition_replaced",
            )
        )

    lines_by_entry: dict[str, list[Mapping[str, object]]] = defaultdict(list)
    for row in line_rows:
        lines_by_entry[_str(row, "entry_id")].append(row)
    movements_by_entry: dict[str, list[Mapping[str, object]]] = defaultdict(list)
    for row in movement_rows:
        movements_by_entry[_str(row, "entry_id")].append(row)

    received_claims = [row for row in claim_rows if _str(row, "status") == "received"]
    suppressed_income_ids = {_str(row, "received_entry_id") for row in received_claims}
    transactions: list[TransactionImport] = []
    imported_entry_ids: set[str] = set()
    raw_candidate_count = 0
    for entry in entry_rows:
        entry_id = _str(entry, "id")
        lines = lines_by_entry.get(entry_id, [])
        movements = movements_by_entry.get(entry_id, [])
        aggregate = {"entry": entry, "category_lines": lines, "movements": movements}
        source = _source("financial_entries", entry_id, aggregate)
        reason = _entry_skip_reason(entry, lines, movements, selected_account_ids)
        if reason is not None:
            if reason == "confirmed_entry_on_voided_credit_cycle":
                raw_candidate_count += 1
            skipped.append(SkippedImport(source, reason))
            continue
        raw_candidate_count += 1
        if entry_id in suppressed_income_ids:
            skipped.append(SkippedImport(source, "suppressed_reimbursement_income"))
            continue
        resolved = _resolve_transaction(
            entry, lines, movements, accounts_by_id, category_source_ids, source
        )
        if resolved is None:
            skipped.append(
                SkippedImport(source, "opening_liability_adjustment_without_cash_flow")
            )
            continue
        if lines and any(item.category_source_id is None for item in resolved):
            for line in lines:
                skipped.append(
                    SkippedImport(
                        _source("entry_category_lines", _str(line, "id"), line),
                        "unmapped_category_imported_uncategorized",
                    )
                )
        transactions.extend(resolved)
        imported_entry_ids.add(entry_id)

    claims: list[ClaimImport] = []
    receipts: list[ReceiptImport] = []
    entries_by_id = {_str(row, "id"): row for row in entry_rows}
    for row in claim_rows:
        claim_id = _str(row, "id")
        linked_entry_id = _str(row, "linked_entry_id")
        claim_source = _source(
            "reimbursement_claims",
            claim_id,
            {
                "claim": row,
                "linked_entry": entries_by_id.get(linked_entry_id),
                "linked_line": next(
                    (
                        line
                        for line in line_rows
                        if _str(line, "id") == row.get("linked_entry_line_id")
                    ),
                    None,
                ),
            },
        )
        status = _str(row, "status")
        if status == "abandoned":
            skipped.append(SkippedImport(claim_source, "abandoned_claim_expense_only"))
            continue
        if status != "received":
            raise LegacyManifestError("unsupported_claim_status", status)
        if linked_entry_id not in imported_entry_ids:
            raise LegacyManifestError("claim_expense_not_imported", claim_id)
        received_account_id = _str(row, "received_account_id")
        if received_account_id not in selected_account_ids:
            raise LegacyManifestError("claim_receipt_account_excluded", claim_id)
        party = normalize_reimbursement_party(_str(row, "payer"))
        amount = _money(row, "amount")
        linked_entry = entries_by_id[linked_entry_id]
        claims.append(
            ClaimImport(
                source=claim_source,
                title=f"{party}报销 · {_str(linked_entry, 'title')}",
                expense_transaction_source_id=linked_entry_id,
                amount_minor=amount,
                party_name=party,
                expected_date=_optional_date(row.get("expected_date")),
                note=_optional_str(row.get("note")),
            )
        )
        received_entry_id = _str(row, "received_entry_id")
        received_entry = entries_by_id.get(received_entry_id)
        if received_entry is None:
            raise LegacyManifestError("missing_received_entry", claim_id)
        received_date = _required_date(row.get("actual_received_date"), "actual_received_date")
        receipt_source = _source(
            "reimbursement_receipts",
            claim_id,
            {"claim": row, "received_entry": received_entry},
        )
        receipts.append(
            ReceiptImport(
                source=receipt_source,
                claim_source_id=claim_id,
                destination_account_source_id=received_account_id,
                amount_minor=amount,
                received_at=legacy_date_to_occurred_at(received_date),
                title=f"{party}报销到账",
                suppressed_income_source_id=received_entry_id,
                note=_optional_str(row.get("note")),
            )
        )

    for row in supplemental_rows:
        object_type = _str(row, "object_type")
        reason = {
            "account_adjustments": "investment_adjustment_excluded",
            "cash_flow_items": "cash_flow_rebuilt_from_fiscal_ledger",
            "credit_statement_cycles": "legacy_cycle_reconciliation_only",
            "installment_plans": "legacy_installment_definition_excluded",
            "attachments": "legacy_attachment_definition_excluded",
        }.get(object_type)
        if reason is None:
            raise LegacyManifestError("unknown_supplemental_object", object_type)
        skipped.append(
            SkippedImport(
                _source(object_type, _str(row, "source_id"), {"payload": row.get("payload")}),
                reason,
            )
        )

    return LegacyManifest(
        source_database_fingerprint=fingerprint,
        accounts=tuple(account_imports),
        categories=tuple(category_imports),
        transactions=tuple(transactions),
        claims=tuple(claims),
        receipts=tuple(receipts),
        skipped=tuple(skipped),
        selection_scope={
            "period_start": P12_POLICY.period_start.isoformat(),
            "period_end": P12_POLICY.period_end.isoformat(),
            "timezone": P12_POLICY.timezone,
            "occurrence_hour": P12_POLICY.occurrence_hour,
            "raw_candidate_entries": raw_candidate_count,
            "opening_balance_as_of": _OPENING_AS_OF.isoformat(),
            "legacy_cycle_reconciliation": (
                "total_liability_only_historical_cycles_not_reconstructable"
            ),
        },
    )


load_resolved_manifest = build_resolved_manifest


def _entry_skip_reason(
    entry: Mapping[str, object],
    lines: Sequence[Mapping[str, object]],
    movements: Sequence[Mapping[str, object]],
    selected_account_ids: set[str],
) -> str | None:
    status = _str(entry, "status")
    if status != "confirmed":
        if status == "voided":
            return "voided_entry"
        raise LegacyManifestError("unsupported_entry_status", status)
    occurred = _required_date(entry.get("date"), "date")
    if not P12_POLICY.period_start <= occurred <= P12_POLICY.period_end:
        return "outside_selected_period"
    if not movements:
        raise LegacyManifestError("entry_without_movement", _str(entry, "id"))
    if any(_str(movement, "currency") != "CNY" for movement in movements) or any(
        _str(line, "currency") != "CNY" for line in lines
    ):
        return "non_cny_aggregate"
    if any(_str(movement, "account_id") not in selected_account_ids for movement in movements):
        return "aggregate_touches_excluded_account"
    if any(
        movement.get("statement_cycle_status") == "voided"
        and movement.get("movement_type") == "credit_charge"
        for movement in movements
    ):
        return "confirmed_entry_on_voided_credit_cycle"
    return None


def _resolve_transaction(
    entry: Mapping[str, object],
    lines: Sequence[Mapping[str, object]],
    movements: Sequence[Mapping[str, object]],
    accounts_by_id: Mapping[str, Mapping[str, object]],
    category_source_ids: Mapping[tuple[str, str], str],
    source: SourceIdentity,
) -> list[TransactionImport] | None:
    entry_id = _str(entry, "id")
    occurred_at = legacy_date_to_occurred_at(_required_date(entry.get("date"), "date"))
    title = _str(entry, "title")
    note = _optional_str(entry.get("note"))
    movement_types = [_str(row, "movement_type") for row in movements]

    if len(movements) == 1 and movement_types == ["credit_repayment"] and not lines:
        movement = movements[0]
        if (
            title == "白条提前还款"
            and _money(movement, "amount") == _WHITE_BAR_ORPHAN_AMOUNT
            and _str(accounts_by_id[_str(movement, "account_id")], "name") == "白条"
        ):
            return None
        raise LegacyManifestError("repayment_missing_paying_account", entry_id)

    if len(movements) == 1 and len(lines) == 1:
        movement, line = movements[0], lines[0]
        amount = _money(movement, "amount")
        if amount != _money(line, "amount"):
            raise LegacyManifestError("entry_amount_mismatch", entry_id)
        direction = _str(line, "direction")
        movement_type = _str(movement, "movement_type")
        if (direction, movement_type) == ("income", "balance_in"):
            kind = "income"
        elif (direction, movement_type) == ("expense", "balance_out"):
            kind = "expense"
        elif (direction, movement_type) == ("expense", "credit_charge"):
            kind = "credit_purchase"
        else:
            raise LegacyManifestError("unsupported_single_entry_shape", entry_id)
        mapped = mapped_category(direction, _str(line, "category_name"))
        category_source_id = (
            category_source_ids.get((direction, mapped)) if mapped is not None else None
        )
        return [
            TransactionImport(
                source=source,
                kind=cast(Any, kind),
                amount_minor=amount,
                occurred_at=occurred_at,
                title=title,
                account_source_id=_str(movement, "account_id"),
                note=note,
                category_source_id=category_source_id,
            )
        ]

    if lines:
        raise LegacyManifestError("transfer_has_category_lines", entry_id)
    if len(movements) != 2:
        raise LegacyManifestError("unsupported_transfer_shape", entry_id)
    by_type = {_str(row, "movement_type"): row for row in movements}
    if set(by_type) == {"transfer_out", "transfer_in"}:
        source_movement, destination = by_type["transfer_out"], by_type["transfer_in"]
        amount = _equal_movement_amounts(entry_id, movements)
        return [
            TransactionImport(
                source=source,
                kind="transfer",
                amount_minor=amount,
                occurred_at=occurred_at,
                title=title,
                account_source_id=_str(source_movement, "account_id"),
                destination_account_source_id=_str(destination, "account_id"),
                note=note,
            )
        ]
    if set(by_type) != {"transfer_out", "credit_repayment"}:
        raise LegacyManifestError("unsupported_transfer_shape", entry_id)
    amount = _equal_movement_amounts(entry_id, movements)
    paying = by_type["transfer_out"]
    credit = by_type["credit_repayment"]
    credit_name = _str(accounts_by_id[_str(credit, "account_id")], "name")
    split = _repayment_split(credit_name, amount)
    result: list[TransactionImport] = []
    for index, (part_amount, selector, period_start, period_end) in enumerate(split, 1):
        part_source = SourceIdentity(
            source.object_type,
            entry_id if len(split) == 1 else f"{entry_id}#repayment_part_{index}",
            _digest(
                {
                    "aggregate_hash": source.content_hash,
                    "part": index,
                    "amount_minor": part_amount,
                    "cycle_selector": selector,
                    "period_start": period_start,
                    "period_end": period_end,
                }
            ),
        )
        result.append(
            TransactionImport(
                source=part_source,
                kind="repayment",
                amount_minor=part_amount,
                occurred_at=occurred_at,
                title=title,
                account_source_id=_str(paying, "account_id"),
                destination_account_source_id=_str(credit, "account_id"),
                note=note,
                credit_cycle_selector=cast(Any, selector),
                credit_cycle_period_start=period_start,
                credit_cycle_period_end=period_end,
            )
        )
    return result


def _repayment_split(
    credit_name: str, amount: int
) -> list[tuple[int, str, date | None, date | None]]:
    if credit_name == "白条" and amount == 421_607:
        return [
            (400_297, "opening", None, None),
            (21_310, "period", date(2026, 6, 2), date(2026, 7, 1)),
        ]
    if credit_name == "花呗" and amount == 151_093:
        return [
            (111_577, "opening", None, None),
            (39_516, "period", date(2026, 6, 2), date(2026, 7, 1)),
        ]
    if credit_name in {"工商3576", "车贷"}:
        return [(amount, "opening", None, None)]
    raise LegacyManifestError("unapproved_repayment_allocation", credit_name)


def _category_imports(rows: Sequence[Mapping[str, object]]) -> list[CategoryImport]:
    imports: list[CategoryImport] = []
    for direction, mapping in (
        ("expense", P12_POLICY.expense_categories),
        ("income", P12_POLICY.income_categories),
    ):
        for target_name in sorted(set(mapping.values())):
            dependencies = [
                row
                for row in rows
                if _str(row, "type") == direction
                and mapping.get(_str(row, "name")) == target_name
            ]
            source_id = f"{direction}:{target_name}"
            imports.append(
                CategoryImport(
                    source=SourceIdentity(
                        "categories",
                        source_id,
                        _digest(
                            {
                                "direction": direction,
                                "target_name": target_name,
                                "legacy_dependencies": dependencies,
                            }
                        ),
                    ),
                    name=target_name,
                    direction=cast(Any, direction),
                )
            )
    return imports


def _equal_movement_amounts(entry_id: str, rows: Sequence[Mapping[str, object]]) -> int:
    amounts = {_money(row, "amount") for row in rows}
    if len(amounts) != 1:
        raise LegacyManifestError("transfer_amount_mismatch", entry_id)
    return amounts.pop()


def _source(object_type: str, object_id: str, payload: object) -> SourceIdentity:
    return SourceIdentity(object_type, object_id, _digest(payload))


def _digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            _canonical(value), ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode()
    ).hexdigest()


def _canonical(value: object) -> object:
    if isinstance(value, Mapping):
        mapping = cast(Mapping[object, object], value)
        return {
            str(key): _canonical(item)
            for key, item in sorted(mapping.items(), key=lambda pair: str(pair[0]))
        }
    if isinstance(value, (list, tuple)):
        sequence = cast(Sequence[object], value)
        return [_canonical(item) for item in sequence]
    if isinstance(value, (date, Decimal)):
        return str(value)
    if isinstance(value, (str, int, bool)) or value is None:
        return value
    return str(value)


def _str(row: Mapping[str, object], key: str) -> str:
    value = row.get(key)
    if not isinstance(value, str) or not value:
        raise LegacyManifestError("invalid_string", key)
    return value


def _optional_str(value: object) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise LegacyManifestError("invalid_optional_string", str(value))
    return value or None


def _money(row: Mapping[str, object], key: str) -> int:
    value = row.get(key)
    if not isinstance(value, Decimal):
        raise LegacyManifestError("invalid_money_type", key)
    return yuan_to_minor(value, field=key)


def _optional_int(value: object) -> int | None:
    if value is None:
        return None
    if not isinstance(value, int):
        raise LegacyManifestError("invalid_integer", str(value))
    return value


def _required_date(value: object, field: str) -> date:
    if not isinstance(value, date):
        raise LegacyManifestError("invalid_date", field)
    return value


def _optional_date(value: object) -> date | None:
    if value is None:
        return None
    return _required_date(value, "optional_date")


def _last_four(name: str) -> str | None:
    digits = "".join(character for character in name if character.isdigit())
    return digits[-4:] if len(digits) >= 4 else None
