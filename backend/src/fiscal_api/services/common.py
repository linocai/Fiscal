from typing import NoReturn

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession
from starlette import status

from fiscal_api.core.errors import APIError

P2_MUTATION_LOCK_ID = 0x0F15CA12


async def acquire_p2_mutation_lock(session: AsyncSession) -> None:
    """Serialize low-frequency P2 master-data mutations within the current transaction."""
    await session.execute(
        text("SELECT pg_advisory_xact_lock(:lock_id)"),
        {"lock_id": P2_MUTATION_LOCK_ID},
    )


def conflict(code: str, message: str) -> NoReturn:
    raise APIError(status_code=status.HTTP_409_CONFLICT, code=code, message=message)


def invalid(code: str, message: str) -> NoReturn:
    raise APIError(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, code=code, message=message)


def not_found(code: str, message: str) -> NoReturn:
    raise APIError(status_code=status.HTTP_404_NOT_FOUND, code=code, message=message)


def check_version(current: int, expected: int) -> None:
    if current != expected:
        conflict("resource_version_conflict", "The resource was changed by another request")
