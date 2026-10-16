"""Public Fiscal MCP tool contracts.

This module is intentionally independent of the Fiscal backend's Pydantic
models.  The backend may evolve internally while the Agent-facing contract
stays stable.  Inputs are validated at the MCP boundary and only JSON-safe
objects leave this package.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import date, datetime
from enum import Enum
from typing import Any, Mapping

from .errors import FiscalMCPError, invalid_params

PERIOD_RE = re.compile(r"^\d{4}-(?:0[1-9]|1[0-2])$")
YEAR_RE = re.compile(r"^\d{4}$")
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
MAX_CANDIDATES = 500
MAX_TEXT_LENGTH = 2_000

CANDIDATE_PROPERTIES: dict[str, Any] = {
    "client_id": {"type": "string", "minLength": 1, "maxLength": 120},
    "kind": {"type": "string", "minLength": 1, "maxLength": 32},
    "amount_minor": {"type": "integer", "minimum": 1},
    "occurred_at": {"type": "string", "format": "date-time"},
    "title": {"type": "string", "minLength": 1, "maxLength": 120},
    "note": {"type": ["string", "null"], "maxLength": 500},
    "account_id": {"type": ["string", "null"]},
    "category_id": {"type": ["string", "null"]},
    "destination_account_id": {"type": ["string", "null"]},
    "credit_cycle_id": {
        "type": ["string", "null"],
        "description": "Required for repayments to fixed-cycle credit accounts; pick from fiscal_list_accounts open_cycles.",
    },
    "field_confidences": {"type": "object", "additionalProperties": {"type": "integer", "minimum": 0, "maximum": 10000}},
    "overall_confidence_bps": {"type": "integer", "minimum": 0, "maximum": 10000},
    "missing_fields": {"type": "array", "items": {"type": "string"}, "maxItems": 8},
    "source_text": {"type": "string", "maxLength": MAX_TEXT_LENGTH},
}


ACCOUNT_PROPERTIES: dict[str, Any] = {
    "name": {"type": "string", "minLength": 1, "maxLength": 80},
    "kind": {"type": "string", "enum": ["cash", "debit", "credit"], "description": "cash for wallets such as WeChat/Alipay balance, debit for bank cards, credit for credit cards/loans."},
    "opening_balance_minor": {"type": "integer", "description": "Integer fen. Positive debt for credit accounts."},
    "institution": {"type": ["string", "null"], "maxLength": 80},
    "last_four": {"type": ["string", "null"], "pattern": r"^[0-9]{4}$"},
    "credit_limit_minor": {"type": ["integer", "null"], "minimum": 1},
    "statement_day": {"type": ["integer", "null"], "minimum": 1, "maximum": 28},
    "due_day": {"type": ["integer", "null"], "minimum": 1, "maximum": 28},
    "cycle_mode": {"type": ["string", "null"], "enum": ["statement_day_cutoff", "previous_calendar_month", "on_demand", None]},
    "opening_balance_as_of_date": {"type": ["string", "null"], "format": "date"},
    "opening_due_date": {"type": ["string", "null"], "format": "date"},
}
CATEGORY_PROPERTIES: dict[str, Any] = {
    "name": {"type": "string", "minLength": 1, "maxLength": 80},
    "direction": {"type": "string", "enum": ["income", "expense"]},
    "parent_id": {"type": ["string", "null"]},
    "icon": {"type": "string", "maxLength": 80, "default": "tag"},
    "color_hex": {"type": "string", "pattern": r"^#[0-9A-Fa-f]{6}$", "default": "#6B7280"},
    "aliases": {"type": "array", "items": {"type": "string", "maxLength": 80}, "maxItems": 20},
    "examples": {"type": "array", "items": {"type": "string", "maxLength": 80}, "maxItems": 20},
}


CASH_FLOW_CREATE_PROPERTIES: dict[str, Any] = {
    "title": {"type": "string", "minLength": 1, "maxLength": 120},
    "note": {"type": ["string", "null"], "maxLength": 500},
    "direction": {"type": "string", "enum": ["inflow", "outflow", "transfer"]},
    "planned_amount_minor": {"type": "integer", "minimum": 1, "description": "Integer fen."},
    "expected_date": {"type": "string", "format": "date", "description": "Asia/Shanghai business date."},
    "account_id": {"type": ["string", "null"]},
    "destination_account_id": {"type": ["string", "null"], "description": "Transfers only."},
    "category_id": {"type": ["string", "null"], "description": "Not allowed for transfers."},
    "recurrence": {"type": ["string", "null"], "enum": ["monthly", None]},
    "recurrence_end_date": {"type": ["string", "null"], "format": "date"},
    "idempotency_key": {"type": "string", "minLength": 8, "maxLength": 128},
}
CASH_FLOW_SETTLE_PROPERTIES: dict[str, Any] = {
    "item_id": {"type": "string", "minLength": 1},
    "expected_version": {"type": "integer", "minimum": 1},
    "actual_amount_minor": {"type": "integer", "minimum": 1, "description": "Integer fen actually received or paid."},
    "occurred_at": {"type": "string", "format": "date-time"},
    "account_id": {"type": "string", "minLength": 1},
    "destination_account_id": {"type": ["string", "null"]},
    "category_id": {"type": ["string", "null"]},
    "title": {"type": ["string", "null"], "maxLength": 120},
    "note": {"type": ["string", "null"], "maxLength": 500},
    "complete_remaining": {"type": "boolean", "default": True, "description": "False keeps the rest of a partially settled plan open."},
    "idempotency_key": {"type": "string", "minLength": 8, "maxLength": 128},
}
CASH_FLOW_CANCEL_PROPERTIES: dict[str, Any] = {
    "item_id": {"type": "string", "minLength": 1},
    "expected_version": {"type": "integer", "minimum": 1},
    "scope": {"type": "string", "enum": ["occurrence", "this_and_future"], "default": "occurrence"},
}


class Scope(str, Enum):
    READ_REPORTS = "read:reports"
    READ_LEDGER = "read:ledger"
    STAGE_IMPORTS = "stage:imports"
    COMMIT_IMPORTS = "commit:imports"
    EXPORT_REPORTS = "export:reports"


class ImportSource(str, Enum):
    TEXT = "text"
    STRUCTURED = "structured"
    OCR = "ocr"
    SHORTCUT_TEXT = "shortcut_text"


class BatchStatus(str, Enum):
    PENDING = "pending"
    VALIDATED = "validated"
    IGNORED = "ignored"
    COMMITTED = "committed"
    FAILED = "failed"


@dataclass(frozen=True, slots=True)
class ToolDefinition:
    name: str
    description: str
    scope: Scope
    input_schema: dict[str, Any]

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "inputSchema": self.input_schema,
        }


def _object_schema(
    properties: dict[str, Any],
    required: list[str],
    *,
    additional_properties: bool = False,
) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": additional_properties,
    }


def tool_definitions() -> tuple[ToolDefinition, ...]:
    """Return the versioned first-stage tool list in stable display order."""

    return (
        ToolDefinition(
            "fiscal_get_monthly_report",
            "Read the Fiscal monthly report for a YYYY-MM period.",
            Scope.READ_REPORTS,
            _object_schema(
                {"period": {"type": "string", "pattern": r"^\d{4}-(0[1-9]|1[0-2])$"}},
                ["period"],
            ),
        ),
        ToolDefinition(
            "fiscal_get_yearly_report",
            "Read the Fiscal yearly report for a YYYY period.",
            Scope.READ_REPORTS,
            _object_schema(
                {"year": {"type": "string", "pattern": r"^\d{4}$"}},
                ["year"],
            ),
        ),
        ToolDefinition(
            "fiscal_list_accounts",
            "List Fiscal accounts with IDs, kind and cycle mode; fixed-cycle credit accounts include unsettled cycles.",
            Scope.READ_LEDGER,
            _object_schema({"include_archived": {"type": "boolean", "default": False}}, []),
        ),
        ToolDefinition(
            "fiscal_list_categories",
            "List Fiscal categories with IDs, direction, parent and aliases for classifying candidates.",
            Scope.READ_LEDGER,
            _object_schema(
                {
                    "direction": {"type": "string", "enum": ["income", "expense"]},
                    "include_archived": {"type": "boolean", "default": False},
                },
                [],
            ),
        ),
        ToolDefinition(
            "fiscal_create_account",
            "Create a Fiscal account (wallet, bank card or credit account); requires an open write window.",
            Scope.COMMIT_IMPORTS,
            _object_schema(ACCOUNT_PROPERTIES, ["name", "kind", "opening_balance_minor"]),
        ),
        ToolDefinition(
            "fiscal_create_category",
            "Create an income or expense category; aliases/examples improve classification. Requires an open write window.",
            Scope.COMMIT_IMPORTS,
            _object_schema(CATEGORY_PROPERTIES, ["name", "direction"]),
        ),
        ToolDefinition(
            "fiscal_list_cash_flow_items",
            "List planned future cash flows (manual plans, credit-cycle dues, reimbursements). Pass month=YYYY-MM for settled/cancelled history.",
            Scope.READ_LEDGER,
            _object_schema(
                {
                    "account_id": {"type": "string"},
                    "month": {"type": "string", "pattern": r"^\d{4}-(0[1-9]|1[0-2])$"},
                },
                [],
            ),
        ),
        ToolDefinition(
            "fiscal_get_cash_flow_outlook",
            "Read the next N days (default 30) of cash: current cash, expected inflow/outflow, projected balance and known future events.",
            Scope.READ_REPORTS,
            _object_schema({"window_days": {"type": "integer", "minimum": 1, "maximum": 90, "default": 30}}, []),
        ),
        ToolDefinition(
            "fiscal_create_cash_flow_item",
            "Create a planned future inflow/outflow/transfer (optionally monthly until an end date); requires an open write window.",
            Scope.COMMIT_IMPORTS,
            _object_schema(CASH_FLOW_CREATE_PROPERTIES, ["title", "direction", "planned_amount_minor", "expected_date", "idempotency_key"]),
        ),
        ToolDefinition(
            "fiscal_confirm_cash_flow_item",
            "Mark an expected plan as confirmed (it will happen); a plan must be confirmed before it can be settled. Requires an open write window.",
            Scope.COMMIT_IMPORTS,
            _object_schema(CASH_FLOW_CANCEL_PROPERTIES, ["item_id", "expected_version"]),
        ),
        ToolDefinition(
            "fiscal_settle_cash_flow_item",
            "Post a confirmed planned cash flow to the ledger once money actually moved; requires an open write window.",
            Scope.COMMIT_IMPORTS,
            _object_schema(CASH_FLOW_SETTLE_PROPERTIES, ["item_id", "expected_version", "actual_amount_minor", "occurred_at", "account_id", "idempotency_key"]),
        ),
        ToolDefinition(
            "fiscal_cancel_cash_flow_item",
            "Cancel a planned cash flow that will not happen (this occurrence or this and future ones); requires an open write window.",
            Scope.COMMIT_IMPORTS,
            _object_schema(CASH_FLOW_CANCEL_PROPERTIES, ["item_id", "expected_version"]),
        ),
        ToolDefinition(
            "fiscal_search_ledger",
            "Search posted Fiscal ledger transactions with pagination.",
            Scope.READ_LEDGER,
            _object_schema(
                {
                    "date_from": {"type": "string", "format": "date"},
                    "date_to": {"type": "string", "format": "date"},
                    "amount_min_minor": {"type": "integer", "minimum": 1},
                    "amount_max_minor": {"type": "integer", "minimum": 1},
                    "category_id": {"type": "string"},
                    "account_id": {"type": "string"},
                    "query": {"type": "string", "maxLength": 120},
                    "cursor": {"type": ["string", "null"]},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 50},
                },
                [],
            ),
        ),
        ToolDefinition(
            "fiscal_create_import_batch",
            "Stage a batch of candidate entries for confirmation; this never posts to the ledger.",
            Scope.STAGE_IMPORTS,
            _object_schema(
                {
                    "source": {"type": "string", "enum": [value.value for value in ImportSource]},
                    "original_content_sha256": {"type": "string", "pattern": r"^[0-9a-fA-F]{64}$"},
                    "candidates": {
                        "type": "array",
                        "minItems": 1,
                        "maxItems": MAX_CANDIDATES,
                        "items": _object_schema(
                            CANDIDATE_PROPERTIES,
                            ["client_id", "kind", "amount_minor", "occurred_at", "title"],
                        ),
                    },
                    "idempotency_key": {"type": "string", "minLength": 8, "maxLength": 128},
                },
                ["source", "original_content_sha256", "candidates", "idempotency_key"],
            ),
        ),
        ToolDefinition(
            "fiscal_get_import_batch",
            "Read a staged import batch, its candidates, validation and available actions.",
            Scope.STAGE_IMPORTS,
            _object_schema({"batch_id": {"type": "string", "minLength": 1}}, ["batch_id"]),
        ),
        ToolDefinition(
            "fiscal_validate_import_batch",
            "Validate a staged batch against current accounts, categories and duplicate rules.",
            Scope.STAGE_IMPORTS,
            _object_schema(
                {
                    "batch_id": {"type": "string", "minLength": 1},
                    "expected_version": {"type": "integer", "minimum": 1},
                },
                ["batch_id", "expected_version"],
            ),
        ),
        ToolDefinition(
            "fiscal_commit_import_batch",
            "Commit a validated batch after a fresh user-approved write operation.",
            Scope.COMMIT_IMPORTS,
            _object_schema(
                {
                    "batch_id": {"type": "string", "minLength": 1},
                    "expected_version": {"type": "integer", "minimum": 1},
                    "confirmation_token": {"type": "string", "minLength": 16, "maxLength": 512, "description": "Legacy manual credential; TOTP sessions leave this out."},
                    "idempotency_key": {"type": "string", "minLength": 8, "maxLength": 128},
                },
                ["batch_id", "expected_version", "idempotency_key"],
            ),
        ),
        ToolDefinition(
            "fiscal_ignore_import_batch",
            "Ignore a staged batch while retaining its source fingerprint and audit history.",
            Scope.STAGE_IMPORTS,
            _object_schema(
                {
                    "batch_id": {"type": "string", "minLength": 1},
                    "expected_version": {"type": "integer", "minimum": 1},
                    "reason": {"type": "string", "maxLength": 240},
                },
                ["batch_id", "expected_version"],
            ),
        ),
        ToolDefinition(
            "fiscal_export_report",
            "Export a monthly or yearly Fiscal report as CSV and return a short-lived reference.",
            Scope.EXPORT_REPORTS,
            _object_schema(
                {
                    "period_kind": {"type": "string", "enum": ["month", "year"]},
                    "period": {"type": "string"},
                    "format": {"type": "string", "enum": ["csv"]},
                },
                ["period_kind", "period", "format"],
            ),
        ),
    )


def _require_mapping(value: Any, *, field: str = "arguments") -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise invalid_params(f"{field} must be an object", field=field)
    return value


def _required_str(values: Mapping[str, Any], key: str, *, max_length: int = 512) -> str:
    value = values.get(key)
    if not isinstance(value, str) or not value.strip():
        raise invalid_params(f"{key} must be a non-empty string", field=key)
    value = value.strip()
    if len(value) > max_length:
        raise invalid_params(f"{key} exceeds {max_length} characters", field=key)
    return value


def _positive_int(values: Mapping[str, Any], key: str, *, required: bool = False) -> int | None:
    value = values.get(key)
    if value is None and not required:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise invalid_params(f"{key} must be a positive integer", field=key)
    return value


def _optional_date(values: Mapping[str, Any], key: str) -> str | None:
    value = values.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise invalid_params(f"{key} must be an ISO date", field=key)
    try:
        date.fromisoformat(value)
    except ValueError as exc:
        raise invalid_params(f"{key} must be an ISO date", field=key) from exc
    return value


def _validate_candidate(value: Any, index: int) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise invalid_params("each candidate must be an object", field=f"candidates[{index}]")
    candidate = dict(value)
    unknown = sorted(set(candidate) - set(CANDIDATE_PROPERTIES))
    if unknown:
        raise invalid_params(
            f"candidate contains unsupported fields: {', '.join(unknown)}",
            field=f"candidates[{index}]",
        )
    for key in ("client_id", "kind", "occurred_at", "title"):
        _required_str(candidate, key, max_length=120)
    amount = candidate.get("amount_minor")
    if isinstance(amount, bool) or not isinstance(amount, int) or amount <= 0:
        raise invalid_params("amount_minor must be a positive integer", field=f"candidates[{index}].amount_minor")
    if len(candidate["title"]) > 120:
        raise invalid_params("title exceeds 120 characters", field=f"candidates[{index}].title")
    occurred_at = candidate["occurred_at"]
    try:
        parsed_occurred_at = datetime.fromisoformat(occurred_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise invalid_params("occurred_at must be an ISO date-time", field=f"candidates[{index}].occurred_at") from exc
    if parsed_occurred_at.tzinfo is None or parsed_occurred_at.utcoffset() is None:
        raise invalid_params("occurred_at must include a timezone", field=f"candidates[{index}].occurred_at")
    for key in ("account_id", "category_id", "destination_account_id", "credit_cycle_id"):
        if candidate.get(key) is not None:
            _required_str(candidate, key, max_length=120)
    if candidate.get("note") is not None:
        _required_str(candidate, "note", max_length=500)
    confidences = candidate.get("field_confidences")
    if confidences is not None:
        if not isinstance(confidences, Mapping):
            raise invalid_params("field_confidences must be an object", field=f"candidates[{index}].field_confidences")
        for key, confidence in confidences.items():
            if isinstance(confidence, bool) or not isinstance(confidence, int) or not 0 <= confidence <= 10_000:
                raise invalid_params("confidence must be 0..10000", field=f"candidates[{index}].field_confidences.{key}")
    return candidate


def _reject_unknown(values: Mapping[str, Any], allowed: Mapping[str, Any]) -> None:
    unknown = sorted(set(values) - set(allowed))
    if unknown:
        raise invalid_params(f"unsupported fields: {', '.join(unknown)}", field="arguments")


def _optional_int(values: Mapping[str, Any], key: str, *, low: int, high: int | None = None) -> None:
    value = values.get(key)
    if value is None:
        return
    if isinstance(value, bool) or not isinstance(value, int) or value < low or (high is not None and value > high):
        raise invalid_params(f"{key} is out of range", field=key)


def _validate_account(values: Mapping[str, Any]) -> dict[str, Any]:
    """Shape checks only; the backend owns account rules such as credit opening dates."""
    _reject_unknown(values, ACCOUNT_PROPERTIES)
    result = {key: values[key] for key in ACCOUNT_PROPERTIES if values.get(key) is not None}
    result["name"] = _required_str(values, "name", max_length=80)
    if values.get("kind") not in {"cash", "debit", "credit"}:
        raise invalid_params("kind must be cash, debit or credit", field="kind")
    opening = values.get("opening_balance_minor")
    if isinstance(opening, bool) or not isinstance(opening, int):
        raise invalid_params("opening_balance_minor must be an integer amount in fen", field="opening_balance_minor")
    _optional_int(values, "credit_limit_minor", low=1)
    _optional_int(values, "statement_day", low=1, high=28)
    _optional_int(values, "due_day", low=1, high=28)
    for key in ("opening_balance_as_of_date", "opening_due_date"):
        _optional_date(values, key)
    for key in ("institution", "last_four", "cycle_mode"):
        if values.get(key) is not None:
            _required_str(values, key, max_length=80)
    return result


def _validate_category(values: Mapping[str, Any]) -> dict[str, Any]:
    _reject_unknown(values, CATEGORY_PROPERTIES)
    result: dict[str, Any] = {
        "name": _required_str(values, "name", max_length=80),
        "icon": values.get("icon") or "tag",
        "color_hex": values.get("color_hex") or "#6B7280",
        "aliases": values.get("aliases") or [],
        "examples": values.get("examples") or [],
    }
    if values.get("direction") not in {"income", "expense"}:
        raise invalid_params("direction must be income or expense", field="direction")
    result["direction"] = values["direction"]
    if values.get("parent_id") is not None:
        result["parent_id"] = _required_str(values, "parent_id", max_length=120)
    if not isinstance(result["icon"], str) or len(result["icon"]) > 80:
        raise invalid_params("icon must be at most 80 characters", field="icon")
    if not isinstance(result["color_hex"], str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}", result["color_hex"]):
        raise invalid_params("color_hex must look like #RRGGBB", field="color_hex")
    for key in ("aliases", "examples"):
        items = result[key]
        if not isinstance(items, list) or len(items) > 20 or not all(isinstance(item, str) and 0 < len(item.strip()) <= 80 for item in items):
            raise invalid_params(f"{key} must be up to 20 non-empty strings", field=key)
    return result


def _idempotency_key(values: Mapping[str, Any]) -> str:
    key = _required_str(values, "idempotency_key", max_length=128)
    if len(key) < 8:
        raise invalid_params("idempotency_key must be at least 8 characters", field="idempotency_key")
    return key


def _validate_cash_flow_create(values: Mapping[str, Any]) -> dict[str, Any]:
    """Shape checks only; the backend owns transfer/category/recurrence rules."""
    _reject_unknown(values, CASH_FLOW_CREATE_PROPERTIES)
    result = {key: values[key] for key in CASH_FLOW_CREATE_PROPERTIES if values.get(key) is not None}
    result["title"] = _required_str(values, "title", max_length=120)
    if values.get("direction") not in {"inflow", "outflow", "transfer"}:
        raise invalid_params("direction must be inflow, outflow or transfer", field="direction")
    _positive_int(values, "planned_amount_minor", required=True)
    if values.get("expected_date") is None:
        raise invalid_params("expected_date is required", field="expected_date")
    _optional_date(values, "expected_date")
    _optional_date(values, "recurrence_end_date")
    if values.get("recurrence") not in {None, "monthly"}:
        raise invalid_params("recurrence must be monthly", field="recurrence")
    for key in ("account_id", "destination_account_id", "category_id"):
        if values.get(key) is not None:
            _required_str(values, key, max_length=120)
    if values.get("note") is not None:
        _required_str(values, "note", max_length=500)
    result["idempotency_key"] = _idempotency_key(values)
    return result


def _validate_cash_flow_settle(values: Mapping[str, Any]) -> dict[str, Any]:
    _reject_unknown(values, CASH_FLOW_SETTLE_PROPERTIES)
    result = {key: values[key] for key in CASH_FLOW_SETTLE_PROPERTIES if values.get(key) is not None}
    result["item_id"] = _required_str(values, "item_id", max_length=120)
    _positive_int(values, "expected_version", required=True)
    _positive_int(values, "actual_amount_minor", required=True)
    result["account_id"] = _required_str(values, "account_id", max_length=120)
    occurred_at = _required_str(values, "occurred_at", max_length=64)
    try:
        parsed = datetime.fromisoformat(occurred_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise invalid_params("occurred_at must be an ISO date-time", field="occurred_at") from exc
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise invalid_params("occurred_at must include a timezone", field="occurred_at")
    if "complete_remaining" in values and not isinstance(values["complete_remaining"], bool):
        raise invalid_params("complete_remaining must be a boolean", field="complete_remaining")
    for key in ("destination_account_id", "category_id", "title", "note"):
        if values.get(key) is not None:
            _required_str(values, key, max_length=500 if key == "note" else 120)
    result["idempotency_key"] = _idempotency_key(values)
    return result


def validate_tool_arguments(name: str, arguments: Any) -> dict[str, Any]:
    """Validate and normalise arguments for one public tool."""

    values = _require_mapping(arguments)
    if name == "fiscal_get_monthly_report":
        period = _required_str(values, "period", max_length=7)
        if not PERIOD_RE.fullmatch(period):
            raise invalid_params("period must use YYYY-MM", field="period")
        return {"period": period}
    if name == "fiscal_get_yearly_report":
        year = _required_str(values, "year", max_length=4)
        if not YEAR_RE.fullmatch(year):
            raise invalid_params("year must use YYYY", field="year")
        return {"year": year}
    if name in {"fiscal_list_accounts", "fiscal_list_categories"}:
        include_archived = values.get("include_archived", False)
        if not isinstance(include_archived, bool):
            raise invalid_params("include_archived must be a boolean", field="include_archived")
        listing: dict[str, Any] = {"include_archived": include_archived}
        if name == "fiscal_list_categories" and values.get("direction") is not None:
            direction = values["direction"]
            if direction not in {"income", "expense"}:
                raise invalid_params("direction must be income or expense", field="direction")
            listing["direction"] = direction
        return listing
    if name == "fiscal_list_cash_flow_items":
        listing: dict[str, Any] = {}
        if values.get("account_id") is not None:
            listing["account_id"] = _required_str(values, "account_id", max_length=120)
        if values.get("month") is not None:
            month = _required_str(values, "month", max_length=7)
            if not PERIOD_RE.fullmatch(month):
                raise invalid_params("month must use YYYY-MM", field="month")
            listing["month"] = month
        return listing
    if name == "fiscal_get_cash_flow_outlook":
        window = values.get("window_days", 30)
        if isinstance(window, bool) or not isinstance(window, int) or not 1 <= window <= 90:
            raise invalid_params("window_days must be between 1 and 90", field="window_days")
        return {"window_days": window}
    if name == "fiscal_create_cash_flow_item":
        return _validate_cash_flow_create(values)
    if name == "fiscal_settle_cash_flow_item":
        return _validate_cash_flow_settle(values)
    if name in {"fiscal_confirm_cash_flow_item", "fiscal_cancel_cash_flow_item"}:
        _reject_unknown(values, CASH_FLOW_CANCEL_PROPERTIES)
        scope = values.get("scope", "occurrence")
        if scope not in {"occurrence", "this_and_future"}:
            raise invalid_params("scope must be occurrence or this_and_future", field="scope")
        expected = _positive_int(values, "expected_version", required=True)
        return {"item_id": _required_str(values, "item_id", max_length=120), "expected_version": expected, "scope": scope}
    if name == "fiscal_create_account":
        return _validate_account(values)
    if name == "fiscal_create_category":
        return _validate_category(values)
    if name == "fiscal_search_ledger":
        result: dict[str, Any] = {}
        for key in ("date_from", "date_to"):
            if (value := _optional_date(values, key)) is not None:
                result[key] = value
        for key in ("amount_min_minor", "amount_max_minor"):
            value = _positive_int(values, key)
            if value is not None:
                result[key] = value
        for key in ("category_id", "account_id", "query", "cursor"):
            value = values.get(key)
            if value is not None:
                if not isinstance(value, str):
                    raise invalid_params(f"{key} must be a string", field=key)
                if key == "query" and len(value) > 120:
                    raise invalid_params("query exceeds 120 characters", field=key)
                result[key] = value
        limit = values.get("limit", 50)
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
            raise invalid_params("limit must be between 1 and 100", field="limit")
        result["limit"] = limit
        return result
    if name == "fiscal_create_import_batch":
        source = _required_str(values, "source", max_length=32)
        if source not in {member.value for member in ImportSource}:
            raise invalid_params("source is unsupported", field="source")
        fingerprint = _required_str(values, "original_content_sha256", max_length=64)
        if not SHA256_RE.fullmatch(fingerprint):
            raise invalid_params("original_content_sha256 must be a SHA-256 hex digest", field="original_content_sha256")
        candidates = values.get("candidates")
        if not isinstance(candidates, list) or not candidates or len(candidates) > MAX_CANDIDATES:
            raise invalid_params(f"candidates must contain 1..{MAX_CANDIDATES} entries", field="candidates")
        idempotency_key = _required_str(values, "idempotency_key", max_length=128)
        if len(idempotency_key) < 8:
            raise invalid_params("idempotency_key must be at least 8 characters", field="idempotency_key")
        return {
            "source": source,
            "original_content_sha256": fingerprint.lower(),
            "candidates": [_validate_candidate(item, index) for index, item in enumerate(candidates)],
            "idempotency_key": idempotency_key,
        }
    if name in {"fiscal_get_import_batch", "fiscal_validate_import_batch", "fiscal_commit_import_batch", "fiscal_ignore_import_batch"}:
        batch_id = _required_str(values, "batch_id", max_length=120)
        result = {"batch_id": batch_id}
        if name != "fiscal_get_import_batch":
            expected = _positive_int(values, "expected_version", required=True)
            assert expected is not None
            result["expected_version"] = expected
        if name == "fiscal_commit_import_batch":
            token = values.get("confirmation_token")
            if token is not None:
                if not isinstance(token, str) or len(token.strip()) < 16 or len(token) > 512:
                    raise invalid_params("confirmation_token must be at least 16 characters", field="confirmation_token")
                token = token.strip()
            key = _required_str(values, "idempotency_key", max_length=128)
            if len(key) < 8:
                raise invalid_params("idempotency_key must be at least 8 characters", field="idempotency_key")
            result["idempotency_key"] = key
            if token is not None:
                result["confirmation_token"] = token
        if name == "fiscal_ignore_import_batch" and values.get("reason") is not None:
            reason = values["reason"]
            if not isinstance(reason, str) or len(reason) > 240:
                raise invalid_params("reason must be at most 240 characters", field="reason")
            result["reason"] = reason.strip()
        return result
    if name == "fiscal_export_report":
        period_kind = _required_str(values, "period_kind", max_length=5)
        if period_kind not in {"month", "year"}:
            raise invalid_params("period_kind must be month or year", field="period_kind")
        period = _required_str(values, "period", max_length=7)
        if period_kind == "month" and not PERIOD_RE.fullmatch(period):
            raise invalid_params("period must use YYYY-MM for a month export", field="period")
        if period_kind == "year" and not YEAR_RE.fullmatch(period):
            raise invalid_params("period must use YYYY for a year export", field="period")
        fmt = _required_str(values, "format", max_length=3)
        if fmt != "csv":
            raise invalid_params("only csv export is supported in phase one", field="format")
        return {"period_kind": period_kind, "period": period, "format": fmt}
    raise FiscalMCPError("unknown_tool", f"Unknown Fiscal MCP tool {name!r}.")


def content_fingerprint(content: str) -> str:
    """Hash text before it can enter an audit record or request log."""

    return hashlib.sha256(content.encode("utf-8")).hexdigest()

