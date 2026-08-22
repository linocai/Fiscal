import asyncio
import math
from collections import OrderedDict
from dataclasses import dataclass
from time import monotonic

from starlette import status

from fiscal_api.core.config import Settings
from fiscal_api.core.errors import APIError


@dataclass
class _Bucket:
    tokens: float
    updated_at: float


class RateLimiter:
    """Bounded, process-local token buckets for the single-worker API."""

    def __init__(self, settings: Settings, *, max_sources: int = 10_000) -> None:
        self._settings = settings
        self._max_sources = max_sources
        self._buckets: OrderedDict[str, _Bucket] = OrderedDict()
        self._lock = asyncio.Lock()

    async def check_failed_auth(self, source: str) -> None:
        await self._consume(f"failed:{source}", self._settings.rate_limit_failed_auth_per_minute)

    async def check_authenticated(self, device_id: str, method: str, path: str) -> None:
        if path.startswith("/api/v1/ai/"):
            scope = "ai"
            limit = self._settings.rate_limit_ai_per_minute
        elif method in {"GET", "HEAD", "OPTIONS"}:
            scope = "read"
            limit = self._settings.rate_limit_read_per_minute
        else:
            scope = "write"
            limit = self._settings.rate_limit_write_per_minute
        await self._consume(f"{scope}:{device_id}", limit)

    async def _consume(self, key: str, limit: int) -> None:
        now = monotonic()
        refill_per_second = limit / 60.0
        async with self._lock:
            bucket = self._buckets.pop(key, None)
            if bucket is None:
                bucket = _Bucket(tokens=float(limit), updated_at=now)
            else:
                bucket.tokens = min(
                    float(limit), bucket.tokens + (now - bucket.updated_at) * refill_per_second
                )
                bucket.updated_at = now
            if bucket.tokens < 1:
                self._buckets[key] = bucket
                retry_after = max(1, math.ceil((1 - bucket.tokens) / refill_per_second))
                raise APIError(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    code="rate_limit_exceeded",
                    message="Too many requests",
                    headers={"Retry-After": str(retry_after)},
                )
            bucket.tokens -= 1
            self._buckets[key] = bucket
            while len(self._buckets) > self._max_sources:
                self._buckets.popitem(last=False)
