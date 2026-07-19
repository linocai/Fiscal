"""Personal access passphrase / access-key authentication against PostgreSQL.

Covers the P19 migration matrix: transition device tokens keep working until a
passphrase is set, ``initialize`` (device-token authorized) permanently closes
the device layer, login mints access keys, a passphrase change bumps the
generation and globally revokes old keys, failed logins consume the failed-auth
bucket, and the startup guard accepts a credential with no active device token.
"""

import asyncio
from collections.abc import Iterator
from os import environ
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from pydantic import SecretStr
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.device_tokens import generate_device_token, token_digest, token_fingerprint
from fiscal_api.core.time import utc_now
from fiscal_api.db.models.security import DeviceToken, DeviceTokenRole, DeviceTokenStatus
from fiscal_api.db.session import create_session_factory
from fiscal_api.main import create_app
from fiscal_api.services.access import AccessService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")
BACKEND_ROOT = Path(__file__).resolve().parents[1]
PEPPER = "p19-test-pepper-that-is-at-least-32-bytes"
PASSPHRASE = "correct horse battery"  # noqa: S105 -- test passphrase, not a real secret
NEW_PASSPHRASE = "another good passphrase"  # noqa: S105 -- test passphrase, not a real secret


def _config() -> Config:
    result = Config(str(BACKEND_ROOT / "alembic.ini"))
    result.set_main_option("script_location", str(BACKEND_ROOT / "alembic"))
    return result


def _settings(**overrides: object) -> Settings:
    assert TEST_DATABASE_URL is not None
    return Settings(
        environment="production",
        database_url=TEST_DATABASE_URL,
        token_pepper=SecretStr(PEPPER),
        passphrase_kdf_iterations=100_000,
        **overrides,  # type: ignore[arg-type]
    )


async def _reset_schema() -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as connection:
        await connection.execute(text("TRUNCATE access_keys, access_credential CASCADE"))
        await connection.execute(text("TRUNCATE device_tokens CASCADE"))
    await engine.dispose()


async def _seed_operator(raw_token: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = create_session_factory(engine)
    async with factory() as session:
        now = utc_now()
        session.add(
            DeviceToken(
                label="P19 operator",
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


async def _seed_credential(passphrase: str) -> None:
    assert TEST_DATABASE_URL is not None
    engine = create_async_engine(TEST_DATABASE_URL)
    factory = create_session_factory(engine)
    async with factory() as session:
        await AccessService(session, _settings()).initialize(passphrase)
    await engine.dispose()


@pytest.fixture(scope="module", autouse=True)
def _migrated() -> Iterator[None]:
    assert TEST_DATABASE_URL is not None
    previous = environ.get("FISCAL_DATABASE_URL")
    environ["FISCAL_DATABASE_URL"] = TEST_DATABASE_URL
    get_settings.cache_clear()
    try:
        command.upgrade(_config(), "head")
        yield
    finally:
        if previous is None:
            environ.pop("FISCAL_DATABASE_URL", None)
        else:
            environ["FISCAL_DATABASE_URL"] = previous
        get_settings.cache_clear()


def _bearer(raw: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {raw}"}


def test_transition_initialize_closes_device_layer_and_login_flow() -> None:
    asyncio.run(_reset_schema())
    operator_raw = generate_device_token()
    asyncio.run(_seed_operator(operator_raw))
    app = create_app(settings=_settings())

    with TestClient(app) as client:
        # Transition: the existing device token authenticates protected routes.
        assert client.get("/api/v1/accounts", headers=_bearer(operator_raw)).status_code == 200
        status = client.get("/api/v1/auth/status", headers=_bearer(operator_raw))
        assert status.status_code == 200, status.text
        assert status.json()["authentication_mode"] == "transition_device_token"
        assert status.json()["passphrase_set"] is False

        # Set the passphrase using the device token (transition bridge).
        initialized = client.post(
            "/api/v1/auth/passphrase/initialize",
            headers=_bearer(operator_raw),
            json={"passphrase": PASSPHRASE},
        )
        assert initialized.status_code == 200, initialized.text
        first_key = initialized.json()["access_key"]
        assert first_key.startswith("fiscal_ak_v1_")
        assert initialized.json()["credential_generation"] == 1

        # The device layer is permanently closed: the same token is now rejected.
        closed = client.get("/api/v1/accounts", headers=_bearer(operator_raw))
        assert closed.status_code == 401
        assert closed.json()["error"]["code"] == "invalid_access_key"

        # The freshly minted access key authenticates protected routes.
        assert client.get("/api/v1/accounts", headers=_bearer(first_key)).status_code == 200

        # Login with the passphrase mints another access key.
        session = client.post("/api/v1/auth/session", json={"passphrase": PASSPHRASE})
        assert session.status_code == 200, session.text
        session_key = session.json()["access_key"]
        assert session_key != first_key
        assert client.get("/api/v1/accounts", headers=_bearer(session_key)).status_code == 200

        # Wrong passphrase is rejected without leaking anything.
        wrong = client.post("/api/v1/auth/session", json={"passphrase": "not the passphrase"})
        assert wrong.status_code == 401
        assert wrong.json()["error"]["code"] == "invalid_passphrase"
        assert PASSPHRASE not in wrong.text

        # Re-initialize is refused once a credential exists.
        again = client.post(
            "/api/v1/auth/passphrase/initialize",
            headers=_bearer(session_key),
            json={"passphrase": PASSPHRASE},
        )
        assert again.status_code == 409
        assert again.json()["error"]["code"] == "passphrase_already_set"

        # /auth/status reports the passphrase mode and never returns a secret.
        after = client.get("/api/v1/auth/status", headers=_bearer(session_key))
        body = after.json()
        assert body["authentication_mode"] == "passphrase"
        assert body["passphrase_set"] is True
        assert body["credential_generation"] == 1
        assert body["active_access_key_count"] >= 2
        # No access-key value (the prefixed secret) and no passphrase is echoed.
        assert "fiscal_ak_v1_" not in after.text
        assert PASSPHRASE not in after.text


def test_change_passphrase_bumps_generation_and_revokes_old_keys() -> None:
    asyncio.run(_reset_schema())
    asyncio.run(_seed_credential(PASSPHRASE))
    app = create_app(settings=_settings())

    with TestClient(app) as client:
        old_key = client.post("/api/v1/auth/session", json={"passphrase": PASSPHRASE}).json()[
            "access_key"
        ]
        assert client.get("/api/v1/accounts", headers=_bearer(old_key)).status_code == 200

        # Wrong old passphrase is rejected.
        wrong = client.post(
            "/api/v1/auth/passphrase/change",
            headers=_bearer(old_key),
            json={"old_passphrase": "incorrect passphrase", "new_passphrase": NEW_PASSPHRASE},
        )
        assert wrong.status_code == 401
        assert wrong.json()["error"]["code"] == "invalid_passphrase"

        changed = client.post(
            "/api/v1/auth/passphrase/change",
            headers=_bearer(old_key),
            json={"old_passphrase": PASSPHRASE, "new_passphrase": NEW_PASSPHRASE},
        )
        assert changed.status_code == 200, changed.text
        new_key = changed.json()["access_key"]
        assert changed.json()["credential_generation"] == 2

        # Generation bump globally revokes every prior access key.
        revoked = client.get("/api/v1/accounts", headers=_bearer(old_key))
        assert revoked.status_code == 401
        assert revoked.json()["error"]["code"] == "invalid_access_key"
        assert client.get("/api/v1/accounts", headers=_bearer(new_key)).status_code == 200

        # The old passphrase no longer logs in; the new one does.
        assert (
            client.post("/api/v1/auth/session", json={"passphrase": PASSPHRASE}).status_code == 401
        )
        relogin = client.post("/api/v1/auth/session", json={"passphrase": NEW_PASSPHRASE})
        assert relogin.status_code == 200, relogin.text


def test_session_before_passphrase_set_is_conflict() -> None:
    asyncio.run(_reset_schema())
    asyncio.run(_seed_operator(generate_device_token()))
    app = create_app(settings=_settings())
    with TestClient(app) as client:
        response = client.post("/api/v1/auth/session", json={"passphrase": PASSPHRASE})
        assert response.status_code == 409
        assert response.json()["error"]["code"] == "passphrase_not_set"


def test_failed_login_consumes_failed_auth_bucket() -> None:
    asyncio.run(_reset_schema())
    asyncio.run(_seed_credential(PASSPHRASE))
    app = create_app(settings=_settings(rate_limit_failed_auth_per_minute=2))
    with TestClient(app) as client:
        for _ in range(2):
            assert (
                client.post(
                    "/api/v1/auth/session", json={"passphrase": "wrong passphrase"}
                ).status_code
                == 401
            )
        limited = client.post("/api/v1/auth/session", json={"passphrase": "wrong passphrase"})
        assert limited.status_code == 429
        assert limited.json()["error"]["code"] == "rate_limit_exceeded"


def test_startup_guard_accepts_credential_without_active_device_token() -> None:
    asyncio.run(_reset_schema())
    asyncio.run(_seed_credential(PASSPHRASE))
    # No active device token exists, only the credential: the app must still boot.
    app = create_app(settings=_settings())
    with TestClient(app) as client:
        login = client.post("/api/v1/auth/session", json={"passphrase": PASSPHRASE})
        assert login.status_code == 200, login.text
