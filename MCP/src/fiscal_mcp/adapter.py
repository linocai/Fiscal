"""Backend adapters used by the MCP service.

The HTTP adapter talks to existing Fiscal routes for read/export operations.
Batch endpoints are configurable because Build51 does not yet expose a batch
resource.  Until that backend contract exists, the mock adapter provides a
complete deterministic fixture for local MCP/Web work.
"""

from __future__ import annotations

import copy
import hashlib
import json
import uuid
from dataclasses import dataclass, field
from typing import Any, Mapping, Protocol

try:  # httpx is the only runtime dependency beyond Python's stdlib.
    import httpx as _httpx
except ImportError:  # pragma: no cover - exercised only in dependency-less installs
    httpx: Any = None
else:
    httpx: Any = _httpx

from .contracts import BatchStatus
from .errors import FiscalMCPError


class FiscalBackendAdapter(Protocol):
    async def get_monthly_report(self, period: str) -> dict[str, Any]: ...

    async def get_yearly_report(self, year: str) -> dict[str, Any]: ...

    async def list_accounts(self, include_archived: bool) -> list[dict[str, Any]]: ...

    async def list_categories(self, direction: str | None, include_archived: bool) -> list[dict[str, Any]]: ...

    async def list_credit_cycles(self, account_id: str, cursor: str | None) -> dict[str, Any]: ...

    async def create_account(self, payload: Mapping[str, Any]) -> dict[str, Any]: ...

    async def list_cash_flow_items(self, account_id: str | None, month: str | None) -> dict[str, Any]: ...

    async def get_cash_flow_outlook(self, window_days: int) -> dict[str, Any]: ...

    async def create_cash_flow_item(self, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]: ...

    async def settle_cash_flow_item(self, item_id: str, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]: ...

    async def cancel_cash_flow_item(self, item_id: str, expected_version: int, scope: str) -> dict[str, Any]: ...

    async def confirm_cash_flow_item(self, item_id: str, expected_version: int, scope: str) -> dict[str, Any]: ...

    async def list_reimbursements(self, params: Mapping[str, Any]) -> dict[str, Any]: ...

    async def list_reimbursable_expenses(self, params: Mapping[str, Any]) -> dict[str, Any]: ...

    async def get_reimbursement(self, claim_id: str) -> dict[str, Any]: ...

    async def create_reimbursement(self, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]: ...

    async def submit_reimbursement(self, claim_id: str, expected_version: int) -> dict[str, Any]: ...

    async def preview_reimbursement_receipt(self, claim_id: str, payload: Mapping[str, Any]) -> dict[str, Any]: ...

    async def create_reimbursement_receipt(self, claim_id: str, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]: ...

    async def preview_reimbursement_cancel(self, claim_id: str, expected_version: int) -> dict[str, Any]: ...

    async def cancel_reimbursement_outstanding(
        self, claim_id: str, expected_version: int, preview_token: str, idempotency_key: str
    ) -> dict[str, Any]: ...

    async def create_category(self, payload: Mapping[str, Any]) -> dict[str, Any]: ...

    async def search_ledger(self, filters: Mapping[str, Any]) -> dict[str, Any]: ...

    async def list_import_batches(self, filters: Mapping[str, Any] | None = None) -> dict[str, Any]: ...

    async def create_import_batch(self, payload: Mapping[str, Any]) -> dict[str, Any]: ...

    async def get_import_batch(self, batch_id: str) -> dict[str, Any]: ...

    async def validate_import_batch(self, batch_id: str, expected_version: int) -> dict[str, Any]: ...

    async def commit_import_batch(
        self, batch_id: str, expected_version: int, confirmation_token: str, idempotency_key: str
    ) -> dict[str, Any]: ...

    async def ignore_import_batch(
        self, batch_id: str, expected_version: int, reason: str | None
    ) -> dict[str, Any]: ...

    async def export_report(
        self, period_kind: str, period: str, export_format: str
    ) -> dict[str, Any]: ...


class BackendAdapterError(FiscalMCPError):
    """A safe error returned when the configured backend cannot be reached."""


# Reports use as-of balances so a ledger that starts mid-year returns data plus
# per-account balance status instead of a 409.
REPORT_HEADERS = {"X-Fiscal-Report-Balance-Semantics": "as-of-v1"}
MAX_ERROR_DETAILS_BYTES = 4_096


def backend_idempotency_uuid(tool: str, key: str) -> str:
    """Backend cash-flow routes need a UUID Idempotency-Key; derive it deterministically."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"fiscal-mcp:{tool}:{key}"))


def backend_outcome_known(error: FiscalMCPError) -> bool:
    """True when the backend answered with a definite 4xx rejection."""

    status = (error.details or {}).get("http_status")
    return isinstance(status, int) and 400 <= status < 500


def _backend_error(status_code: int, body: Any) -> BackendAdapterError:
    """Translate a backend error envelope into a public MCP error.

    4xx responses are business rejections whose message and details are part
    of the backend's public API, so they pass through (size-capped).  5xx keeps
    a generic message so internals never leak.
    """

    error_body = body.get("error") if isinstance(body, dict) else None
    source = error_body if isinstance(error_body, dict) else body if isinstance(body, dict) else {}
    code = source.get("code") if isinstance(source.get("code"), str) else "backend_error"
    details: dict[str, Any] = {"http_status": status_code}
    if status_code >= 500:
        return BackendAdapterError(code, f"Fiscal backend request failed ({status_code}).", details)
    message = source.get("message")
    if not isinstance(message, str) or not message.strip():
        message = f"Fiscal backend request failed ({status_code})."
    backend_details = source.get("details")
    if backend_details is not None:
        encoded = json.dumps(backend_details, ensure_ascii=False, default=str)
        if len(encoded.encode("utf-8")) <= MAX_ERROR_DETAILS_BYTES:
            details["backend_details"] = backend_details
        else:
            details["backend_details_truncated"] = True
    if isinstance(source.get("request_id"), str):
        details["request_id"] = source["request_id"]
    return BackendAdapterError(code, message[:500], details)


class HttpFiscalBackendAdapter:
    """Translate stable MCP calls to existing Fiscal HTTP routes.

    ``batch_path`` is intentionally opt-in.  Build51 has proposal endpoints,
    but no atomic import-batch endpoint.  Calling a proposal endpoint once per
    row would break batch idempotency, so this adapter fails clearly until a
    backend batch route is available.
    """

    def __init__(
        self,
        base_url: str,
        *,
        backend_token: str | None = None,
        timeout_seconds: float = 15.0,
        batch_path: str | None = None,
        client: Any | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.backend_token = backend_token
        self.batch_path = batch_path
        self._client = client
        self.timeout_seconds = timeout_seconds

    @staticmethod
    def _revision_from(value: Any) -> int | None:
        """Read a revision only when the backend explicitly supplies one.

        Build51 responses use ``meta.data_revision`` while a future batch
        endpoint may put it at the top level or in a response header.  The
        adapter accepts all of those shapes without inventing a revision.
        """

        candidates: list[Any] = []
        if isinstance(value, Mapping):
            candidates.extend(
                (
                    value.get("data_revision"),
                    value.get("dataRevision"),
                    value.get("revision"),
                )
            )
            meta = value.get("meta")
            if isinstance(meta, Mapping):
                candidates.extend((meta.get("data_revision"), meta.get("dataRevision"), meta.get("revision")))
        for candidate in candidates:
            if isinstance(candidate, bool):
                continue
            if isinstance(candidate, int) and candidate >= 0:
                return candidate
            if isinstance(candidate, str) and candidate.isdigit():
                return int(candidate)
        return None

    @classmethod
    def _attach_header_revision(cls, body: Any, headers: Mapping[str, Any]) -> Any:
        """Expose an explicit revision header without changing other fields."""

        if not isinstance(body, dict) or cls._revision_from(body) is not None:
            return body
        revision: int | None = None
        for name, value in headers.items():
            if name.lower() in {"x-fiscal-data-revision", "x-data-revision", "x-fiscal-revision"}:
                revision = cls._revision_from({"data_revision": value})
                if revision is not None:
                    break
        if revision is None:
            return body
        result = dict(body)
        meta = result.get("meta")
        if isinstance(meta, dict):
            result["meta"] = {**meta, "data_revision": revision}
        else:
            result["data_revision"] = revision
        return result

    def _headers(self) -> dict[str, str]:
        headers = {"Accept": "application/json"}
        if self.backend_token:
            headers["Authorization"] = f"Bearer {self.backend_token}"
        return headers

    async def _request(
        self,
        method: str,
        path: str,
        *,
        params: Mapping[str, Any] | None = None,
        json_body: Mapping[str, Any] | None = None,
        headers: Mapping[str, str] | None = None,
    ) -> Any:
        if httpx is None and self._client is None:
            raise BackendAdapterError("backend_dependency_missing", "Install MCP runtime dependencies first.")
        url = f"{self.base_url}/{path.lstrip('/')}"
        own_client = self._client is None
        client: Any
        if own_client:
            if httpx is None:  # defensive guard for dependency-less installs
                raise BackendAdapterError("backend_dependency_missing", "Install MCP runtime dependencies first.")
            client = httpx.AsyncClient(timeout=self.timeout_seconds)
        else:
            client = self._client
        try:
            response = await client.request(
                method,
                url,
                headers={**self._headers(), **dict(headers or {})},
                params=dict(params or {}),
                json=json_body,
            )
            if response.status_code >= 400:
                body: Any = None
                try:
                    body = response.json()
                except (ValueError, json.JSONDecodeError):
                    pass
                raise _backend_error(response.status_code, body)
            if response.headers.get("content-type", "").startswith("text/csv"):
                return {
                    "_csv_content": response.content,
                    "_headers": {key.lower(): value for key, value in response.headers.items()},
                }
            return self._attach_header_revision(response.json(), response.headers)
        except BackendAdapterError:
            raise
        except Exception as exc:
            raise BackendAdapterError("backend_unavailable", "Fiscal backend is unavailable.") from exc
        finally:
            if own_client:
                await client.aclose()

    async def get_monthly_report(self, period: str) -> dict[str, Any]:
        return await self._request("GET", f"/reports/v2/monthly/{period}", headers=REPORT_HEADERS)

    async def get_yearly_report(self, year: str) -> dict[str, Any]:
        return await self._request("GET", f"/reports/v2/yearly/{year}", headers=REPORT_HEADERS)

    async def list_accounts(self, include_archived: bool) -> list[dict[str, Any]]:
        result = await self._request("GET", "/accounts", params={"include_archived": str(include_archived).lower()})
        if not isinstance(result, list):
            raise BackendAdapterError("backend_contract_mismatch", "Fiscal accounts API returned an invalid list.")
        return result

    async def list_categories(self, direction: str | None, include_archived: bool) -> list[dict[str, Any]]:
        params: dict[str, Any] = {"include_archived": str(include_archived).lower()}
        if direction:
            params["direction"] = direction
        result = await self._request("GET", "/categories", params=params)
        if not isinstance(result, list):
            raise BackendAdapterError("backend_contract_mismatch", "Fiscal categories API returned an invalid list.")
        return result

    async def create_account(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        return await self._request("POST", "/accounts", json_body=payload)

    async def list_cash_flow_items(self, account_id: str | None, month: str | None) -> dict[str, Any]:
        if month:
            return await self._request("GET", "/cash-flow-items/history", params={"month": month})
        return await self._request("GET", "/cash-flow-items", params={"account_id": account_id} if account_id else None)

    async def get_cash_flow_outlook(self, window_days: int) -> dict[str, Any]:
        return await self._request("GET", "/reports/facts", params={"window_days": window_days}, headers=REPORT_HEADERS)

    async def create_cash_flow_item(self, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]:
        return await self._request("POST", "/cash-flow-items", json_body=payload, headers={"Idempotency-Key": idempotency_key})

    async def settle_cash_flow_item(self, item_id: str, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]:
        return await self._request(
            "POST", f"/cash-flow-items/{item_id}/settle", json_body=payload, headers={"Idempotency-Key": idempotency_key}
        )

    async def confirm_cash_flow_item(self, item_id: str, expected_version: int, scope: str) -> dict[str, Any]:
        return await self._request(
            "POST", f"/cash-flow-items/{item_id}/confirm", json_body={"expected_version": expected_version, "scope": scope}
        )

    async def cancel_cash_flow_item(self, item_id: str, expected_version: int, scope: str) -> dict[str, Any]:
        return await self._request(
            "POST", f"/cash-flow-items/{item_id}/cancel", json_body={"expected_version": expected_version, "scope": scope}
        )

    async def list_reimbursements(self, params: Mapping[str, Any]) -> dict[str, Any]:
        query = {key: (str(value).lower() if isinstance(value, bool) else value) for key, value in params.items()}
        return await self._request("GET", "/reimbursement-claims", params=query)

    async def list_reimbursable_expenses(self, params: Mapping[str, Any]) -> dict[str, Any]:
        return await self._request("GET", "/reimbursement-expense-candidates", params=params)

    async def get_reimbursement(self, claim_id: str) -> dict[str, Any]:
        return await self._request("GET", f"/reimbursement-claims/{claim_id}")

    async def create_reimbursement(self, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]:
        return await self._request("POST", "/reimbursement-claims", json_body=payload, headers={"Idempotency-Key": idempotency_key})

    async def submit_reimbursement(self, claim_id: str, expected_version: int) -> dict[str, Any]:
        return await self._request("POST", f"/reimbursement-claims/{claim_id}/submit", json_body={"expected_version": expected_version})

    async def preview_reimbursement_receipt(self, claim_id: str, payload: Mapping[str, Any]) -> dict[str, Any]:
        return await self._request("POST", f"/reimbursement-claims/{claim_id}/receipt-preview", json_body=payload)

    async def create_reimbursement_receipt(self, claim_id: str, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]:
        return await self._request(
            "POST", f"/reimbursement-claims/{claim_id}/receipts", json_body=payload, headers={"Idempotency-Key": idempotency_key}
        )

    async def preview_reimbursement_cancel(self, claim_id: str, expected_version: int) -> dict[str, Any]:
        return await self._request("POST", f"/reimbursement-claims/{claim_id}/cancel-preview", json_body={"expected_version": expected_version})

    async def cancel_reimbursement_outstanding(
        self, claim_id: str, expected_version: int, preview_token: str, idempotency_key: str
    ) -> dict[str, Any]:
        return await self._request(
            "POST",
            f"/reimbursement-claims/{claim_id}/cancel-outstanding",
            json_body={"expected_version": expected_version, "preview_token": preview_token},
            headers={"Idempotency-Key": idempotency_key},
        )

    async def create_category(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        return await self._request("POST", "/categories", json_body=payload)

    async def list_credit_cycles(self, account_id: str, cursor: str | None) -> dict[str, Any]:
        params: dict[str, Any] = {"limit": 100}
        if cursor:
            params["cursor"] = cursor
        result = await self._request("GET", f"/credit-accounts/{account_id}/cycles", params=params)
        if not isinstance(result, dict):
            raise BackendAdapterError("backend_contract_mismatch", "Fiscal credit cycle API returned an invalid page.")
        return result

    async def search_ledger(self, filters: Mapping[str, Any]) -> dict[str, Any]:
        return await self._request("GET", "/transactions", params=filters)

    async def list_import_batches(self, filters: Mapping[str, Any] | None = None) -> dict[str, Any]:
        """List import batches when the optional batch API is enabled.

        A backend may return either an object envelope or a bare JSON array;
        preserving the envelope while wrapping an array in ``items`` gives Web
        a stable collection boundary without guessing any candidate fields.
        """

        result = await self._request("GET", self._require_batch_path(), params=filters)
        if isinstance(result, list):
            return {"items": result}
        if not isinstance(result, dict):
            raise BackendAdapterError("backend_contract_mismatch", "Fiscal batch API returned an invalid collection.")
        return result

    def _require_batch_path(self) -> str:
        if not self.batch_path:
            raise BackendAdapterError(
                "batch_api_unavailable",
                "Fiscal Build51 has no import-batch API; configure a compatible batch_path first.",
            )
        return self.batch_path.rstrip("/")

    @staticmethod
    def _batch_contract(value: Any) -> dict[str, Any]:
        """Adapt the backend's UUID ``id`` to the stable MCP ``batch_id`` field."""
        if not isinstance(value, dict):
            raise BackendAdapterError("backend_contract_mismatch", "Fiscal batch API returned an invalid object.")
        result = dict(value)
        if "batch_id" not in result and isinstance(result.get("id"), (str, int)):
            result["batch_id"] = str(result["id"])
        return result

    async def create_import_batch(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        return self._batch_contract(await self._request("POST", self._require_batch_path(), json_body=payload))

    async def get_import_batch(self, batch_id: str) -> dict[str, Any]:
        return self._batch_contract(await self._request("GET", f"{self._require_batch_path()}/{batch_id}"))

    async def validate_import_batch(self, batch_id: str, expected_version: int) -> dict[str, Any]:
        return self._batch_contract(await self._request(
            "POST",
            f"{self._require_batch_path()}/{batch_id}/validate",
            json_body={"expected_version": expected_version},
        ))

    async def commit_import_batch(
        self, batch_id: str, expected_version: int, confirmation_token: str, idempotency_key: str
    ) -> dict[str, Any]:
        return self._batch_contract(await self._request(
            "POST",
            f"{self._require_batch_path()}/{batch_id}/commit",
            json_body={
                "expected_version": expected_version,
                "confirmation_token": confirmation_token,
                "idempotency_key": idempotency_key,
            },
            headers={"Idempotency-Key": idempotency_key},
        ))

    async def ignore_import_batch(
        self, batch_id: str, expected_version: int, reason: str | None
    ) -> dict[str, Any]:
        return self._batch_contract(await self._request(
            "POST",
            f"{self._require_batch_path()}/{batch_id}/ignore",
            json_body={"expected_version": expected_version, "reason": reason},
        ))

    async def export_report(self, period_kind: str, period: str, export_format: str) -> dict[str, Any]:
        if export_format != "csv":
            raise BackendAdapterError("unsupported_export", "Only CSV export is supported in phase one.")
        path = f"/reports/v2/{'monthly' if period_kind == 'month' else 'yearly'}/{period}/export.csv"
        response = await self._request("GET", path, headers=REPORT_HEADERS)
        if not isinstance(response, dict) or not isinstance(response.get("_csv_content"), bytes):
            raise BackendAdapterError("backend_error", "Fiscal backend returned an invalid export.")
        # A short-lived URL is a later web concern; MCP returns an inline
        # base64-safe text reference so no large content is placed in logs.
        import base64

        headers = response.get("_headers", {})
        revision = headers.get("x-fiscal-data-revision") if isinstance(headers, dict) else None
        try:
            data_revision = int(revision) if revision is not None else None
        except (TypeError, ValueError):
            data_revision = None
        return {
            "format": "csv",
            "period": period,
            "data_revision": data_revision,
            "content_base64": base64.b64encode(response["_csv_content"]).decode("ascii"),
        }


@dataclass(slots=True)
class MockFiscalBackendAdapter:
    """Deterministic fixture adapter for tests and local MCP development."""

    monthly_reports: dict[str, dict[str, Any]] = field(default_factory=dict)
    yearly_reports: dict[str, dict[str, Any]] = field(default_factory=dict)
    ledger_items: list[dict[str, Any]] = field(default_factory=list)
    accounts: list[dict[str, Any]] = field(default_factory=list)
    categories: list[dict[str, Any]] = field(default_factory=list)
    credit_cycles: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    cash_flow_items: list[dict[str, Any]] = field(default_factory=list)
    reimbursements: dict[str, dict[str, Any]] = field(default_factory=dict)
    reimbursable_expenses: list[dict[str, Any]] = field(default_factory=list)
    data_revision: int = 1
    _batches: dict[str, dict[str, Any]] = field(default_factory=dict, init=False, repr=False)
    _batch_idempotency: dict[str, str] = field(default_factory=dict, init=False, repr=False)
    _batch_idempotency_payloads: dict[str, str] = field(default_factory=dict, init=False, repr=False)
    _commit_idempotency: dict[str, dict[str, Any]] = field(default_factory=dict, init=False, repr=False)
    _commit_idempotency_context: dict[str, tuple[str, int]] = field(default_factory=dict, init=False, repr=False)
    _cash_flow_idempotency: dict[str, Any] = field(default_factory=dict, init=False, repr=False)
    _previews: dict[str, tuple[str, str, dict[str, Any]]] = field(default_factory=dict, init=False, repr=False)

    async def get_monthly_report(self, period: str) -> dict[str, Any]:
        return copy.deepcopy(self.monthly_reports.get(period, {"meta": {"period": period, "data_revision": self.data_revision}, "summary": {}, "categories": []}))

    async def get_yearly_report(self, year: str) -> dict[str, Any]:
        return copy.deepcopy(self.yearly_reports.get(year, {"meta": {"period": year, "data_revision": self.data_revision}, "summary": {}, "categories": []}))

    async def list_accounts(self, include_archived: bool) -> list[dict[str, Any]]:
        return copy.deepcopy([item for item in self.accounts if include_archived or not item.get("archived_at")])

    async def list_categories(self, direction: str | None, include_archived: bool) -> list[dict[str, Any]]:
        return copy.deepcopy(
            [
                item
                for item in self.categories
                if (include_archived or not item.get("archived_at")) and (direction is None or item.get("direction") == direction)
            ]
        )

    async def list_credit_cycles(self, account_id: str, cursor: str | None) -> dict[str, Any]:
        return {"items": copy.deepcopy(self.credit_cycles.get(account_id, [])), "next_cursor": None}

    def _create_named(self, rows: list[dict[str, Any]], payload: Mapping[str, Any], code: str) -> dict[str, Any]:
        if any(row.get("name", "").casefold() == str(payload["name"]).casefold() and not row.get("archived_at") for row in rows):
            raise FiscalMCPError(code, "A record with this name already exists.", {"http_status": 409})
        row = {"id": str(uuid.uuid4()), "archived_at": None, **copy.deepcopy(dict(payload))}
        rows.append(row)
        return copy.deepcopy(row)

    async def create_account(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        return self._create_named(self.accounts, payload, "account_name_conflict")

    async def list_cash_flow_items(self, account_id: str | None, month: str | None) -> dict[str, Any]:
        items = [
            item for item in self.cash_flow_items
            if (account_id is None or item.get("account_id") == account_id)
            and (item["status"] in {"settled", "cancelled"}) == (month is not None)
        ]
        return {"items": copy.deepcopy(items), "summary": {"inflow_minor": 0, "outflow_minor": 0, "net_minor": 0}}

    async def get_cash_flow_outlook(self, window_days: int) -> dict[str, Any]:
        return {"meta": {"data_revision": self.data_revision}, "window_days": window_days, "known_future_events": []}

    async def create_cash_flow_item(self, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]:
        if idempotency_key in self._cash_flow_idempotency:
            return copy.deepcopy(self._cash_flow_idempotency[idempotency_key])
        item = {"id": str(uuid.uuid4()), "status": "expected", "version": 1, "remaining_amount_minor": payload["planned_amount_minor"], **copy.deepcopy(dict(payload))}
        self.cash_flow_items.append(item)
        result = {"items": [copy.deepcopy(item)]}
        self._cash_flow_idempotency[idempotency_key] = result
        return copy.deepcopy(result)

    def _cash_flow(self, item_id: str, expected_version: int) -> dict[str, Any]:
        item = next((row for row in self.cash_flow_items if row["id"] == item_id), None)
        if item is None:
            raise FiscalMCPError("cash_flow_item_not_found", "Cash flow item was not found.", {"http_status": 404})
        if item["version"] != expected_version:
            raise FiscalMCPError("resource_version_conflict", "Cash flow item changed.", {"http_status": 409})
        return item

    async def confirm_cash_flow_item(self, item_id: str, expected_version: int, scope: str) -> dict[str, Any]:
        item = self._cash_flow(item_id, expected_version)
        item.update(status="confirmed", version=item["version"] + 1)
        return copy.deepcopy(item)

    async def settle_cash_flow_item(self, item_id: str, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]:
        if idempotency_key in self._cash_flow_idempotency:
            return copy.deepcopy(self._cash_flow_idempotency[idempotency_key])
        item = self._cash_flow(item_id, int(payload["expected_version"]))
        if item["status"] != "confirmed":
            raise FiscalMCPError("cash_flow_not_confirmed", "Only confirmed cash flow items can be settled", {"http_status": 409})
        transaction = {"id": str(uuid.uuid4()), "title": item["title"], "amount_minor": payload["actual_amount_minor"]}
        self.ledger_items.append(transaction)
        item.update(status="settled", version=item["version"] + 1, remaining_amount_minor=0, linked_transaction_id=transaction["id"])
        self._cash_flow_idempotency[idempotency_key] = copy.deepcopy(item)
        return copy.deepcopy(item)

    def _claim(self, claim_id: str, expected_version: int | None = None) -> dict[str, Any]:
        claim = self.reimbursements.get(claim_id)
        if claim is None:
            raise FiscalMCPError("reimbursement_claim_not_found", "Reimbursement claim was not found.", {"http_status": 404})
        if expected_version is not None and claim["version"] != expected_version:
            raise FiscalMCPError("resource_version_conflict", "Reimbursement claim changed.", {"http_status": 409})
        return claim

    @staticmethod
    def _claim_status(claim: dict[str, Any]) -> None:
        received, total = claim["received_minor"], claim["total_claimed_minor"]
        claim["outstanding_minor"] = 0 if claim.get("cancelled_at") else total - received
        claim["status"] = (
            ("partially_received_cancelled" if received else "cancelled") if claim.get("cancelled_at")
            else "received" if received == total
            else "partial_received" if received
            else "pending" if claim.get("submitted_at")
            else "draft"
        )

    async def list_reimbursements(self, params: Mapping[str, Any]) -> dict[str, Any]:
        items = [claim for claim in self.reimbursements.values() if params.get("status") in (None, claim["status"])]
        return {"items": copy.deepcopy(items), "next_cursor": None}

    async def list_reimbursable_expenses(self, params: Mapping[str, Any]) -> dict[str, Any]:
        return {"items": copy.deepcopy(self.reimbursable_expenses), "next_cursor": None}

    async def get_reimbursement(self, claim_id: str) -> dict[str, Any]:
        return copy.deepcopy(self._claim(claim_id))

    async def create_reimbursement(self, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]:
        if idempotency_key in self._cash_flow_idempotency:
            return copy.deepcopy(self._cash_flow_idempotency[idempotency_key])
        total = sum(int(expense["amount_minor"]) for expense in payload["expenses"])
        claim = {"id": str(uuid.uuid4()), **copy.deepcopy(dict(payload)), "total_claimed_minor": total, "received_minor": 0, "version": 1, "submitted_at": None, "cancelled_at": None}
        self._claim_status(claim)
        self.reimbursements[claim["id"]] = claim
        self._cash_flow_idempotency[idempotency_key] = copy.deepcopy(claim)
        return copy.deepcopy(claim)

    async def submit_reimbursement(self, claim_id: str, expected_version: int) -> dict[str, Any]:
        claim = self._claim(claim_id, expected_version)
        if claim["status"] != "draft":
            raise FiscalMCPError("reimbursement_action_unavailable", "Only drafts can be submitted.", {"http_status": 409})
        claim.update(submitted_at="2026-10-16T00:00:00+00:00", version=claim["version"] + 1)
        self._claim_status(claim)
        return copy.deepcopy(claim)

    async def preview_reimbursement_receipt(self, claim_id: str, payload: Mapping[str, Any]) -> dict[str, Any]:
        claim = self._claim(claim_id, int(payload["expected_claim_version"]))
        if int(payload["amount_minor"]) > claim["outstanding_minor"]:
            raise FiscalMCPError("reimbursement_receipt_exceeds_outstanding", "Receipt exceeds the outstanding amount.", {"http_status": 422})
        token = str(uuid.uuid4())
        self._previews[token] = ("receipt", claim_id, dict(payload))
        return {"preview_token": token, "claim_version": claim["version"]}

    async def create_reimbursement_receipt(self, claim_id: str, payload: Mapping[str, Any], idempotency_key: str) -> dict[str, Any]:
        if idempotency_key in self._cash_flow_idempotency:
            return copy.deepcopy(self._cash_flow_idempotency[idempotency_key])
        kind, previewed_claim, _ = self._previews.pop(str(payload["preview_token"]), (None, None, None))
        if kind is None:
            raise FiscalMCPError("reimbursement_preview_not_found", "The preview token is invalid", {"http_status": 422})
        if kind != "receipt" or previewed_claim != claim_id:
            raise FiscalMCPError("preview_token_invalid", "Preview is missing or stale.", {"http_status": 409})
        claim = self._claim(claim_id, int(payload["expected_claim_version"]))
        claim.update(received_minor=claim["received_minor"] + int(payload["amount_minor"]), version=claim["version"] + 1)
        self._claim_status(claim)
        receipt = {"id": str(uuid.uuid4()), "claim_id": claim_id, "amount_minor": payload["amount_minor"], "transaction": {"id": str(uuid.uuid4())}}
        self.ledger_items.append(receipt["transaction"])
        self._cash_flow_idempotency[idempotency_key] = copy.deepcopy(receipt)
        return copy.deepcopy(receipt)

    async def preview_reimbursement_cancel(self, claim_id: str, expected_version: int) -> dict[str, Any]:
        claim = self._claim(claim_id, expected_version)
        token = str(uuid.uuid4())
        self._previews[token] = ("cancel", claim_id, {})
        return {"preview_token": token, "released_minor": claim["outstanding_minor"]}

    async def cancel_reimbursement_outstanding(
        self, claim_id: str, expected_version: int, preview_token: str, idempotency_key: str
    ) -> dict[str, Any]:
        if idempotency_key in self._cash_flow_idempotency:
            return copy.deepcopy(self._cash_flow_idempotency[idempotency_key])
        kind, previewed_claim, _ = self._previews.pop(preview_token, (None, None, None))
        if kind != "cancel" or previewed_claim != claim_id:
            raise FiscalMCPError("preview_token_invalid", "Preview is missing or stale.", {"http_status": 409})
        claim = self._claim(claim_id, expected_version)
        claim.update(cancelled_at="2026-10-16T00:00:00+00:00", version=claim["version"] + 1)
        self._claim_status(claim)
        self._cash_flow_idempotency[idempotency_key] = copy.deepcopy(claim)
        return copy.deepcopy(claim)

    async def cancel_cash_flow_item(self, item_id: str, expected_version: int, scope: str) -> dict[str, Any]:
        item = self._cash_flow(item_id, expected_version)
        item.update(status="cancelled", version=item["version"] + 1)
        return {"items": [copy.deepcopy(item)]}

    async def create_category(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        return self._create_named(self.categories, payload, "category_name_conflict")

    async def search_ledger(self, filters: Mapping[str, Any]) -> dict[str, Any]:
        items = copy.deepcopy(self.ledger_items)
        query = filters.get("query")
        if isinstance(query, str) and query:
            items = [item for item in items if query.casefold() in json.dumps(item, ensure_ascii=False).casefold()]
        limit = int(filters.get("limit", 50))
        return {"items": items[:limit], "next_cursor": None, "data_revision": self.data_revision}

    async def list_import_batches(self, filters: Mapping[str, Any] | None = None) -> dict[str, Any]:
        statuses = filters.get("status") if isinstance(filters, Mapping) else None
        allowed = {str(status) for status in statuses} if isinstance(statuses, (list, tuple, set)) else None
        items = [batch for batch in self._batches.values() if allowed is None or batch["status"] in allowed]
        return {"items": copy.deepcopy(items), "data_revision": self.data_revision}

    async def create_import_batch(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        idem = str(payload["idempotency_key"])
        request_fingerprint = hashlib.sha256(
            json.dumps(dict(payload), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        ).hexdigest()
        existing_id = self._batch_idempotency.get(idem)
        if existing_id:
            if self._batch_idempotency_payloads.get(idem) != request_fingerprint:
                raise FiscalMCPError("idempotency_conflict", "The batch idempotency key was already used with different input.")
            return copy.deepcopy(self._batches[existing_id])
        batch_id = f"batch-{uuid.uuid5(uuid.NAMESPACE_URL, idem)}"
        batch = {
            "batch_id": batch_id,
            "status": BatchStatus.PENDING.value,
            "source": payload["source"],
            "original_content_sha256": payload["original_content_sha256"],
            "candidates": copy.deepcopy(payload["candidates"]),
            "validation": None,
            "version": 1,
            "data_revision": self.data_revision,
            "audit": [{"action": "created", "version": 1}],
        }
        self._batch_idempotency[idem] = batch_id
        self._batch_idempotency_payloads[idem] = request_fingerprint
        self._batches[batch_id] = batch
        return copy.deepcopy(batch)

    def _batch(self, batch_id: str) -> dict[str, Any]:
        batch = self._batches.get(batch_id)
        if batch is None:
            raise FiscalMCPError("batch_not_found", "Import batch was not found.")
        return batch

    def _check_version(self, batch: dict[str, Any], expected_version: int) -> None:
        if batch["version"] != expected_version:
            raise FiscalMCPError(
                "stale_batch_version",
                "Import batch changed; reload it before retrying.",
                {"expected_version": expected_version, "current_version": batch["version"]},
            )

    async def get_import_batch(self, batch_id: str) -> dict[str, Any]:
        return copy.deepcopy(self._batch(batch_id))

    async def validate_import_batch(self, batch_id: str, expected_version: int) -> dict[str, Any]:
        batch = self._batch(batch_id)
        self._check_version(batch, expected_version)
        seen: set[tuple[Any, ...]] = set()
        duplicates: list[str] = []
        missing: list[dict[str, Any]] = []
        for candidate in batch["candidates"]:
            key = (candidate.get("occurred_at"), candidate.get("amount_minor"), candidate.get("title"))
            if key in seen:
                duplicates.append(candidate["client_id"])
            seen.add(key)
            fields = [field for field in ("account_id", "category_id") if not candidate.get(field)]
            if fields:
                missing.append({"client_id": candidate["client_id"], "fields": fields})
        validation = {"duplicates": duplicates, "missing_fields": missing, "writable_count": len(batch["candidates"]) - len(duplicates) - len(missing), "validated_at": "fixture"}
        batch["validation"] = validation
        batch["status"] = BatchStatus.VALIDATED.value
        batch["version"] += 1
        batch["audit"].append({"action": "validated", "version": batch["version"]})
        return copy.deepcopy(batch)

    async def commit_import_batch(
        self, batch_id: str, expected_version: int, confirmation_token: str, idempotency_key: str
    ) -> dict[str, Any]:
        replay = self._commit_idempotency.get(idempotency_key)
        if replay is not None:
            if self._commit_idempotency_context.get(idempotency_key) != (batch_id, expected_version):
                raise FiscalMCPError("idempotency_conflict", "The commit idempotency key was already used for another batch.")
            return copy.deepcopy(replay)
        batch = self._batch(batch_id)
        self._check_version(batch, expected_version)
        if batch["status"] != BatchStatus.VALIDATED.value:
            raise FiscalMCPError("batch_not_validated", "Validate the import batch before committing it.")
        validation = batch["validation"] or {}
        if validation.get("missing_fields") or validation.get("duplicates"):
            raise FiscalMCPError("batch_has_conflicts", "Resolve missing fields and duplicates before committing.")
        self.data_revision += 1
        transactions = []
        for candidate in batch["candidates"]:
            transaction_key = f"{batch_id}:{candidate['client_id']}"
            transaction = {"id": f"tx-{uuid.uuid5(uuid.NAMESPACE_URL, transaction_key)}", **copy.deepcopy(candidate)}
            transactions.append(transaction)
            self.ledger_items.append(transaction)
        batch["status"] = BatchStatus.COMMITTED.value
        batch["version"] += 1
        batch["data_revision"] = self.data_revision
        batch["audit"].append({"action": "committed", "version": batch["version"], "data_revision": self.data_revision})
        result = {"batch": copy.deepcopy(batch), "transactions": transactions, "skipped": [], "data_revision": self.data_revision}
        self._commit_idempotency[idempotency_key] = copy.deepcopy(result)
        self._commit_idempotency_context[idempotency_key] = (batch_id, expected_version)
        return result

    async def ignore_import_batch(self, batch_id: str, expected_version: int, reason: str | None) -> dict[str, Any]:
        batch = self._batch(batch_id)
        self._check_version(batch, expected_version)
        if batch["status"] in {BatchStatus.COMMITTED.value, BatchStatus.IGNORED.value}:
            return copy.deepcopy(batch)
        batch["status"] = BatchStatus.IGNORED.value
        batch["version"] += 1
        batch["audit"].append({"action": "ignored", "version": batch["version"], "reason": reason})
        return copy.deepcopy(batch)

    async def export_report(self, period_kind: str, period: str, export_format: str) -> dict[str, Any]:
        report = self.monthly_reports.get(period) if period_kind == "month" else self.yearly_reports.get(period)
        return {"format": export_format, "period": period, "data_revision": self.data_revision, "content": json.dumps(report or {}, ensure_ascii=False)}

