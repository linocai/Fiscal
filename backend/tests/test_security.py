import pytest
from fastapi.testclient import TestClient

RESOURCE_ID = "00000000-0000-0000-0000-000000000001"


def test_system_status_requires_device_token(client: TestClient) -> None:
    response = client.get("/api/v1/system/status")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "authentication_required"


def test_p2_routes_require_device_token(client: TestClient) -> None:
    assert client.get("/api/v1/accounts").json()["error"]["code"] == "authentication_required"
    assert client.get("/api/v1/categories").json()["error"]["code"] == "authentication_required"


def test_system_status_rejects_invalid_device_token(client: TestClient) -> None:
    response = client.get(
        "/api/v1/system/status",
        headers={"Authorization": "Bearer incorrect"},
    )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_device_token"


@pytest.mark.parametrize(
    ("method", "path", "body"),
    [
        ("GET", "/api/v1/accounts", None),
        ("POST", "/api/v1/accounts", {}),
        ("PUT", "/api/v1/accounts/order", {"ordered_ids": []}),
        ("PATCH", f"/api/v1/accounts/{RESOURCE_ID}", {}),
        ("POST", f"/api/v1/accounts/{RESOURCE_ID}/archive", {}),
        ("GET", "/api/v1/categories", None),
        ("POST", "/api/v1/categories", {}),
        ("PUT", "/api/v1/categories/order", {"parent_id": None, "ordered_ids": []}),
        ("PATCH", f"/api/v1/categories/{RESOURCE_ID}", {}),
        ("POST", f"/api/v1/categories/{RESOURCE_ID}/merge", {}),
        ("POST", f"/api/v1/categories/{RESOURCE_ID}/split", {}),
        ("GET", "/api/v1/transactions", None),
        ("POST", "/api/v1/transactions", {}),
        ("GET", "/api/v1/transactions/summary", None),
        ("GET", "/api/v1/transactions/export.csv", None),
        ("POST", "/api/v1/transactions/bulk-category", {}),
        ("GET", f"/api/v1/transactions/{RESOURCE_ID}", None),
        ("PUT", f"/api/v1/transactions/{RESOURCE_ID}", {}),
        ("POST", f"/api/v1/transactions/{RESOURCE_ID}/void", {}),
        ("POST", f"/api/v1/transactions/{RESOURCE_ID}/restore", {}),
        ("GET", "/api/v1/credit-accounts", None),
        ("GET", f"/api/v1/credit-accounts/{RESOURCE_ID}", None),
        ("GET", f"/api/v1/credit-accounts/{RESOURCE_ID}/cycles", None),
        ("GET", f"/api/v1/credit-cycles/{RESOURCE_ID}", None),
        ("GET", f"/api/v1/credit-cycles/{RESOURCE_ID}/transactions", None),
        ("GET", "/api/v1/ai/settings", None),
        ("PUT", "/api/v1/ai/settings", {}),
        ("GET", "/api/v1/ai/proposals", None),
        ("POST", "/api/v1/ai/proposals", {}),
        ("GET", f"/api/v1/ai/proposals/{RESOURCE_ID}", None),
        ("PUT", f"/api/v1/ai/proposals/{RESOURCE_ID}", {}),
        ("POST", f"/api/v1/ai/proposals/{RESOURCE_ID}/execute", {}),
        ("POST", f"/api/v1/ai/proposals/{RESOURCE_ID}/ignore", {}),
        ("POST", f"/api/v1/ai/proposals/{RESOURCE_ID}/retry", {}),
        ("POST", f"/api/v1/ai/proposals/{RESOURCE_ID}/undo", {}),
    ],
)
def test_p2_route_matrix_rejects_missing_token_before_database_access(
    client: TestClient,
    method: str,
    path: str,
    body: dict[str, object] | None,
) -> None:
    response = client.request(method, path, json=body)

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "authentication_required"
    assert response.json()["error"]["request_id"] == response.headers["X-Request-ID"]


@pytest.mark.parametrize(
    ("path", "body"),
    [
        (
            f"/api/v1/accounts/{RESOURCE_ID}",
            {"expected_version": 1, "name": None},
        ),
        (
            f"/api/v1/categories/{RESOURCE_ID}",
            {"expected_version": 1, "direction": None},
        ),
    ],
)
def test_patch_rejects_explicit_null_for_required_fields(
    client: TestClient,
    path: str,
    body: dict[str, object],
) -> None:
    response = client.patch(
        path,
        json=body,
        headers={"Authorization": "Bearer test-device-token"},
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_account_create_rejects_json_floating_point_money(client: TestClient) -> None:
    response = client.post(
        "/api/v1/accounts",
        json={
            "name": "现金",
            "kind": "cash",
            "opening_balance_minor": 12.5,
        },
        headers={"Authorization": "Bearer test-device-token"},
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


@pytest.mark.parametrize(
    "payload",
    [
        {"name": "极大现金", "kind": "cash", "opening_balance_minor": 2**63},
        {
            "name": "极大额度",
            "kind": "credit",
            "opening_balance_minor": 0,
            "credit_limit_minor": 2**63,
            "statement_day": 10,
            "due_day": 20,
        },
        {
            "name": "零额度",
            "kind": "credit",
            "opening_balance_minor": 0,
            "credit_limit_minor": 0,
            "statement_day": 10,
            "due_day": 20,
        },
    ],
)
def test_account_money_rejects_out_of_range_or_nonpositive_limit(
    client: TestClient, payload: dict[str, object]
) -> None:
    response = client.post(
        "/api/v1/accounts",
        json=payload,
        headers={"Authorization": "Bearer test-device-token"},
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_system_status_returns_operational_contract(client: TestClient) -> None:
    response = client.get(
        "/api/v1/system/status",
        headers={"Authorization": "Bearer test-device-token"},
    )

    assert response.status_code == 200
    assert response.json() == {
        "service": "fiscal-api",
        "version": "0.1.0",
        "environment": "test",
        "status": "operational",
        "database": "ready",
        "currency": "CNY",
        "business_timezone": "Asia/Shanghai",
        "timestamp": response.json()["timestamp"],
    }
    assert response.json()["timestamp"].endswith("Z")
