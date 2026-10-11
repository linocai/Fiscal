from __future__ import annotations

import json
import unittest
from typing import Any

from fiscal_mcp.auth import ApiKeyRegistry
from fiscal_mcp.confirmation import NoopConfirmationVerifier
from fiscal_mcp.contracts import Scope
from fiscal_mcp.http_server import MCPHTTPApplication
from fiscal_mcp.server import MCPServer
from fiscal_mcp.service import FiscalMCPService
from fiscal_mcp.adapter import MockFiscalBackendAdapter


KEY = "agent-key-0123456789-abcdef"


def build_app() -> MCPHTTPApplication:
    registry = ApiKeyRegistry()
    registry.register(KEY, list(Scope), label="test")
    service = FiscalMCPService(MockFiscalBackendAdapter(), registry, NoopConfirmationVerifier())
    return MCPHTTPApplication(MCPServer(service), allowed_origins=("https://console.invalid",))


async def request(
    app: MCPHTTPApplication,
    method: str,
    path: str,
    payload: Any = None,
    *,
    authorization: str | None = None,
    origin: str | None = None,
) -> tuple[int, dict[str, str], bytes]:
    body = b"" if payload is None else json.dumps(payload).encode("utf-8")
    headers: list[tuple[bytes, bytes]] = [(b"content-length", str(len(body)).encode("ascii"))]
    if authorization is not None:
        headers.append((b"authorization", authorization.encode("latin-1")))
    if origin is not None:
        headers.append((b"origin", origin.encode("latin-1")))
    messages = [{"type": "http.request", "body": body, "more_body": False}]
    sent: list[dict[str, Any]] = []

    async def receive() -> dict[str, Any]:
        return messages.pop(0) if messages else {"type": "http.disconnect"}

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    await app(
        {
            "type": "http",
            "method": method,
            "path": path,
            "headers": headers,
        },
        receive,
        send,
    )
    start = next(message for message in sent if message["type"] == "http.response.start")
    body_message = next(message for message in sent if message["type"] == "http.response.body")
    response_headers = {key.decode("latin-1"): value.decode("latin-1") for key, value in start["headers"]}
    return start["status"], response_headers, body_message.get("body", b"")


class MCPHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def test_health_is_public_and_mcp_requires_bearer(self) -> None:
        app = build_app()
        health_status, _, health_body = await request(app, "GET", "/health")
        self.assertEqual(health_status, 200)
        self.assertEqual(json.loads(health_body)["status"], "ok")

        status, headers, body = await request(
            app,
            "POST",
            "/mcp",
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        )
        self.assertEqual(status, 401)
        self.assertIn("Bearer", headers["www-authenticate"])
        self.assertEqual(json.loads(body)["error"], "unauthorized")

    async def test_initialize_and_tools_call_forward_bearer_key(self) -> None:
        app = build_app()
        initialize = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
        status, headers, body = await request(app, "POST", "/mcp", initialize, authorization=f"Bearer {KEY}")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["result"]["serverInfo"]["name"], "fiscal-ledger-mcp")
        self.assertIn("mcp-session-id", headers)
        self.assertEqual(headers["mcp-protocol-version"], "2024-11-05")

        tool_call = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "fiscal_get_monthly_report", "arguments": {"period": "2026-10"}},
        }
        status, _, body = await request(app, "POST", "/mcp", tool_call, authorization=f"Bearer {KEY}", origin="https://console.invalid")
        self.assertEqual(status, 200)
        response = json.loads(body)
        self.assertEqual(response["result"]["structuredContent"]["meta"]["period"], "2026-10")

    async def test_unknown_path_and_oversized_body_are_bounded(self) -> None:
        app = build_app()
        status, _, _ = await request(app, "POST", "/wrong", {}, authorization=f"Bearer {KEY}")
        self.assertEqual(status, 404)
        status, _, _ = await request(app, "POST", "/mcp", "x" * (1_048_576 + 1), authorization=f"Bearer {KEY}")
        self.assertEqual(status, 413)

    async def test_notifications_return_accepted_without_body(self) -> None:
        app = build_app()
        notification = {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
        status, headers, body = await request(app, "POST", "/mcp", notification, authorization=f"Bearer {KEY}")
        self.assertEqual(status, 202)
        self.assertEqual(body, b"")
        self.assertEqual(headers["content-length"], "0")


if __name__ == "__main__":
    unittest.main()
