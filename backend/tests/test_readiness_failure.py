from fastapi.testclient import TestClient
from pydantic import SecretStr

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app


async def unavailable_database() -> None:
    raise OSError("database is offline")


def test_ready_reports_unavailable_without_leaking_exception() -> None:
    settings = Settings(environment="test", device_token=SecretStr("test-device-token"))
    app = create_app(settings=settings, readiness_check=unavailable_database)

    with TestClient(app) as client:
        response = client.get("/api/v1/health/ready")

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "database_unavailable"
    assert response.json()["error"]["request_id"] == response.headers["X-Request-ID"]
    assert "offline" not in response.text
