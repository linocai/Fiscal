from __future__ import annotations

import asyncio
import unittest

from fiscal_mcp.adapter import HttpFiscalBackendAdapter, MockFiscalBackendAdapter
from fiscal_mcp.auth import ApiKeyRegistry, TotpSessionRegistry
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
                "fiscal_list_accounts",
                "fiscal_list_categories",
                "fiscal_create_account",
                "fiscal_create_category",
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

    def test_list_accounts_includes_open_cycles_and_categories_flatten(self) -> None:
        self.adapter.accounts = [
            {"id": "cash-1", "name": "钱包", "kind": "cash", "cycle_mode": None, "usage_count": 3},
            {"id": "card-1", "name": "信用卡", "kind": "credit", "cycle_mode": "statement_day_cutoff"},
            {"id": "flex-1", "name": "随借随还", "kind": "credit", "cycle_mode": "on_demand"},
            {"id": "old-1", "name": "旧卡", "kind": "debit", "archived_at": "2026-01-01T00:00:00Z"},
        ]
        self.adapter.credit_cycles["card-1"] = [
            {"id": "cycle-new", "due_date": "2026-11-22", "status": "open", "remaining_minor": 500},
            {"id": "cycle-old", "due_date": "2026-10-22", "status": "unpaid", "remaining_minor": 1000},
            {"id": "cycle-done", "due_date": "2026-09-22", "status": "settled", "remaining_minor": 0},
        ]
        self.adapter.categories = [
            {"id": "food", "name": "餐饮", "direction": "expense", "children": [{"id": "coffee", "name": "咖啡", "direction": "expense", "parent_id": "food"}]},
        ]
        accounts = self.invoke("fiscal_list_accounts", {})["items"]
        self.assertEqual([item["id"] for item in accounts], ["cash-1", "card-1", "flex-1"])
        self.assertNotIn("usage_count", accounts[0])
        self.assertNotIn("open_cycles", accounts[0])
        self.assertNotIn("open_cycles", accounts[2])
        self.assertEqual([cycle["cycle_id"] for cycle in accounts[1]["open_cycles"]], ["cycle-old", "cycle-new"])
        self.assertEqual(len(self.invoke("fiscal_list_accounts", {"include_archived": True})["items"]), 4)
        categories = self.invoke("fiscal_list_categories", {"direction": "expense"})["items"]
        self.assertEqual([(item["id"], item["parent_id"]) for item in categories], [("food", None), ("coffee", "food")])
        with self.assertRaises(FiscalMCPError) as caught:
            self.invoke("fiscal_list_categories", {"direction": "transfer"})
        self.assertEqual(caught.exception.code, "invalid_params")

    def test_candidate_accepts_credit_cycle_id(self) -> None:
        repayment = {**self.candidate("repay-1"), "kind": "repayment", "category_id": None, "destination_account_id": "card-1", "credit_cycle_id": "cycle-old"}
        batch = self.invoke(
            "fiscal_create_import_batch",
            {"source": "structured", "original_content_sha256": "d" * 64, "candidates": [repayment], "idempotency_key": "import-repay-01"},
        )
        self.assertEqual(batch["candidates"][0]["credit_cycle_id"], "cycle-old")

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


class SessionCommitTests(unittest.TestCase):
    SECRET = "JBSWY3DPEHPK3PXP"

    def setUp(self) -> None:
        from datetime import datetime, timezone

        from test_auth import totp

        self.totp = totp
        self.adapter = MockFiscalBackendAdapter()
        self.sessions = TotpSessionRegistry(self.SECRET, default_scopes=[scope for scope in Scope if scope is not Scope.COMMIT_IMPORTS])
        self.service = FiscalMCPService(self.adapter, ApiKeyRegistry(), HMACConfirmationVerifier("test-confirmation-secret"), sessions=self.sessions)
        now = datetime.now(timezone.utc)
        challenge, _ = self.sessions.create_challenge(kind="session", now=now)
        self.sessions.approve(challenge.challenge_id, totp(self.SECRET, now), now=now)
        self.session = challenge.result_token

    def call(self, tool, args):
        return run(self.service.invoke(tool, args, api_key=None, session_token=self.session))

    def validated_batch(self, key: str) -> dict:
        candidate = {"client_id": "row-1", "kind": "expense", "amount_minor": 1234, "occurred_at": "2026-10-01T12:00:00+08:00", "title": f"Coffee {key}", "account_id": "account-1", "category_id": "category-1"}
        batch = self.call("fiscal_create_import_batch", {"source": "structured", "original_content_sha256": "e" * 64, "candidates": [candidate], "idempotency_key": f"import-{key}"})
        return self.call("fiscal_validate_import_batch", {"batch_id": batch["batch_id"], "expected_version": 1})

    def open_window(self) -> None:
        from datetime import datetime, timezone

        now = datetime.now(timezone.utc)
        challenge, _ = self.sessions.create_challenge(kind="write_window", session_token=self.session, now=now)
        self.sessions.approve(challenge.challenge_id, self.totp(self.SECRET, now), now=now)

    def test_commit_requires_an_open_write_window(self) -> None:
        batch = self.validated_batch("closed-01")
        with self.assertRaises(FiscalMCPError) as caught:
            self.call("fiscal_commit_import_batch", {"batch_id": batch["batch_id"], "expected_version": 2, "idempotency_key": "commit-closed-01"})
        self.assertEqual(caught.exception.code, "write_window_required")

    def test_master_data_creation_requires_window_and_validates_shape(self) -> None:
        account = {"name": "微信零钱", "kind": "cash", "opening_balance_minor": 12_345}
        category = {"name": "咖啡", "direction": "expense", "aliases": ["瑞幸", "星巴克"]}
        for tool, args in (("fiscal_create_account", account), ("fiscal_create_category", category)):
            with self.assertRaises(FiscalMCPError) as caught:
                self.call(tool, args)
            self.assertEqual(caught.exception.code, "write_window_required")
        self.open_window()
        created = self.call("fiscal_create_account", account)
        self.assertEqual((created["name"], created["kind"]), ("微信零钱", "cash"))
        self.assertIn("id", created)
        self.assertEqual(self.adapter.accounts[0]["opening_balance_minor"], 12_345)
        created_category = self.call("fiscal_create_category", category)
        self.assertEqual(created_category["aliases"], ["瑞幸", "星巴克"])
        self.assertEqual((self.adapter.categories[0]["icon"], self.adapter.categories[0]["color_hex"]), ("tag", "#6B7280"))
        listed = self.call("fiscal_list_accounts", {})["items"]
        self.assertEqual([item["name"] for item in listed], ["微信零钱"])
        with self.assertRaises(FiscalMCPError) as caught:
            self.call("fiscal_create_account", account)
        self.assertEqual(caught.exception.code, "account_name_conflict")
        for tool, bad in (
            ("fiscal_create_account", {**account, "name": "x", "opening_balance_minor": "12.34"}),
            ("fiscal_create_account", {**account, "name": "y", "kind": "wallet"}),
            ("fiscal_create_account", {**account, "name": "z", "statement_day": 31}),
            ("fiscal_create_account", {**account, "name": "w", "balance": 1}),
            ("fiscal_create_category", {**category, "name": "k", "color_hex": "red"}),
            ("fiscal_create_category", {**category, "name": "m", "direction": "transfer"}),
        ):
            with self.assertRaises(FiscalMCPError) as caught:
                self.call(tool, bad)
            self.assertEqual(caught.exception.code, "invalid_params", bad)

    def test_one_window_covers_several_commits_and_retries(self) -> None:
        self.open_window()
        for key in ("window-01", "window-02"):
            batch = self.validated_batch(key)
            args = {"batch_id": batch["batch_id"], "expected_version": 2, "idempotency_key": f"commit-{key}"}
            committed = self.call("fiscal_commit_import_batch", args)
            self.assertEqual(committed["batch"]["status"], "committed")
            self.assertEqual(self.call("fiscal_commit_import_batch", args), committed)
        self.assertEqual(len(self.adapter.ledger_items), 2)


class RecordingClient:
    def __init__(self, status_code=200, body=None, content_type="application/json", content=b""):
        self.calls = []
        self.status_code = status_code
        self.body = body if body is not None else {"meta": {"data_revision": 3}}
        self.content_type = content_type
        self.content = content

    async def request(self, method, url, *, headers, params, json):
        self.calls.append((method, url, headers, params, json))
        outer = self

        class Response:
            status_code = outer.status_code
            headers = {"content-type": outer.content_type, "x-fiscal-data-revision": "3"}
            content = outer.content

            def json(self):
                return outer.body

        return Response()

    async def aclose(self):
        return None


class HttpAdapterTests(unittest.TestCase):
    def test_reports_and_exports_request_as_of_balances(self) -> None:
        client = RecordingClient()
        adapter = HttpFiscalBackendAdapter("https://example.test", client=client)
        run(adapter.get_monthly_report("2026-10"))
        run(adapter.get_yearly_report("2026"))
        client.content_type, client.content = "text/csv", b"a,b\n"
        exported = run(adapter.export_report("year", "2026", "csv"))
        self.assertEqual(exported["data_revision"], 3)
        self.assertEqual(
            [url for _, url, *_ in client.calls],
            [
                "https://example.test/reports/v2/monthly/2026-10",
                "https://example.test/reports/v2/yearly/2026",
                "https://example.test/reports/v2/yearly/2026/export.csv",
            ],
        )
        for _, _, headers, _, _ in client.calls:
            self.assertEqual(headers["X-Fiscal-Report-Balance-Semantics"], "as-of-v1")

    def test_backend_4xx_passes_message_and_details_but_5xx_stays_generic(self) -> None:
        envelope = {
            "error": {
                "code": "historical_balance_unavailable",
                "message": "Opening balance is unknown for one or more accounts",
                "request_id": "req-1",
                "details": {"unknown_balance_account_ids": ["acc-1"]},
            }
        }
        adapter = HttpFiscalBackendAdapter("https://example.test", client=RecordingClient(409, envelope))
        with self.assertRaises(FiscalMCPError) as caught:
            run(adapter.get_yearly_report("2026"))
        error = caught.exception
        self.assertEqual(error.code, "historical_balance_unavailable")
        self.assertEqual(error.message, "Opening balance is unknown for one or more accounts")
        self.assertEqual(error.details["http_status"], 409)
        self.assertEqual(error.details["backend_details"], {"unknown_balance_account_ids": ["acc-1"]})
        self.assertEqual(error.details["request_id"], "req-1")
        internal = {"error": {"code": "internal_error", "message": "database exploded", "details": {"sql": "secret"}}}
        adapter = HttpFiscalBackendAdapter("https://example.test", client=RecordingClient(500, internal))
        with self.assertRaises(FiscalMCPError) as caught:
            run(adapter.get_yearly_report("2026"))
        self.assertEqual(caught.exception.message, "Fiscal backend request failed (500).")
        self.assertEqual(caught.exception.details, {"http_status": 500})

    def test_list_routes(self) -> None:
        client = RecordingClient(body=[])
        adapter = HttpFiscalBackendAdapter("https://example.test", client=client)
        run(adapter.list_accounts(False))
        run(adapter.list_categories("expense", True))
        client.body = {"items": [], "next_cursor": None}
        run(adapter.list_credit_cycles("card-1", "cursor-1"))
        self.assertEqual(
            [(url, params) for _, url, _, params, _ in client.calls],
            [
                ("https://example.test/accounts", {"include_archived": "false"}),
                ("https://example.test/categories", {"include_archived": "true", "direction": "expense"}),
                ("https://example.test/credit-accounts/card-1/cycles", {"limit": 100, "cursor": "cursor-1"}),
            ],
        )

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

