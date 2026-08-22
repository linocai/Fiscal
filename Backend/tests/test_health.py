from fastapi.testclient import TestClient

from fiscal_api.core.middleware import REQUEST_ID_HEADER


def test_live_health(client: TestClient) -> None:
    response = client.get("/api/v1/health/live", headers={REQUEST_ID_HEADER: "ios-device-1"})

    assert response.status_code == 200
    assert response.json() == {"status": "live"}
    assert response.headers[REQUEST_ID_HEADER] == "ios-device-1"


def test_invalid_request_id_is_replaced(client: TestClient) -> None:
    response = client.get("/api/v1/health/live", headers={REQUEST_ID_HEADER: "not valid!"})

    assert response.status_code == 200
    assert response.headers[REQUEST_ID_HEADER] != "not valid!"


def test_ready_health(client: TestClient) -> None:
    response = client.get("/api/v1/health/ready")

    assert response.status_code == 200
    assert response.json() == {"status": "ready", "database": "ready"}
