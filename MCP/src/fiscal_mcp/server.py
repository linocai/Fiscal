"""Minimal stdio MCP transport for Fiscal tools.

The implementation uses only JSON-RPC messages and keeps the Fiscal tool
contract in :mod:`fiscal_mcp.contracts`; no backend or database code is
imported.  It is suitable for local Agent clients today and can sit behind an
HTTP MCP transport later without changing the service layer. Remote clients
normally use the TOTP session boundary; legacy bearer keys remain available
only for controlled break-glass or compatibility use.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, TextIO

from .adapter import HttpFiscalBackendAdapter, MockFiscalBackendAdapter
from .auth import ApiKeyRegistry, TotpSessionRegistry
from .confirmation import HMACConfirmationVerifier
from .errors import FiscalMCPError
from .service import FiscalMCPService

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "fiscal-ledger-mcp"
SERVER_VERSION = "0.1.0"


class MCPServer:
    def __init__(
        self,
        service: FiscalMCPService,
        *,
        static_api_key: str | None = None,
        sessions: TotpSessionRegistry | None = None,
    ) -> None:
        self.service = service
        self.static_api_key = static_api_key
        self.sessions = sessions or service.sessions

    async def handle_message(self, message: Any) -> dict[str, Any] | None:
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            return self._error(message.get("id") if isinstance(message, dict) else None, -32600, "Invalid JSON-RPC request.")
        method = message.get("method")
        request_id = message.get("id")
        if not isinstance(method, str):
            return self._error(request_id, -32600, "JSON-RPC method is required.")
        if request_id is None and method.startswith("notifications/"):
            return None
        params = message.get("params")
        if params is None:
            params = {}
        if not isinstance(params, dict):
            return self._error(request_id, -32602, "Method params must be an object.")
        if method == "initialize":
            return self._success(
                request_id,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                },
            )
        if method == "ping":
            return self._success(request_id, {})
        if method == "tools/list":
            return self._success(request_id, {"tools": self.service.list_tools()})
        if method == "tools/call":
            return await self._call_tool(request_id, params)
        return self._error(request_id, -32601, "Method not found.")

    async def _call_tool(self, request_id: Any, params: dict[str, Any]) -> dict[str, Any]:
        name = params.get("name")
        arguments = params.get("arguments", {})
        if not isinstance(name, str):
            return self._error(request_id, -32602, "tools/call requires a tool name.")
        meta = params.get("_meta")
        presented_key = self.static_api_key
        session_token = None
        operation_token = None
        if isinstance(meta, dict) and isinstance(meta.get("fiscal_api_key"), str):
            presented_key = meta["fiscal_api_key"]
        if isinstance(meta, dict) and isinstance(meta.get("fiscal_session_token"), str):
            session_token = meta["fiscal_session_token"]
        if isinstance(meta, dict) and isinstance(meta.get("fiscal_operation_token"), str):
            operation_token = meta["fiscal_operation_token"]
        try:
            result = await self.service.invoke(
                name,
                arguments,
                api_key=presented_key,
                session_token=session_token,
                operation_token=operation_token,
            )
            return self._success(request_id, self._tool_result(result))
        except FiscalMCPError as error:
            return self._success(request_id, self._tool_error(error))

    @staticmethod
    def _tool_result(value: dict[str, Any]) -> dict[str, Any]:
        text = json.dumps(value, ensure_ascii=False, separators=(",", ":"), default=str)
        return {"content": [{"type": "text", "text": text}], "structuredContent": value}

    @staticmethod
    def _tool_error(error: FiscalMCPError) -> dict[str, Any]:
        payload = {"error": error.as_dict()}
        text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), default=str)
        return {"content": [{"type": "text", "text": text}], "structuredContent": payload, "isError": True}

    @staticmethod
    def _success(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    @staticmethod
    def _error(request_id: Any, code: int, message: str) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def build_default_server() -> MCPServer:
    registry, static_key = ApiKeyRegistry.from_environment()
    if os.environ.get("FISCAL_MCP_USE_MOCK", "").lower() in {"1", "true", "yes"}:
        adapter = MockFiscalBackendAdapter()
    else:
        adapter = HttpFiscalBackendAdapter(
            os.environ.get("FISCAL_BACKEND_URL", "http://127.0.0.1:8000"),
            backend_token=os.environ.get("FISCAL_BACKEND_TOKEN"),
            batch_path=os.environ.get("FISCAL_BATCH_API_PATH"),
        )
    secret = os.environ.get("FISCAL_MCP_CONFIRMATION_SECRET")
    session_scopes = [
        value.strip()
        for value in os.environ.get(
            "FISCAL_MCP_SESSION_SCOPES",
            "read:reports,read:ledger,stage:imports,export:reports",
        ).split(",")
        if value.strip()
    ]
    sessions = TotpSessionRegistry(
        os.environ.get("FISCAL_MCP_TOTP_SECRET"),
        default_scopes=session_scopes,
        idle_seconds=int(os.environ.get("FISCAL_MCP_SESSION_IDLE_SECONDS", "7200")),
        absolute_seconds=int(os.environ.get("FISCAL_MCP_SESSION_MAX_SECONDS", "28800")),
        operation_seconds=int(os.environ.get("FISCAL_MCP_OPERATION_SECONDS", "1800")),
        challenge_seconds=int(os.environ.get("FISCAL_MCP_CHALLENGE_SECONDS", "600")),
    )
    service = FiscalMCPService(
        adapter=adapter,
        key_registry=registry,
        confirmation_verifier=HMACConfirmationVerifier(secret),
        sessions=sessions,
    )
    return MCPServer(service, static_api_key=static_key, sessions=sessions)


async def run_stdio(server: MCPServer, *, stdin: TextIO | None = None, stdout: TextIO | None = None) -> None:
    """Run newline-delimited JSON-RPC over stdio."""

    input_stream: TextIO = stdin if stdin is not None else sys.stdin
    output_stream: TextIO = stdout if stdout is not None else sys.stdout
    for line in input_stream:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
            response = await server.handle_message(message)
        except json.JSONDecodeError:
            response = MCPServer._error(None, -32700, "Invalid JSON.")
        if response is not None:
            output_stream.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
            output_stream.flush()

