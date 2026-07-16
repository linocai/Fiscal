import asyncio
from datetime import timedelta
from os import environ

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr
from sqlalchemy import select, text
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
        await connection.execute(text("TRUNCATE device_tokens CASCADE"))
    await engine.dispose()


async def _database_contains_raw_token(raw_token: str) -> bool:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = create_session_factory(engine)
    async with factory() as session:
        rows = list(await session.scalars(select(DeviceToken)))
        found = any(raw_token.encode() in row.token_digest for row in rows)
    await engine.dispose()
    return found


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


def test_p11_issue_activate_rotate_revoke_and_roles() -> None:
    operator_raw = generate_device_token()
    asyncio.run(_seed_operator(operator_raw))
    app = create_app(settings=_settings())
    operator_auth = {"Authorization": f"Bearer {operator_raw}"}

    with TestClient(app) as client:
        status_response = client.get("/api/v1/system/security-status", headers=operator_auth)
        assert status_response.status_code == 200, status_response.text
        operator = status_response.json()["current_device"]
        assert operator["role"] == "operator"
        assert status_response.json()["token_counts"] == {"active": 1, "pending": 0}

        operations_response = client.get("/api/v1/system/operations-status", headers=operator_auth)
        assert operations_response.status_code == 200, operations_response.text
        operations = operations_response.json()
        assert operations["database"] == "ready"
        assert operations["alembic_revision"] == "20260716_0010"
        assert operations["schema_state"] == "unknown"
        assert operations["backup"]["state"] == "unavailable"

        issued_response = client.post(
            "/api/v1/device-tokens", headers=operator_auth, json={"label": "My iPhone"}
        )
        assert issued_response.status_code == 201, issued_response.text
        issued = issued_response.json()
        device_raw = issued["device_token"]
        device_id = issued["token"]["id"]
        assert issued["token"]["status"] == "pending"
        assert device_raw not in issued["token"].values()
        assert not asyncio.run(_database_contains_raw_token(device_raw))

        pending_denied = client.get(
            "/api/v1/accounts", headers={"Authorization": f"Bearer {device_raw}"}
        )
        assert pending_denied.status_code == 401
        assert pending_denied.json()["error"]["code"] == "invalid_device_token"

        activated = client.post(
            "/api/v1/device-tokens/activate",
            headers={"Authorization": f"Bearer {device_raw}"},
            json={"expected_version": 1},
        )
        assert activated.status_code == 200, activated.text
        assert activated.json()["token"]["status"] == "active"
        assert activated.json()["revoked_predecessor_id"] is None
        device_auth = {"Authorization": f"Bearer {device_raw}"}

        visible = client.get("/api/v1/device-tokens", headers=device_auth)
        assert [item["id"] for item in visible.json()["items"]] == [device_id]
        forbidden_issue = client.post(
            "/api/v1/device-tokens", headers=device_auth, json={"label": "Not allowed"}
        )
        assert forbidden_issue.status_code == 403

        stale_rotation = client.post(
            "/api/v1/device-tokens/current/rotate",
            headers=device_auth,
            json={"expected_version": 1},
        )
        assert stale_rotation.status_code == 409
        assert stale_rotation.json()["error"]["code"] == "stale_version"
        rotation = client.post(
            "/api/v1/device-tokens/current/rotate",
            headers=device_auth,
            json={"expected_version": 2},
        )
        assert rotation.status_code == 201, rotation.text
        successor_raw = rotation.json()["device_token"]
        assert client.get("/api/v1/system/security-status", headers=device_auth).status_code == 200

        successor = client.post(
            "/api/v1/device-tokens/activate",
            headers={"Authorization": f"Bearer {successor_raw}"},
            json={"expected_version": 1},
        )
        assert successor.status_code == 200, successor.text
        assert successor.json()["revoked_predecessor_id"] == device_id
        assert client.get("/api/v1/accounts", headers=device_auth).status_code == 401
        successor_auth = {"Authorization": f"Bearer {successor_raw}"}
        assert client.get("/api/v1/device-tokens", headers=successor_auth).status_code == 200

        revoked = client.post(
            f"/api/v1/device-tokens/{successor.json()['token']['id']}/revoke",
            headers=operator_auth,
            json={"expected_version": 2},
        )
        assert revoked.status_code == 200, revoked.text
        assert revoked.json()["token"]["status"] == "revoked"
        assert client.get("/api/v1/accounts", headers=successor_auth).status_code == 401

        last_operator = client.post(
            f"/api/v1/device-tokens/{operator['id']}/revoke",
            headers=operator_auth,
            json={"expected_version": operator["version"]},
        )
        assert last_operator.status_code == 409
        assert last_operator.json()["error"]["code"] == "last_operator_required"


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
