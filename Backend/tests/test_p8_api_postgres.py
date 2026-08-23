from datetime import UTC, datetime
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from fiscal_api.api.dependencies import get_ai_provider
from fiscal_api.api.p8_schemas import AIFieldConfidences, AIParseRequest, AIProviderResult
from fiscal_api.core.config import Settings
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


class APIFakeProvider:
    configured = True
    provider_id = "api_fake"
    model_id = "api-model"

    async def parse(self, request: AIParseRequest) -> AIProviderResult:
        account = next(item for item in request.accounts if item.kind == "debit")
        category = next(item for item in request.categories if item.direction == "expense")
        return AIProviderResult(
            kind="expense",
            amount_minor=2_000,
            occurred_at=datetime(2026, 7, 16, 4, tzinfo=UTC),
            title="API 午餐",
            account_id=account.id,
            category_id=category.id,
            confidences=AIFieldConfidences(
                kind=9_500,
                amount_minor=9_500,
                occurred_at=9_500,
                title=9_500,
                account_id=9_500,
                category_id=9_500,
            ),
            overall_confidence_bps=9_500,
            missing_fields=[],
        )


def test_p8_real_api_nested_edit_idempotency_and_queue_count() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(
            environment="test",
            database_url=TEST_DATABASE_URL,
            token_pepper=SecretStr("p8-api-provider-root-secret-32-bytes"),
        ),
        readiness_check=ready,
    )
    app.dependency_overrides[get_ai_provider] = lambda: APIFakeProvider()
    auth = {"Authorization": "Bearer p8-api-token"}
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        settings = client.get("/api/v1/ai/settings", headers=auth).json()
        disabled = client.put(
            "/api/v1/ai/settings",
            headers=auth,
            json={
                "auto_execute_enabled": False,
                "ocr_source_enabled": False,
                "shortcut_text_source_enabled": False,
                "auto_execute_limit_minor": 100_000,
                "minimum_confidence_bps": 9_000,
                "expected_version": settings["version"],
            },
        )
        assert disabled.status_code == 200
        account = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"P8 API 银行 {suffix}",
                "kind": "debit",
                "opening_balance_minor": 100_000,
            },
        )
        category = client.post(
            "/api/v1/categories",
            headers=auth,
            json={
                "name": f"P8 API 餐饮 {suffix}",
                "direction": "expense",
                "icon": "fork.knife",
                "color_hex": "#334455",
            },
        )
        assert account.status_code == category.status_code == 201
        key = str(uuid4())
        created = client.post(
            "/api/v1/ai/proposals",
            headers={**auth, "Idempotency-Key": key},
            json={"source": "text", "text": f"API 午餐 {suffix}"},
        )
        assert created.status_code == 201, created.text
        body = created.json()
        assert body["status"] == "pending"
        assert body["field_confidences"]["amount_minor"] == 9_500
        assert body["overall_confidence_bps"] == 9_500
        replay = client.post(
            "/api/v1/ai/proposals",
            headers={**auth, "Idempotency-Key": key},
            json={"source": "text", "text": f"API 午餐 {suffix}"},
        )
        assert replay.status_code == 200 and replay.json()["id"] == body["id"]

        flat = client.put(
            f"/api/v1/ai/proposals/{body['id']}",
            headers=auth,
            json={
                "kind": "expense",
                "amount_minor": 2_100,
                "occurred_at": "2026-07-16T04:00:00Z",
                "title": "错误扁平结构",
                "account_id": account.json()["id"],
                "category_id": category.json()["id"],
                "expected_version": body["version"],
            },
        )
        assert flat.status_code == 422
        edited = client.put(
            f"/api/v1/ai/proposals/{body['id']}",
            headers=auth,
            json={
                "draft": {
                    "kind": "expense",
                    "amount_minor": 2_100,
                    "occurred_at": "2026-07-16T04:00:00Z",
                    "title": "嵌套修正",
                    "account_id": account.json()["id"],
                    "category_id": category.json()["id"],
                },
                "expected_version": body["version"],
            },
        )
        assert edited.status_code == 200, edited.text
        assert edited.json()["amount_minor"] == 2_100
        queue = client.get("/api/v1/ai/proposals?status=pending", headers=auth)
        assert queue.status_code == 200
        assert queue.json()["pending_count"] >= 1
        assert any(item["id"] == body["id"] for item in queue.json()["items"])

        revision = client.get("/api/v1/data-revision", headers=auth).json()["revision"]
        deleted = client.delete(
            f"/api/v1/ai/proposals/{body['id']}?expected_version={edited.json()['version']}",
            headers=auth,
        )
        assert deleted.status_code == 204, deleted.text
        assert int(deleted.headers["X-Fiscal-Data-Revision"]) == revision + 1
        assert client.get(f"/api/v1/ai/proposals/{body['id']}", headers=auth).status_code == 404
        refreshed_queue = client.get("/api/v1/ai/proposals?status=pending", headers=auth)
        assert not any(item["id"] == body["id"] for item in refreshed_queue.json()["items"])


def test_d3_settings_and_strategy_reject_retired_automatic_execution() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(
            environment="test",
            database_url=TEST_DATABASE_URL,
            token_pepper=SecretStr("p8-settings-provider-root-secret-32-bytes"),
        ),
        readiness_check=ready,
    )
    auth = {"Authorization": "Bearer p8-settings-token"}
    with TestClient(app) as client:
        current = client.get("/api/v1/ai/settings", headers=auth)
        assert current.status_code == 200
        body = current.json()
        assert body["provider_configured"] is False
        assert body["effective_auto_execute"] is False
        relaxed = client.put(
            "/api/v1/ai/settings",
            headers=auth,
            json={
                "auto_execute_enabled": True,
                "ocr_source_enabled": False,
                "shortcut_text_source_enabled": False,
                "auto_execute_limit_minor": body["auto_execute_limit_minor"],
                "minimum_confidence_bps": body["minimum_confidence_bps"],
                "expected_version": body["version"],
            },
        )
        assert relaxed.status_code == 409
        assert relaxed.json()["error"]["code"] == "ai_auto_execute_retired"

        strategy = client.post(
            "/api/v1/ai/strategy",
            headers=auth,
            json={
                "source": None,
                "transaction_kind": None,
                "auto_execute_enabled": True,
                "auto_execute_limit_minor": body["auto_execute_limit_minor"],
                "minimum_confidence_bps": body["minimum_confidence_bps"],
                "minimum_sample_size": 30,
                "change_reason": "legacy client enable attempt",
                "confirm_relaxation": True,
            },
        )
        assert strategy.status_code == 409
        assert strategy.json()["error"]["code"] == "ai_auto_execute_retired"

        first_scope_relaxation = client.post(
            "/api/v1/ai/strategy",
            headers=auth,
            json={
                "source": "text",
                "transaction_kind": "expense",
                "auto_execute_enabled": False,
                "auto_execute_limit_minor": body["auto_execute_limit_minor"],
                "minimum_confidence_bps": body["minimum_confidence_bps"],
                "minimum_sample_size": 1,
                "change_reason": "first scope sample relaxation",
            },
        )
        assert first_scope_relaxation.status_code == 409
        assert first_scope_relaxation.json()["error"]["code"] == "ai_auto_execute_retired"

        text_scope = client.post(
            "/api/v1/ai/strategy",
            headers=auth,
            json={
                "source": "text",
                "transaction_kind": "expense",
                "auto_execute_enabled": False,
                "auto_execute_limit_minor": 80_000,
                "minimum_confidence_bps": 9_200,
                "minimum_sample_size": 40,
                "change_reason": "tight text scope",
            },
        )
        assert text_scope.status_code == 200, text_scope.text
        assert text_scope.json()["auto_execute_enabled"] is False
        assert text_scope.json()["minimum_sample_size"] == 40

        # This is looser than the unrelated text scope but remains tighter
        # than global settings, proving cross-scope rows do not set its base.
        ocr_scope = client.post(
            "/api/v1/ai/strategy",
            headers=auth,
            json={
                "source": "ocr",
                "transaction_kind": "expense",
                "auto_execute_enabled": False,
                "auto_execute_limit_minor": 90_000,
                "minimum_confidence_bps": 9_100,
                "minimum_sample_size": 30,
                "change_reason": "independent OCR scope",
            },
        )
        assert ocr_scope.status_code == 200, ocr_scope.text
        assert ocr_scope.json()["auto_execute_enabled"] is False

        same_scope_relaxation = client.post(
            "/api/v1/ai/strategy",
            headers=auth,
            json={
                "source": "text",
                "transaction_kind": "expense",
                "auto_execute_enabled": False,
                "auto_execute_limit_minor": 80_000,
                "minimum_confidence_bps": 9_200,
                "minimum_sample_size": 30,
                "change_reason": "same scope sample relaxation",
            },
        )
        assert same_scope_relaxation.status_code == 409
        assert same_scope_relaxation.json()["error"]["code"] == "ai_auto_execute_retired"

        policies = client.get("/api/v1/ai/strategy", headers=auth)
        assert policies.status_code == 200
        assert all(item["auto_execute_enabled"] is False for item in policies.json())
