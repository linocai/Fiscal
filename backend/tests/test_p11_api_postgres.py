import asyncio
from datetime import timedelta
from os import environ

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import Settings
from fiscal_api.core.device_tokens import generate_device_token, token_digest, token_fingerprint
from fiscal_api.core.time import utc_now
from fiscal_api.db.models.security import DeviceToken, DeviceTokenRole, DeviceTokenStatus
from fiscal_api.db.session import create_session_factory
from fiscal_api.main import create_app

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
PEPPER = "p11-test-pepper-that-is-at-least-32-bytes"


async def _seed_operator(raw_token: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = create_session_factory(engine)
    async with factory() as session:
        await session.execute(text("TRUNCATE access_keys, access_credential CASCADE"))
        await session.execute(text("TRUNCATE device_tokens CASCADE"))
        now = utc_now()
        session.add(
            DeviceToken(
                label="P11 operator",
                role=DeviceTokenRole.OPERATOR,
                status=DeviceTokenStatus.ACTIVE,
                token_digest=token_digest(raw_token, PEPPER),
                fingerprint=token_fingerprint(raw_token),
                pepper_version=1,
                version=1,
                activated_at=now,
                created_at=now,
                updated_at=now,
            )
        )
        await session.commit()
    await engine.dispose()


async def _clear_tokens() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(text("TRUNCATE access_keys, access_credential CASCADE"))
        await connection.execute(text("TRUNCATE device_tokens CASCADE"))
    await engine.dispose()


async def _insert_unusable_tokens() -> tuple[str, str]:
    assert TEST_DATABASE_URL is not None
    expired_raw = generate_device_token()
    revoked_raw = generate_device_token()
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = create_session_factory(engine)
    async with factory() as session:
        now = utc_now()
        session.add_all(
            [
                DeviceToken(
                    label="Expired",
                    role=DeviceTokenRole.DEVICE,
                    status=DeviceTokenStatus.ACTIVE,
                    token_digest=token_digest(expired_raw, PEPPER),
                    fingerprint=token_fingerprint(expired_raw),
                    pepper_version=1,
                    version=1,
                    activated_at=now - timedelta(days=2),
                    expires_at=now - timedelta(days=1),
                    created_at=now - timedelta(days=2),
                    updated_at=now - timedelta(days=1),
                ),
                DeviceToken(
                    label="Revoked",
                    role=DeviceTokenRole.DEVICE,
                    status=DeviceTokenStatus.REVOKED,
                    token_digest=token_digest(revoked_raw, PEPPER),
                    fingerprint=token_fingerprint(revoked_raw),
                    pepper_version=1,
                    version=2,
                    activated_at=now - timedelta(days=2),
                    revoked_at=now - timedelta(days=1),
                    created_at=now - timedelta(days=2),
                    updated_at=now - timedelta(days=1),
                ),
            ]
        )
        await session.commit()
    await engine.dispose()
    return expired_raw, revoked_raw


def _settings(**limits: int) -> Settings:
    assert TEST_DATABASE_URL is not None
    return Settings(
        environment="production",
        database_url=TEST_DATABASE_URL,
        token_pepper=SecretStr(PEPPER),
        **limits,
    )


def test_p11_deployed_app_fails_fast_without_an_active_token() -> None:
    asyncio.run(_clear_tokens())
    app = create_app(settings=_settings())
    with pytest.raises(RuntimeError, match="at least one active"):
        with TestClient(app):
            pass


def test_p11_transition_device_token_and_operations_status() -> None:
    operator_raw = generate_device_token()
    asyncio.run(_seed_operator(operator_raw))
    app = create_app(settings=_settings())
    operator_auth = {"Authorization": f"Bearer {operator_raw}"}

    with TestClient(app) as client:
        # Before a passphrase is set the device token still reaches protected routes.
        assert client.get("/api/v1/accounts", headers=operator_auth).status_code == 200

        operations_response = client.get("/api/v1/system/operations-status", headers=operator_auth)
        assert operations_response.status_code == 200, operations_response.text
        operations = operations_response.json()
        assert operations["database"] == "ready"
        assert operations["schema_state"] == "unknown"
        assert operations["backup"]["state"] == "unavailable"


def test_p11_database_rate_limits_and_uniform_invalid_credentials() -> None:
    operator_raw = generate_device_token()
    asyncio.run(_seed_operator(operator_raw))
    app = create_app(
        settings=_settings(
            rate_limit_read_per_minute=1,
            rate_limit_failed_auth_per_minute=2,
        )
    )
    auth = {"Authorization": f"Bearer {operator_raw}"}
    with TestClient(app) as client:
        assert client.get("/api/v1/system/status", headers=auth).status_code == 200
        limited = client.get("/api/v1/system/status", headers=auth)
        assert limited.status_code == 429
        assert limited.json()["error"]["code"] == "rate_limit_exceeded"
        assert int(limited.headers["Retry-After"]) >= 1

        missing = client.get("/api/v1/accounts")
        assert missing.status_code == 401
        assert missing.json()["error"]["code"] == "authentication_required"
        malformed = client.get("/api/v1/accounts", headers={"Authorization": "Bearer malformed"})
        assert malformed.status_code == 401
        assert malformed.json()["error"]["code"] == "invalid_device_token"
        failed_limit = client.get(
            "/api/v1/accounts", headers={"Authorization": "Bearer another-malformed"}
        )
        assert failed_limit.status_code == 429
        assert failed_limit.json()["error"]["code"] == "rate_limit_exceeded"


def test_p11_expired_revoked_malformed_and_oversized_tokens_are_indistinguishable() -> None:
    operator_raw = generate_device_token()
    asyncio.run(_seed_operator(operator_raw))
    expired_raw, revoked_raw = asyncio.run(_insert_unusable_tokens())
    app = create_app(settings=_settings())
    supplied = [expired_raw, revoked_raw, "malformed", f"fiscal_dt_v1_{'x' * 1000}"]
    with TestClient(app) as client:
        for raw_token in supplied:
            response = client.get(
                "/api/v1/accounts", headers={"Authorization": f"Bearer {raw_token}"}
            )
            assert response.status_code == 401
            assert response.json()["error"]["code"] == "invalid_device_token"
