"""Loopback-only Swift/PDF integration harness; never uses a production provider or database."""

from __future__ import annotations

import json
import os
import re

import httpx
from sqlalchemy.engine import make_url

from fiscal_api.api.dependencies import get_statement_import_provider
from fiscal_api.core.config import Settings
from fiscal_api.main import create_app
from fiscal_api.services.ai_provider import OpenAICompatibleProvider
from fiscal_api.services.statement_import_provider import OpenAICompatibleStatementImportProvider


def create_e2e_app():
    url = os.environ["FISCAL_TEST_DATABASE_URL"]
    parsed = make_url(url)
    local_database = parsed.host in {"localhost", "127.0.0.1"} or (
        parsed.host is None and parsed.query.get("host") == "/tmp"  # noqa: S108 - PG socket only
    )
    if not local_database or "test" not in (parsed.database or ""):
        raise RuntimeError("Explicit disposable local test database required")

    def handle(request: httpx.Request) -> httpx.Response:
        wire = json.loads(request.content)
        evidence = json.loads(wire["messages"][1]["content"])["input"]
        assert set(evidence) == {"schema_version", "currency", "pages", "rows"}
        assert "4111111111111111" not in json.dumps(evidence)
        candidates = []
        for row in evidence["rows"]:
            if "Grocery" in row["evidence_text_masked"]:
                match = re.search(r"(\d{4}-\d{2}-\d{2}).*?(18\.50)", row["evidence_text_masked"])
                if match:
                    candidates.append(
                        {
                            "source_row_numbers": [row["row_number"]],
                            "transaction_date": match[1],
                            "raw_amount": match[2],
                            "direction": "outflow",
                            "transaction_kind": "expense",
                            "summary_evidence": "Grocery",
                        }
                    )
        result = {
            "schema_version": "statement-provider-v1",
            "document": {"status": "complete"},
            "candidates": candidates,
        }
        return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(result)}}]})

    transport = OpenAICompatibleProvider(
        base_url="http://statement.local/v1",
        model="local-statement-test",
        api_key="local-stub-only",
        timeout_seconds=2,
        max_response_bytes=100_000,
        transport=httpx.MockTransport(handle),
    )
    app = create_app(
        settings=Settings(environment="test", database_url=url, rate_limit_write_per_minute=300)
    )
    app.dependency_overrides[get_statement_import_provider] = lambda: (
        OpenAICompatibleStatementImportProvider(transport, "e2e-stub-v1")
    )
    return app
