from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "preflight.py"
SPEC = importlib.util.spec_from_file_location("fiscal_mcp_preflight", SCRIPT)
assert SPEC and SPEC.loader
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)


def valid_values() -> dict[str, str]:
    return {
        "FISCAL_BACKEND_URL": "https://fiscal.invalid/api/v1",
        "FISCAL_BACKEND_TOKEN": "backend-token-0123456789-abcdef0123456789",
        "FISCAL_BATCH_API_PATH": "/import-batches",
        "FISCAL_MCP_API_KEY": "agent-key-0123456789",
        "FISCAL_MCP_API_SCOPES": "read:reports,read:ledger,stage:imports,export:reports",
        "FISCAL_MCP_TOTP_SECRET": "JBSWY3DPEHPK3PXP",
        "FISCAL_MCP_SESSION_SCOPES": "read:reports,read:ledger,stage:imports,export:reports",
        "FISCAL_MCP_CONFIRMATION_SECRET": "confirmation-secret-0123456789-0123456789",
        "FISCAL_MCP_APPROVAL_URL": "https://console.fiscal.invalid/agent/approve",
        "FISCAL_MCP_USE_MOCK": "0",
        "FISCAL_MCP_HTTP_PATH": "/mcp",
        "FISCAL_MCP_HEALTH_PATH": "/health",
        "FISCAL_MCP_BIND_HOST": "127.0.0.1",
        "FISCAL_MCP_BIND_PORT": "8050",
    }


class PreflightTests(unittest.TestCase):
    def test_valid_stage_configuration_has_secret_free_summary(self) -> None:
        summary = preflight.validate(valid_values(), target="staging")
        self.assertEqual(summary["backend_url"], "https://fiscal.invalid/api/v1")
        self.assertEqual(summary["commit_confirmation"], "configured")
        self.assertEqual(summary["bind"], "127.0.0.1:8050")
        self.assertNotIn("backend-token", repr(summary))

    def test_production_rejects_http(self) -> None:
        values = valid_values()
        values["FISCAL_BACKEND_URL"] = "http://fiscal.invalid/api/v1"
        with self.assertRaisesRegex(preflight.ConfigError, "HTTPS"):
            preflight.validate(values, target="production")

    def test_commit_scope_requires_independent_confirmation_secret(self) -> None:
        values = valid_values()
        values["FISCAL_MCP_API_SCOPES"] += ",commit:imports"
        values["FISCAL_MCP_CONFIRMATION_SECRET"] = values["FISCAL_BACKEND_TOKEN"]
        with self.assertRaisesRegex(preflight.ConfigError, "independent"):
            preflight.validate(values, target="staging")

    def test_commit_scope_accepts_long_independent_secret(self) -> None:
        values = valid_values()
        values["FISCAL_MCP_API_SCOPES"] += ",commit:imports"
        values["FISCAL_MCP_CONFIRMATION_SECRET"] = "confirmation-secret-0123456789-0123456789"
        summary = preflight.validate(values, target="staging")
        self.assertEqual(summary["commit_confirmation"], "configured")

    def test_mock_mode_is_local_only(self) -> None:
        values = valid_values()
        values["FISCAL_MCP_USE_MOCK"] = "1"
        values.pop("FISCAL_BACKEND_URL")
        values.pop("FISCAL_BACKEND_TOKEN")
        values.pop("FISCAL_BATCH_API_PATH")
        summary = preflight.validate(values, target="local")
        self.assertEqual(summary["backend_url"], "mock adapter")
        with self.assertRaisesRegex(preflight.ConfigError, "FISCAL_MCP_USE_MOCK"):
            preflight.validate({**values, "FISCAL_BACKEND_URL": "https://fiscal.invalid/api/v1"}, target="staging")

    def test_deployed_gateway_must_remain_loopback(self) -> None:
        values = valid_values()
        values["FISCAL_MCP_BIND_HOST"] = "0.0.0.0"
        with self.assertRaisesRegex(preflight.ConfigError, "loopback"):
            preflight.validate(values, target="production")

    def test_cors_does_not_allow_wildcard(self) -> None:
        values = valid_values()
        values["FISCAL_MCP_ALLOWED_ORIGINS"] = "*"
        with self.assertRaisesRegex(preflight.ConfigError, "exact origins"):
            preflight.validate(values, target="production")

    def test_env_file_parser_handles_comments_and_quotes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mcp.env"
            path.write_text(
                "# comment\nFISCAL_BACKEND_URL='https://fiscal.invalid/api/v1'\n",
                encoding="utf-8",
            )
            values = preflight.read_env_file(path)
        self.assertEqual(values["FISCAL_BACKEND_URL"], "https://fiscal.invalid/api/v1")


if __name__ == "__main__":
    unittest.main()
