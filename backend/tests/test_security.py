from fastapi.testclient import TestClient


def test_system_status_requires_device_token(client: TestClient) -> None:
    response = client.get("/api/v1/system/status")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "authentication_required"


def test_system_status_rejects_invalid_device_token(client: TestClient) -> None:
    response = client.get(
        "/api/v1/system/status",
        headers={"Authorization": "Bearer incorrect"},
    )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_device_token"


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
