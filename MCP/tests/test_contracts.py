from __future__ import annotations

import asyncio
import unittest

from fiscal_mcp.adapter import HttpFiscalBackendAdapter, MockFiscalBackendAdapter
from fiscal_mcp.auth import ApiKeyRegistry
from fiscal_mcp.confirmation import HMACConfirmationVerifier
from fiscal_mcp.contracts import Scope, content_fingerprint
from fiscal_mcp.errors import FiscalMCPError
from fiscal_mcp.server import MCPServer
from fiscal_mcp.service import FiscalMCPService


KEY = "local-test-key-0123456789abcdef"


def run(coro):
    return asyncio.run(coro)


class FiscalMCPContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = ApiKeyRegistry()
        self.registry.register(KEY, list(Scope), label="test")
        self.adapter = MockFiscalBackendAdapter()
        self.verifier = HMACConfirmationVerifier("test-confirmation-secret")
        self.service = FiscalMCPService(self.adapter, self.registry, self.verifier)

    def invoke(self, tool: str, args: dict, key: str = KEY):
        return run(self.service.invoke(tool, args, api_key=key))

    def candidate(self, client_id: str = "row-1") -> dict:
        return {
            "client_id": client_id,
            "kind": "expense",
            "amount_minor": 1234,
            "occurred_at": "2026-10-01T12:00:00+08:00",
            "title": "Coffee",
            "account_id": "account-1",
            "category_id": "category-1",
        }

    def test_tool_contract_is_stable(self) -> None:
        names = [item["name"] for item in self.service.list_tools()]
        self.assertEqual(
            names,
            [
                "fiscal_get_monthly_report",
                "fiscal_get_yearly_report",
                "fiscal_search_ledger",
                "fiscal_create_import_batch",
                "fiscal_get_import_batch",
                "fiscal_validate_import_batch",
                "fiscal_commit_import_batch",
                "fiscal_ignore_import_batch",
                "fiscal_export_report",
            ],
        )
        self.assertIn("required", self.service.list_tools()[0]["inputSchema"])

    def test_read_scope_and_report(self) -> None:
        result = self.invoke("fiscal_get_monthly_report", {"period": "2026-10"})
        self.assertEqual(result["meta"]["data_revision"], 1)
        read_registry = ApiKeyRegistry()
        read_registry.register(KEY, [Scope.STAGE_IMPORTS])
        service = FiscalMCPService(self.adapter, read_registry, self.verifier)
        with self.assertRaises(FiscalMCPError) as caught:
            run(service.invoke("fiscal_get_monthly_report", {"period": "2026-10"}, api_key=KEY))
        self.assertEqual(caught.exception.code, "insufficient_scope")

    def test_batch_idempotency_validation_and_commit_replay(self) -> None:
        source = "2026-10-01 coffee 12.34"
        args = {
            "source": "text",
            "original_content_sha256": content_fingerprint(source),
            "candidates": [self.candidate()],
            "idempotency_key": "import-week-0001",
        }
        first = self.invoke("fiscal_create_import_batch", args)
        replay = self.invoke("fiscal_create_import_batch", args)
        self.assertEqual(first["batch_id"], replay["batch_id"])
        self.assertEqual(first["version"], 1)
        conflicting = {**args, "candidates": [self.candidate("row-2")]}
        with self.assertRaises(FiscalMCPError) as caught:
            self.invoke("fiscal_create_import_batch", conflicting)
        self.assertEqual(caught.exception.code, "idempotency_conflict")
        validated = self.invoke(
            "fiscal_validate_import_batch",
            {"batch_id": first["batch_id"], "expected_version": 1},
        )
        self.assertEqual(validated["status"], "validated")
        token = self.verifier.mint(batch_id=first["batch_id"], expected_version=2)
        commit_args = {
            "batch_id": first["batch_id"],
            "expected_version": 2,
            "confirmation_token": token,
            "idempotency_key": "commit-week-0001",
        }
        committed = self.invoke("fiscal_commit_import_batch", commit_args)
        replayed = self.invoke("fiscal_commit_import_batch", commit_args)
        self.assertEqual(committed, replayed)
        self.assertEqual(len(self.adapter.ledger_items), 1)
        self.assertEqual(committed["data_revision"], 2)

    def test_commit_rejects_bad_confirmation(self) -> None:
        batch = self.invoke(
            "fiscal_create_import_batch",
            {
                "source": "structured",
                "original_content_sha256": "a" * 64,
                "candidates": [self.candidate()],
                "idempotency_key": "import-week-0002",
            },
        )
        self.invoke("fiscal_validate_import_batch", {"batch_id": batch["batch_id"], "expected_version": 1})
        with self.assertRaises(FiscalMCPError) as caught:
            self.invoke(
                "fiscal_commit_import_batch",
                {
                    "batch_id": batch["batch_id"],
                    "expected_version": 2,
                    "confirmation_token": "invalid-confirmation-token",
                    "idempotency_key": "commit-week-0002",
                },
            )
        self.assertEqual(caught.exception.code, "invalid_confirmation")

    def test_owner_break_glass_key_can_commit_without_totp_operation(self) -> None:
        break_glass = "owner-break-glass-key-0123456789"
        self.registry.register(break_glass, list(Scope), label="owner-break-glass")
        batch = self.invoke(
            "fiscal_create_import_batch",
            {
                "source": "structured",
                "original_content_sha256": "c" * 64,
                "candidates": [self.candidate("break-glass-row")],
                "idempotency_key": "import-break-glass",
            },
            key=break_glass,
        )
        self.invoke("fiscal_validate_import_batch", {"batch_id": batch["batch_id"], "expected_version": 1}, key=break_glass)
        committed = self.invoke(
            "fiscal_commit_import_batch",
            {"batch_id": batch["batch_id"], "expected_version": 2, "idempotency_key": "commit-break-glass"},
            key=break_glass,
        )
        self.assertEqual(committed["batch"]["status"], "committed")

    def test_candidate_contract_rejects_unknown_or_naive_datetime(self) -> None:
        base = {
            "source": "text",
            "original_content_sha256": "b" * 64,
            "candidates": [self.candidate()],
            "idempotency_key": "import-week-0003",
        }
        unknown = dict(base)
        unknown["candidates"] = [{**self.candidate(), "unexpected": True}]
        with self.assertRaises(FiscalMCPError) as caught:
            self.invoke("fiscal_create_import_batch", unknown)
        self.assertEqual(caught.exception.code, "invalid_params")
        naive = dict(base)
        naive["candidates"] = [{**self.candidate(), "occurred_at": "2026-10-01T12:00:00"}]
        with self.assertRaises(FiscalMCPError) as caught:
            self.invoke("fiscal_create_import_batch", naive)
        self.assertEqual(caught.exception.code, "invalid_params")

    def test_mcp_stdio_message_shape(self) -> None:
        server = MCPServer(self.service, static_api_key=KEY)
        initialized = run(server.handle_message({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}))
        self.assertEqual(initialized["result"]["serverInfo"]["name"], "fiscal-ledger-mcp")
        result = run(
            server.handle_message(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": {"name": "fiscal_get_yearly_report", "arguments": {"year": "2026"}},
                }
            )
        )
        self.assertEqual(result["result"]["structuredContent"]["meta"]["period"], "2026")


class HttpAdapterTests(unittest.TestCase):
    def test_existing_read_route_and_batch_boundary(self) -> None:
        class Response:
            status_code = 200
            headers = {"content-type": "application/json", "x-fiscal-data-revision": "8"}
            content = b""

            def json(self):
                return {"meta": {"period": "2026-10", "data_revision": 8}}

        class Client:
            async def request(self, method, url, *, headers, params, json):
                self.request_url = url
                return Response()

            async def aclose(self):
                return None

        client = Client()
        adapter = HttpFiscalBackendAdapter("https://example.test", client=client)
        result = run(adapter.get_monthly_report("2026-10"))
        self.assertEqual(result["meta"]["data_revision"], 8)
        with self.assertRaises(FiscalMCPError) as caught:
            run(adapter.create_import_batch({}))
        self.assertEqual(caught.exception.code, "batch_api_unavailable")
        self.assertEqual(client.request_url, "https://example.test/reports/v2/monthly/2026-10")

    def test_batch_http_routes_forward_versions_and_commit_idempotency(self) -> None:
        class Response:
            status_code = 200
            headers = {"content-type": "application/json"}
            content = b""

            def __init__(self, body):
                self.body = body

            def json(self):
                return self.body

        class Client:
            def __init__(self):
                self.calls = []

            async def request(self, method, url, *, headers, params, json):
                self.calls.append((method, url, headers, params, json))
                if method == "GET":
                    return Response({"items": [{"batch_id": "batch-1", "version": 1}]})
                return Response({"batch_id": "batch-1", "status": "committed", "data_revision": 9})

            async def aclose(self):
                return None

        client = Client()
        adapter = HttpFiscalBackendAdapter("https://example.test", batch_path="/import-batches", client=client)
        listed = run(adapter.list_import_batches({"status": "pending"}))
        self.assertEqual(listed["items"][0]["batch_id"], "batch-1")
        committed = run(adapter.commit_import_batch("batch-1", 2, "v1.token", "commit-1234"))
        self.assertEqual(committed["data_revision"], 9)
        method, url, headers, params, body = client.calls[-1]
        self.assertEqual((method, url), ("POST", "https://example.test/import-batches/batch-1/commit"))
        self.assertEqual(headers["Idempotency-Key"], "commit-1234")
        self.assertEqual(body["expected_version"], 2)
        self.assertEqual(body["confirmation_token"], "v1.token")


if __name__ == "__main__":
    unittest.main()

