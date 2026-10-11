"""Application service that binds public MCP tools to a backend adapter."""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Mapping

from .adapter import FiscalBackendAdapter
from .auth import ApiKeyRecord, ApiKeyRegistry, TotpSessionRegistry, request_digest
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
        operation_token: str | None = None,
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
            if name == "fiscal_commit_import_batch":
                if session_based:
                    assert self.sessions is not None
                    self.sessions.consume_operation(
                        operation_token,
                        session_token,
                        request_digest(name, arguments if isinstance(arguments, Mapping) else {}),
                    )
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

