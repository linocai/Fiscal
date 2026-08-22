from fastapi import APIRouter
from starlette import status

from fiscal_api.api.dependencies import ReadinessDependency
from fiscal_api.api.schemas import LiveResponse, ReadyResponse
from fiscal_api.core.errors import APIError

router = APIRouter(prefix="/health", tags=["health"])


@router.get("/live", response_model=LiveResponse)
async def live() -> LiveResponse:
    return LiveResponse()


@router.get("/ready", response_model=ReadyResponse)
async def ready(check: ReadinessDependency) -> ReadyResponse:
    try:
        await check()
    except Exception as error:
        raise APIError(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            code="database_unavailable",
            message="The database is unavailable",
        ) from error
    return ReadyResponse()
