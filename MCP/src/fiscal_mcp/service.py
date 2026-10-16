"""Application service that binds public MCP tools to a backend adapter."""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Mapping

from .adapter import FiscalBackendAdapter, backend_idempotency_uuid
from .auth import ApiKeyRecord, ApiKeyRegistry, TotpSessionRegistry
from .confirmation import ConfirmationVerifier
from .contracts import Scope, ToolDefinition, tool_definitions, validate_tool_arguments
from .errors import FiscalMCPError


@dataclass(slots=True)
class AuditEvent:
    action: str
    tool: str
    key_fingerprint: str | None
    outcome: str
    at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    details: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "action": self.action,
            "tool": self.tool,
            "key_fingerprint": self.key_fingerprint,
            "outcome": self.outcome,
            "at": self.at.isoformat(),
            "details": copy.deepcopy(self.details),
        }


class AuditLog:
    """Bounded in-memory audit sink for the independent MCP process.

    Production deployment can replace this sink with the existing backend's
    audit service once the corresponding endpoint is available.
    """

    def __init__(self, *, max_events: int = 2_000) -> None:
        self.max_events = max_events
        self.events: list[AuditEvent] = []

    def append(self, event: AuditEvent) -> None:
        self.events.append(event)
        if len(self.events) > self.max_events:
            del self.events[: len(self.events) - self.max_events]


@dataclass(slots=True)
class FiscalMCPService:
    adapter: FiscalBackendAdapter
    key_registry: ApiKeyRegistry
    confirmation_verifier: ConfirmationVerifier
    sessions: TotpSessionRegistry | None = None
    audit: AuditLog = field(default_factory=AuditLog)
    definitions: tuple[ToolDefinition, ...] = field(default_factory=tool_definitions)

    def definition(self, name: str) -> ToolDefinition:
        for definition in self.definitions:
            if definition.name == name:
                return definition
        raise FiscalMCPError("unknown_tool", f"Unknown Fiscal MCP tool {name!r}.")

    def list_tools(self) -> list[dict[str, Any]]:
        return [definition.as_dict() for definition in self.definitions]

    def _record(
        self,
        *,
        action: str,
        tool: str,
        principal: ApiKeyRecord | None,
        outcome: str,
        details: Mapping[str, Any] | None = None,
    ) -> None:
        self.audit.append(
            AuditEvent(
                action=action,
                tool=tool,
                key_fingerprint=principal.fingerprint if principal else None,
                outcome=outcome,
                details=dict(details or {}),
            )
        )

    async def invoke(
        self,
        name: str,
        arguments: Any,
        *,
        api_key: str | None,
        session_token: str | None = None,
    ) -> dict[str, Any]:
        definition = self.definition(name)
        principal: ApiKeyRecord | None = None
        try:
            session_based = session_token is not None
            if session_based:
                if self.sessions is None:
                    raise FiscalMCPError("unauthorized", "Authenticator sessions are not configured.")
                required_scope = None if definition.scope is Scope.COMMIT_IMPORTS else definition.scope
                session = self.sessions.resolve(session_token, required_scope=required_scope)
                principal = ApiKeyRecord(
                    session.token_fingerprint,
                    session.scopes,
                    label=session.label,
                    expires_at=session.absolute_expires_at,
                    created_at=session.issued_at,
                )
            else:
                principal = self.key_registry.require(api_key, definition.scope)
            values = validate_tool_arguments(name, arguments)
            if session_based and definition.scope is Scope.COMMIT_IMPORTS:
                assert self.sessions is not None
                self.sessions.require_write_window(session_token)
            if name == "fiscal_commit_import_batch":
                if session_based:
                    values = dict(values)
                    values["confirmation_token"] = self.confirmation_verifier.mint(
                        batch_id=values["batch_id"], expected_version=values["expected_version"]
                    )
                elif "confirmation_token" not in values:
                    if principal is not None and principal.label == "owner-break-glass":
                        values = dict(values)
                        values["confirmation_token"] = self.confirmation_verifier.mint(
                            batch_id=values["batch_id"], expected_version=values["expected_version"]
                        )
                    else:
                        raise FiscalMCPError("confirmation_required", "A confirmation credential is required for this commit.")
            result = await self._invoke_adapter(name, values)
            details: dict[str, Any] = {}
            if name == "fiscal_create_import_batch":
                details = {"batch_id": result.get("batch_id"), "candidate_count": len(values["candidates"])}
            elif name in {"fiscal_create_account", "fiscal_create_category"}:
                details = {"created_id": result.get("id")}
            elif name in {"fiscal_confirm_cash_flow_item", "fiscal_settle_cash_flow_item", "fiscal_cancel_cash_flow_item"}:
                details = {"item_id": values["item_id"]}
            elif "batch_id" in values:
                details = {"batch_id": values["batch_id"]}
            self._record(action=name, tool=name, principal=principal, outcome="success", details=details)
            return result
        except FiscalMCPError as error:
            details = {"error_code": error.code}
            if "batch_id" in (arguments if isinstance(arguments, Mapping) else {}):
                details["batch_id"] = arguments["batch_id"]
            self._record(action=name, tool=name, principal=principal, outcome="error", details=details)
            raise
        except Exception as error:  # Adapter exceptions must not leak internals.
            self._record(action=name, tool=name, principal=principal, outcome="error", details={"error_code": "backend_error"})
            raise FiscalMCPError("backend_error", "Fiscal backend request failed.") from error

    async def _invoke_adapter(self, name: str, values: Mapping[str, Any]) -> dict[str, Any]:
        if name == "fiscal_get_monthly_report":
            return await self.adapter.get_monthly_report(values["period"])
        if name == "fiscal_get_yearly_report":
            return await self.adapter.get_yearly_report(values["year"])
        if name == "fiscal_list_accounts":
            return await self._list_accounts(values["include_archived"])
        if name == "fiscal_list_categories":
            return await self._list_categories(values.get("direction"), values["include_archived"])
        if name == "fiscal_list_cash_flow_items":
            return await self.adapter.list_cash_flow_items(values.get("account_id"), values.get("month"))
        if name == "fiscal_get_cash_flow_outlook":
            return await self.adapter.get_cash_flow_outlook(values["window_days"])
        if name == "fiscal_create_cash_flow_item":
            payload = {key: value for key, value in values.items() if key != "idempotency_key"}
            key = backend_idempotency_uuid(name, values["idempotency_key"])
            return await self.adapter.create_cash_flow_item(payload, key)
        if name == "fiscal_settle_cash_flow_item":
            payload = {key: value for key, value in values.items() if key not in {"idempotency_key", "item_id"}}
            key = backend_idempotency_uuid(name, values["idempotency_key"])
            return await self.adapter.settle_cash_flow_item(values["item_id"], payload, key)
        if name == "fiscal_confirm_cash_flow_item":
            return await self.adapter.confirm_cash_flow_item(values["item_id"], values["expected_version"], values["scope"])
        if name == "fiscal_cancel_cash_flow_item":
            return await self.adapter.cancel_cash_flow_item(values["item_id"], values["expected_version"], values["scope"])
        if name == "fiscal_create_account":
            account = await self.adapter.create_account(values)
            return {key: account.get(key) for key in ACCOUNT_FIELDS}
        if name == "fiscal_create_category":
            category = await self.adapter.create_category(values)
            return {key: category.get(key) for key in CATEGORY_FIELDS}
        if name == "fiscal_search_ledger":
            return await self.adapter.search_ledger(values)
        if name == "fiscal_create_import_batch":
            return await self.adapter.create_import_batch(values)
        if name == "fiscal_get_import_batch":
            return await self.adapter.get_import_batch(values["batch_id"])
        if name == "fiscal_validate_import_batch":
            return await self.adapter.validate_import_batch(values["batch_id"], values["expected_version"])
        if name == "fiscal_commit_import_batch":
            self.confirmation_verifier.verify(
                values["confirmation_token"],
                batch_id=values["batch_id"],
                expected_version=values["expected_version"],
            )
            return await self.adapter.commit_import_batch(
                values["batch_id"],
                values["expected_version"],
                values["confirmation_token"],
                values["idempotency_key"],
            )
        if name == "fiscal_ignore_import_batch":
            return await self.adapter.ignore_import_batch(
                values["batch_id"], values["expected_version"], values.get("reason")
            )
        if name == "fiscal_export_report":
            return await self.adapter.export_report(values["period_kind"], values["period"], values["format"])
        raise FiscalMCPError("unknown_tool", f"Unknown Fiscal MCP tool {name!r}.")


    async def _list_accounts(self, include_archived: bool) -> dict[str, Any]:
        items: list[dict[str, Any]] = []
        for account in await self.adapter.list_accounts(include_archived):
            item = {key: account.get(key) for key in ACCOUNT_FIELDS}
            if account.get("kind") == "credit" and account.get("cycle_mode") not in (None, "on_demand"):
                item["open_cycles"] = await self._open_cycles(str(account["id"]))
            items.append(item)
        return {"items": items}

    async def _open_cycles(self, account_id: str) -> list[dict[str, Any]]:
        """Unsettled cycles a repayment can target, oldest due date first."""

        cycles: list[dict[str, Any]] = []
        cursor: str | None = None
        for _ in range(MAX_CYCLE_PAGES):
            page = await self.adapter.list_credit_cycles(account_id, cursor)
            for cycle in page.get("items") or []:
                if isinstance(cycle, Mapping) and cycle.get("status") != "settled":
                    entry = {key: cycle.get(key) for key in CYCLE_FIELDS}
                    entry["cycle_id"] = str(cycle.get("id"))
                    cycles.append(entry)
            cursor = page.get("next_cursor")
            if not cursor:
                break
        return sorted(cycles, key=lambda entry: str(entry.get("due_date") or ""))

    async def _list_categories(self, direction: str | None, include_archived: bool) -> dict[str, Any]:
        items: list[dict[str, Any]] = []

        def flatten(nodes: Any) -> None:
            for node in nodes or []:
                if isinstance(node, Mapping):
                    items.append({key: node.get(key) for key in CATEGORY_FIELDS})
                    flatten(node.get("children"))

        flatten(await self.adapter.list_categories(direction, include_archived))
        return {"items": items}


ACCOUNT_FIELDS = (
    "id",
    "name",
    "kind",
    "institution",
    "last_four",
    "cycle_mode",
    "statement_day",
    "due_day",
    "opening_balance_as_of_date",
    "current_balance_minor",
    "credit_limit_minor",
    "archived_at",
)
CYCLE_FIELDS = (
    "period_start",
    "period_end",
    "statement_date",
    "due_date",
    "amount_due_minor",
    "repaid_minor",
    "remaining_minor",
    "status",
    "is_overdue",
)
CATEGORY_FIELDS = ("id", "name", "direction", "parent_id", "aliases", "is_balance_adjustment", "archived_at")
MAX_CYCLE_PAGES = 10
