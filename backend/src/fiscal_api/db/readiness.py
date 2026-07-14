from collections.abc import Awaitable, Callable

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

ReadinessCheck = Callable[[], Awaitable[None]]


def build_readiness_check(engine: AsyncEngine) -> ReadinessCheck:
    async def check() -> None:
        async with engine.connect() as connection:
            await connection.execute(text("SELECT 1"))

    return check
