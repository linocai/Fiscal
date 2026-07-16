import asyncio

import pytest
from pydantic import SecretStr, ValidationError

from fiscal_api.core.config import Settings
from fiscal_api.core.device_tokens import (
    TOKEN_PREFIX,
    generate_device_token,
    is_well_formed_database_token,
    token_digest,
    token_fingerprint,
)
from fiscal_api.core.errors import APIError
from fiscal_api.core.rate_limit import RateLimiter


def test_database_device_token_is_random_hashed_and_fingerprinted() -> None:
    first = generate_device_token()
    second = generate_device_token()

    assert first.startswith(TOKEN_PREFIX)
    assert is_well_formed_database_token(first)
    assert first != second
    assert len(token_digest(first, "p" * 32)) == 32
    assert token_digest(first, "p" * 32) != token_digest(first, "q" * 32)
    assert len(token_fingerprint(first)) == 12
    assert not is_well_formed_database_token("x" * 10_000)


def test_deployed_settings_require_database_auth_and_strong_pepper() -> None:
    with pytest.raises(ValidationError, match="at least 32"):
        Settings(environment="production")
    with pytest.raises(ValidationError, match="forbidden"):
        Settings(
            environment="production",
            device_token=SecretStr("legacy-token-that-must-not-be-deployed"),
            token_pepper=SecretStr("p" * 32),
        )
    settings = Settings(environment="production", token_pepper=SecretStr("p" * 32))
    assert settings.uses_database_device_tokens


def test_token_bucket_returns_stable_retry_after() -> None:
    settings = Settings(environment="test", rate_limit_read_per_minute=1)
    limiter = RateLimiter(settings)

    async def exercise() -> None:
        await limiter.check_authenticated("device", "GET", "/api/v1/accounts")
        with pytest.raises(APIError) as raised:
            await limiter.check_authenticated("device", "GET", "/api/v1/accounts")
        assert raised.value.status_code == 429
        assert raised.value.code == "rate_limit_exceeded"
        assert int(raised.value.headers["Retry-After"]) >= 1

    asyncio.run(exercise())
