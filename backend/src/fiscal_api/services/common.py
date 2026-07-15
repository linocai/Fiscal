from typing import NoReturn

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession
from starlette import status

from fiscal_api.core.errors import APIError

MUTATION_LOCK_ID = 0x0F15CA12
INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1


async def acquire_mutation_lock(session: AsyncSession) -> None:
    """Serialize all master-data and ledger mutations within the current transaction."""
    await session.execute(
        text("SELECT pg_advisory_xact_lock(:lock_id)"),
        {"lock_id": MUTATION_LOCK_ID},
    )


# Compatibility name retained for existing callers while P3 moves to the shared terminology.
acquire_p2_mutation_lock = acquire_mutation_lock


def conflict(code: str, message: str) -> NoReturn:
    raise APIError(status_code=status.HTTP_409_CONFLICT, code=code, message=message)


def invalid(code: str, message: str) -> NoReturn:
    raise APIError(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, code=code, message=message)


def not_found(code: str, message: str) -> NoReturn:
    raise APIError(status_code=status.HTTP_404_NOT_FOUND, code=code, message=message)


def check_version(current: int, expected: int) -> None:
    if current != expected:
        conflict("resource_version_conflict", "The resource was changed by another request")


def checked_int64(value: int, *, label: str = "derived amount") -> int:
    if value < INT64_MIN or value > INT64_MAX:
        conflict(
            "derived_amount_out_of_range",
            f"The {label} is outside the signed 64-bit integer range",
        )
    return value
