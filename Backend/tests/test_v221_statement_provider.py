from __future__ import annotations

import json

import httpx
import pytest

from fiscal_api.api.p26_schemas import StatementProviderOutboundRequest
from fiscal_api.core.errors import APIError
from fiscal_api.services.ai_provider import OpenAICompatibleProvider
from fiscal_api.services.statement_import_provider import OpenAICompatibleStatementImportProvider


def evidence() -> StatementProviderOutboundRequest:
    return StatementProviderOutboundRequest.model_validate(
        {
            "schema_version": "statement-provider-v1",
            "currency": "CNY",
            "pages": [
                {
                    "page_number": 1,
                    "source_kind": "text",
                    "evidence_text_masked": "[REDACTED]\n2026-08-12 Grocery 18.50",
                }
            ],
            "rows": [
                {
                    "row_number": 1,
                    "page_number": 1,
                    "evidence_text_masked": "2026-08-12 Grocery 18.50",
                    "bounding_box": {"x": 0.1, "y": 0.1, "width": 0.5, "height": 0.1},
                }
            ],
        }
    )


def result() -> dict[str, object]:
    return {
        "schema_version": "statement-provider-v1",
        "document": {"status": "complete"},
        "candidates": [
            {
                "source_row_numbers": [1],
                "transaction_date": "2026-08-12",
                "raw_amount": "18.50",
                "direction": "outflow",
                "transaction_kind": "expense",
                "summary_evidence": "Grocery",
            }
        ],
    }


def adapter(handler: object, limit: int = 100_000) -> OpenAICompatibleStatementImportProvider:
    return OpenAICompatibleStatementImportProvider(
        OpenAICompatibleProvider(
            base_url="http://statement.local/v1",
            model="local-statement-test",
            api_key="local-stub-key",
            timeout_seconds=1,
            max_response_bytes=limit,
            transport=httpx.MockTransport(handler),  # type: ignore[arg-type]
        ),
        "test-revision",
    )


@pytest.mark.asyncio
async def test_statement_adapter_posts_only_masked_evidence_with_real_http_shape() -> None:
    requests: list[httpx.Request] = []

    def handle(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        body = json.loads(request.content)
        assert str(request.url) == "http://statement.local/v1/chat/completions"
        assert body["model"] == "local-statement-test"
        assert json.loads(body["messages"][1]["content"])["input"] == evidence().model_dump(
            mode="json"
        )
        return httpx.Response(
            200, json={"choices": [{"message": {"content": json.dumps(result())}}]}
        )

    parsed = await adapter(handle).parse(evidence())
    assert parsed.candidates[0].raw_amount == "18.50"
    assert len(requests) == 1


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "bad",
    [
        "not json",
        '{"candidates": []}',
        '{"secret": "unexpected"}',
        json.dumps(
            {
                **result(),
                "candidates": [
                    {
                        "source_row_numbers": [1],
                        "raw_amount": "18.501",
                        "direction": "outflow",
                        "transaction_kind": "expense",
                    }
                ],
            }
        ),
    ],
)
async def test_statement_adapter_rejects_empty_unknown_fields_and_precision(bad: str) -> None:
    def handle(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"choices": [{"message": {"content": bad}}]})

    with pytest.raises((ValueError, APIError)):
        await adapter(handle).parse(evidence())


@pytest.mark.asyncio
async def test_statement_adapter_enforces_response_budget() -> None:
    def handle(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"x" * 1000)

    with pytest.raises(APIError):
        await adapter(handle, limit=100).parse(evidence())


def test_statement_source_amount_cannot_be_a_substring_of_a_larger_amount():
    from fiscal_api.api.p26_schemas import StatementProviderResult
    from fiscal_api.services.statement_imports import StatementImportService

    service = StatementImportService(None, adapter(lambda _: None))
    payload = result()
    payload["candidates"][0]["raw_amount"] = "8.50"
    with pytest.raises(ValueError, match="unproven amount"):
        service._validate_provider_result(
            StatementProviderResult.model_validate(payload), evidence()
        )
