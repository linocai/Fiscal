"""Remote HTTP transport for the Fiscal MCP server.

The tool service remains transport-agnostic. This small ASGI boundary accepts
JSON-RPC over a protected HTTP endpoint so an Agent on another device can use
the same Fiscal MCP contract as a local stdio client. Nginx owns TLS and public
rate limiting; this app only handles the MCP request, bearer authentication,
bounded bodies and optional CORS for the Web console.
"""

from __future__ import annotations

import json
import importlib
import os
import secrets
from collections.abc import Awaitable, Callable, Iterable
from typing import Any

from .server import MCPServer, build_default_server

ASGIMessage = dict[str, Any]
Send = Callable[[ASGIMessage], Awaitable[None]]
Receive = Callable[[], Awaitable[ASGIMessage]]

MAX_BODY_BYTES = 1_048_576
DEFAULT_PATH = "/mcp"
DEFAULT_HEALTH_PATH = "/health"


def _headers(scope: dict[str, Any]) -> dict[str, str]:
    return {
        key.decode("latin-1").lower(): value.decode("latin-1")
        for key, value in scope.get("headers", [])
    }


def _header_bytes(values: Iterable[tuple[str, str]]) -> list[tuple[bytes, bytes]]:
    return [(key.encode("latin-1"), value.encode("latin-1")) for key, value in values]


class MCPHTTPApplication:
    """A stateless JSON-RPC-over-HTTP ASGI application.

    The bearer token is copied into the existing MCP ``params._meta`` boundary
    only for ``tools/call``. It is never written to an audit detail or response.
    Session IDs are echoed for clients that use the Streamable HTTP convention;
    authorization remains the bearer token on every request.
    """

    def __init__(
        self,
        server: MCPServer,
        *,
        path: str = DEFAULT_PATH,
        health_path: str = DEFAULT_HEALTH_PATH,
        allowed_origins: Iterable[str] = (),
        max_body_bytes: int = MAX_BODY_BYTES,
    ) -> None:
        self.server = server
        self.path = "/" + path.strip("/") if path.strip("/") else DEFAULT_PATH
        self.health_path = "/" + health_path.strip("/") if health_path.strip("/") else DEFAULT_HEALTH_PATH
        self.allowed_origins = frozenset(origin.strip() for origin in allowed_origins if origin.strip())
        self.max_body_bytes = max_body_bytes

    async def __call__(self, scope: dict[str, Any], receive: Receive, send: Send) -> None:
        if scope.get("type") != "http":
            return
        request_headers = _headers(scope)
        origin = request_headers.get("origin")
        cors = self._cors_headers(origin)
        method = str(scope.get("method", "")).upper()
        path = str(scope.get("path", ""))

        if path == self.health_path and method == "GET":
            await self._respond(send, 200, {"service": "fiscal-mcp", "status": "ok"}, cors=cors)
            return
        if path != self.path:
            await self._respond(send, 404, {"error": "not_found"}, cors=cors)
            return
        if method == "OPTIONS":
            await self._respond(send, 204, None, cors=cors, allow_options=True)
            return
        if method != "POST":
            await self._respond(send, 405, {"error": "method_not_allowed"}, cors=cors, extra_headers=(("allow", "POST"),))
            return

        token = self._bearer_token(request_headers.get("authorization"))
        if token is None:
            await self._respond(
                send,
                401,
                {"error": "unauthorized", "message": "A Fiscal MCP bearer key is required."},
                cors=cors,
                extra_headers=(("www-authenticate", 'Bearer realm="fiscal-mcp"'),),
            )
            await self._drain(receive)
            return

        try:
            raw_body = await self._read_body(receive, request_headers.get("content-length"))
            payload = json.loads(raw_body)
        except BodyTooLarge:
            await self._respond(send, 413, {"error": "request_too_large"}, cors=cors)
            return
        except (UnicodeDecodeError, json.JSONDecodeError):
            await self._respond(send, 400, MCPServer._error(None, -32700, "Invalid JSON."), cors=cors)
            return

        responses = await self._handle_payload(payload, token)
        if responses is None:
            await self._respond(send, 202, None, cors=cors)
            return
        result: Any = responses[0] if len(responses) == 1 and not isinstance(payload, list) else responses
        session_id = self._session_header(payload, request_headers)
        extra = [("mcp-protocol-version", "2024-11-05")]
        if session_id:
            extra.append(("mcp-session-id", session_id))
        await self._respond(send, 200, result, cors=cors, extra_headers=extra)

    async def _handle_payload(self, payload: Any, token: str) -> list[dict[str, Any]] | None:
        if isinstance(payload, list):
            if not payload:
                return [MCPServer._error(None, -32600, "Invalid JSON-RPC request.")]
            messages = payload
        else:
            messages = [payload]
        responses: list[dict[str, Any]] = []
        for message in messages:
            if not isinstance(message, dict):
                responses.append(MCPServer._error(None, -32600, "Invalid JSON-RPC request."))
                continue
            authenticated = self._with_bearer(message, token)
            response = await self.server.handle_message(authenticated)
            if response is not None:
                responses.append(response)
        return responses or None

    @staticmethod
    def _with_bearer(message: dict[str, Any], token: str) -> dict[str, Any]:
        if message.get("method") != "tools/call":
            return message
        params = message.get("params")
        params = dict(params) if isinstance(params, dict) else {}
        meta = params.get("_meta")
        meta = dict(meta) if isinstance(meta, dict) else {}
        meta["fiscal_api_key"] = token
        params["_meta"] = meta
        return {**message, "params": params}

    @staticmethod
    def _bearer_token(value: str | None) -> str | None:
        if not value:
            return None
        scheme, separator, token = value.partition(" ")
        if not separator or scheme.lower() != "bearer" or not token.strip():
            return None
        return token.strip()

    async def _read_body(self, receive: Receive, content_length: str | None) -> bytes:
        if content_length is not None:
            try:
                if int(content_length) > self.max_body_bytes:
                    raise BodyTooLarge
            except ValueError:
                raise BodyTooLarge from None
        chunks: list[bytes] = []
        size = 0
        while True:
            message = await receive()
            if message.get("type") == "http.disconnect":
                break
            if message.get("type") != "http.request":
                continue
            chunk = message.get("body", b"")
            if not isinstance(chunk, bytes):
                raise BodyTooLarge
            size += len(chunk)
            if size > self.max_body_bytes:
                raise BodyTooLarge
            chunks.append(chunk)
            if not message.get("more_body", False):
                break
        return b"".join(chunks)

    @staticmethod
    async def _drain(receive: Receive) -> None:
        while True:
            message = await receive()
            if message.get("type") != "http.request" or not message.get("more_body", False):
                return

    def _session_header(self, payload: Any, request_headers: dict[str, str]) -> str | None:
        existing = request_headers.get("mcp-session-id")
        if existing:
            return existing[:128]
        messages = payload if isinstance(payload, list) else [payload]
        if any(isinstance(message, dict) and message.get("method") == "initialize" for message in messages):
            return secrets.token_urlsafe(24)
        return None

    def _cors_headers(self, origin: str | None) -> tuple[tuple[str, str], ...]:
        if not origin or origin not in self.allowed_origins:
            return ()
        return (
            ("access-control-allow-origin", origin),
            ("access-control-allow-headers", "Authorization, Content-Type, MCP-Protocol-Version, Mcp-Session-Id"),
            ("access-control-allow-methods", "POST, OPTIONS"),
            ("vary", "Origin"),
        )

    async def _respond(
        self,
        send: Send,
        status: int,
        value: Any,
        *,
        cors: tuple[tuple[str, str], ...],
        allow_options: bool = False,
        extra_headers: Iterable[tuple[str, str]] = (),
    ) -> None:
        body = b"" if value is None else json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        headers = [("content-type", "application/json; charset=utf-8"), ("content-length", str(len(body)))]
        headers.extend(cors)
        headers.extend(extra_headers)
        if allow_options:
            headers.append(("access-control-max-age", "600"))
        await send({"type": "http.response.start", "status": status, "headers": _header_bytes(headers)})
        await send({"type": "http.response.body", "body": body})


class BodyTooLarge(Exception):
    pass


def build_http_app() -> MCPHTTPApplication:
    raw_origins = os.environ.get("FISCAL_MCP_ALLOWED_ORIGINS", "")
    return MCPHTTPApplication(
        build_default_server(),
        path=os.environ.get("FISCAL_MCP_HTTP_PATH", DEFAULT_PATH),
        health_path=os.environ.get("FISCAL_MCP_HEALTH_PATH", DEFAULT_HEALTH_PATH),
        allowed_origins=raw_origins.split(","),
    )


app = build_http_app()


def main() -> None:
    uvicorn: Any = importlib.import_module("uvicorn")

    uvicorn.run(
        "fiscal_mcp.http_server:app",
        host=os.environ.get("FISCAL_MCP_BIND_HOST", "127.0.0.1"),
        port=int(os.environ.get("FISCAL_MCP_BIND_PORT", "8050")),
        proxy_headers=False,
        server_header=False,
        log_level=os.environ.get("FISCAL_MCP_LOG_LEVEL", "info").lower(),
    )


if __name__ == "__main__":
    main()
