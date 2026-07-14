from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app


async def ready_database() -> None:
    return None


@pytest.fixture
def settings() -> Settings:
    return Settings(
        environment="test",
        database_url="postgresql+asyncpg://unused:unused@localhost/unused",
        device_token=SecretStr("test-device-token"),
    )


@pytest.fixture
def client(settings: Settings) -> Iterator[TestClient]:
    app = create_app(settings=settings, readiness_check=ready_database)
    with TestClient(app) as test_client:
        yield test_client
