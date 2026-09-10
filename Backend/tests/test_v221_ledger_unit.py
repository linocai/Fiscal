import asyncio
from threading import Event
from uuid import uuid4

import pytest

from fiscal_api.core.config import Settings
from fiscal_api.core.errors import APIError
from fiscal_api.core.mapping_generation import backfill_mapping_generations
from fiscal_api.core.rate_limit import RateLimiter
from fiscal_api.services.access import _run_kdf


def test_mapping_migration_invalidates_legacy_aba_and_preserves_receipts():
    transactions = [{"id": "a"}, {"id": "b"}, {"id": "c"}]
    mappings = [{"transaction_id": "a", "version": 1}]
    operations = [
        {"receipt": {"mapping": {"transaction_id": "a", "mapping_version": 8}}},
        {"receipt": {"mapping": {"transaction_id": "b", "mapping_version": 4}}},
    ]
    backfill_mapping_generations(transactions, mappings, operations)
    assert [row["merchant_mapping_generation"] for row in transactions] == [9, 5, 0]
    assert mappings[0]["version"] == 9
    assert operations[0]["receipt"]["mapping"]["mapping_version"] == 8


async def test_passphrase_attempt_budget_is_separate_and_consumed_before_work():
    limiter = RateLimiter(Settings(rate_limit_failed_auth_per_minute=1))
    await limiter.check_passphrase_attempt("client")
    with pytest.raises(APIError) as error:
        await limiter.check_passphrase_attempt("client")
    assert error.value.status_code == 429
    await limiter.check_failed_auth("client")


async def test_kdf_cancel_does_not_release_running_capacity_or_block_loop():
    entered, release = asyncio.Event(), Event()
    loop = asyncio.get_running_loop()

    def work():
        loop.call_soon_threadsafe(entered.set)
        release.wait(timeout=5)
        return True

    tasks = [asyncio.create_task(_run_kdf(work)) for _ in range(4)]
    try:
        await asyncio.wait_for(entered.wait(), timeout=2)
        await asyncio.sleep(0)
        with pytest.raises(APIError):
            await _run_kdf(work)
        tasks[0].cancel()
        await asyncio.sleep(0)
        with pytest.raises(APIError):
            await _run_kdf(work)
    finally:
        release.set()
        await asyncio.gather(*tasks, return_exceptions=True)


async def test_login_route_rejects_exhausted_attempt_without_kdf():
    from types import SimpleNamespace
    from unittest.mock import AsyncMock

    from starlette.requests import Request

    from fiscal_api.api.auth_schemas import SessionRequest
    from fiscal_api.api.routes.auth import create_session

    limiter = RateLimiter(Settings(rate_limit_failed_auth_per_minute=1))
    request = Request(
        {
            "type": "http",
            "client": ("same-client", 123),
            "app": SimpleNamespace(state=SimpleNamespace(rate_limiter=limiter)),
        }
    )
    passphrase = uuid4().hex
    service = SimpleNamespace(
        get_credential=AsyncMock(return_value=object()),
        verify_passphrase=AsyncMock(return_value=False),
    )
    with pytest.raises(APIError) as first:
        await create_session(request, SessionRequest(passphrase=passphrase), service)
    assert first.value.status_code == 401
    with pytest.raises(APIError) as second:
        await create_session(request, SessionRequest(passphrase=passphrase), service)
    assert second.value.status_code == 429
    service.verify_passphrase.assert_awaited_once()
