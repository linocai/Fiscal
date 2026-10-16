from __future__ import annotations

import json
import base64
import hashlib
import hmac
import unittest
from datetime import datetime, timezone
from typing import Any

from fiscal_mcp.auth import ApiKeyRegistry, TotpSessionRegistry, request_digest
from fiscal_mcp.confirmation import HMACConfirmationVerifier, NoopConfirmationVerifier
from fiscal_mcp.contracts import Scope
from fiscal_mcp.http_server import MCPHTTPApplication
from fiscal_mcp.server import MCPServer
from fiscal_mcp.service import FiscalMCPService
from fiscal_mcp.adapter import MockFiscalBackendAdapter


KEY = "agent-key-0123456789-abcdef"
TOTP_SECRET = "JBSWY3DPEHPK3PXP"


def current_totp() -> str:
    counter = int(datetime.now(timezone.utc).timestamp()) // 30
    digest = hmac.new(base64.b32decode(TOTP_SECRET), counter.to_bytes(8, "big"), hashlib.sha1).digest()
    number = (int.from_bytes(digest[digest[-1] & 0x0F :][:4], "big") & 0x7FFFFFFF) % 1_000_000
    return f"{number:06d}"


def build_app() -> MCPHTTPApplication:
    registry = ApiKeyRegistry()
    registry.register(KEY, list(Scope), label="test")
    sessions = TotpSessionRegistry(TOTP_SECRET, default_scopes=(scope for scope in Scope if scope is not Scope.COMMIT_IMPORTS))
    service = FiscalMCPService(MockFiscalBackendAdapter(), registry, HMACConfirmationVerifier("test-confirmation-secret"), sessions=sessions)
    return MCPHTTPApplication(MCPServer(service, sessions=sessions), allowed_origins=("https://console.invalid",))


async def request(
    app: MCPHTTPApplication,
    method: str,
    path: str,
    payload: Any = None,
    *,
    authorization: str | None = None,
    origin: str | None = None,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    body = b"" if payload is None else json.dumps(payload).encode("utf-8")
    headers: list[tuple[bytes, bytes]] = [(b"content-length", str(len(body)).encode("ascii"))]
    if authorization is not None:
        headers.append((b"authorization", authorization.encode("latin-1")))
    if origin is not None:
        headers.append((b"origin", origin.encode("latin-1")))
    for key, value in (extra_headers or {}).items():
        headers.append((key.lower().encode("latin-1"), value.encode("latin-1")))
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

    async def test_every_mcp_method_rejects_unknown_or_expired_credentials(self) -> None:
        app = build_app()
        for method in ("initialize", "tools/list", "ping"):
            message = {"jsonrpc": "2.0", "id": 1, "method": method, "params": {}}
            for authorization, code in (
                ("Session fiscal_session_v1_stale", "session_expired"),
                ("Bearer not-a-registered-key-000", "unauthorized"),
            ):
                status, headers, body = await request(app, "POST", "/mcp", message, authorization=authorization)
                self.assertEqual(status, 401, (method, authorization))
                self.assertIn("Session", headers["www-authenticate"])
                self.assertEqual(json.loads(body)["error"]["code"], code)

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

    async def test_totp_session_challenge_and_agent_call(self) -> None:
        app = build_app()
        status, _, body = await request(
            app,
            "POST",
            "/auth/challenges",
            {"kind": "session", "client_label": "test-agent", "scopes": ["read:reports"]},
            origin="https://console.invalid",
        )
        self.assertEqual(status, 201)
        challenge = json.loads(body)
        self.assertIn("/agent/approve/?challenge=", challenge["approval_url"])
        status, _, _ = await request(
            app,
            "POST",
            f"/auth/challenges/{challenge['challenge_id']}/approve",
            {"totp": current_totp()},
            origin="https://console.invalid",
        )
        self.assertEqual(status, 200)
        status, _, body = await request(
            app,
            "GET",
            f"/auth/challenges/{challenge['challenge_id']}",
            extra_headers={"X-Fiscal-Poll-Token": challenge["poll_token"]},
        )
        self.assertEqual(status, 200)
        session_token = json.loads(body)["session_token"]
        status, _, body = await request(
            app,
            "POST",
            "/mcp",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "fiscal_get_monthly_report", "arguments": {"period": "2026-10"}}},
            authorization=f"Session {session_token}",
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["result"]["structuredContent"]["meta"]["period"], "2026-10")

    async def test_operation_challenge_is_required_for_commit(self) -> None:
        app = build_app()
        status, _, body = await request(app, "POST", "/auth/challenges", {"kind": "session"})
        session_challenge = json.loads(body)
        await request(app, "POST", f"/auth/challenges/{session_challenge['challenge_id']}/approve", {"totp": current_totp()})
        _, _, body = await request(app, "GET", f"/auth/challenges/{session_challenge['challenge_id']}", extra_headers={"X-Fiscal-Poll-Token": session_challenge["poll_token"]})
        session_token = json.loads(body)["session_token"]
        args = {"batch_id": "batch-missing", "expected_version": 1, "idempotency_key": "commit-1234"}
        digest = request_digest("fiscal_commit_import_batch", args)
        status, _, body = await request(
            app,
            "POST",
            "/auth/challenges",
            {"kind": "operation", "scope": "commit:imports", "request_digest": digest, "intent": "commit reviewed batch"},
            authorization=f"Session {session_token}",
        )
        self.assertEqual(status, 201)
        operation_challenge = json.loads(body)
        await request(app, "POST", f"/auth/challenges/{operation_challenge['challenge_id']}/approve", {"totp": current_totp()})
        _, _, body = await request(app, "GET", f"/auth/challenges/{operation_challenge['challenge_id']}", extra_headers={"X-Fiscal-Poll-Token": operation_challenge["poll_token"]})
        operation_token = json.loads(body)["operation_token"]
        status, _, body = await request(app, "POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "fiscal_commit_import_batch", "arguments": args, "_meta": {"fiscal_operation_token": operation_token}}}, authorization=f"Session {session_token}")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["result"]["structuredContent"]["error"]["code"], "batch_not_found")

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
