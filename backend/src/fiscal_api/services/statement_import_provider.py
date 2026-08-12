"""P26 isolated statement provider contract.

Only the synthetic adapter exists in this slice.  It neither reads settings nor opens a network
connection; production adapters intentionally have no construction path here.
"""

from __future__ import annotations

from typing import Protocol

from fiscal_api.api.p26_schemas import StatementProviderOutboundRequest, StatementProviderResult
from fiscal_api.core.errors import APIError


class StatementImportProvider(Protocol):
    provider_id: str
    model_id: str
    prompt_version: str
    schema_version: str

    async def parse(self, request: StatementProviderOutboundRequest) -> StatementProviderResult: ...


class SyntheticStatementImportProvider:
    provider_id = "synthetic_statement"
    model_id = "synthetic-statement-v1"
    prompt_version = "statement-p26-v1"
    schema_version = "statement-provider-v1"

    async def parse(self, request: StatementProviderOutboundRequest) -> StatementProviderResult:
        # Intentional no-op parser: P26 validates transport, snapshots, and source references.
        # P27 owns turning parsed candidates into import rows or ledger actions.
        del request
        return StatementProviderResult(document={"status": "synthetic"}, candidates=[])


def unavailable_provider_error() -> APIError:
    return APIError(
        status_code=503,
        code="statement_provider_unavailable",
        message="Statement parsing is temporarily unavailable",
    )
