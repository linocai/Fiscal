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
            device_token=SecretStr("p8-api-token"),
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


def test_p8_settings_reject_unsafe_client_relaxation() -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(
            environment="test",
            database_url=TEST_DATABASE_URL,
            device_token=SecretStr("p8-settings-token"),
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
                "auto_execute_limit_minor": 100_001,
                "minimum_confidence_bps": 8_999,
                "expected_version": body["version"],
            },
        )
        assert relaxed.status_code == 422
