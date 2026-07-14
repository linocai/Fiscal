from typing import Annotated

from fastapi import APIRouter, Depends
from starlette import status

from fiscal_api import __version__
from fiscal_api.api.dependencies import ReadinessDependency
from fiscal_api.api.schemas import SystemStatusResponse
from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.errors import APIError
from fiscal_api.core.security import require_device_token
from fiscal_api.core.time import utc_now

router = APIRouter(
    prefix="/system",
    tags=["system"],
    dependencies=[Depends(require_device_token)],
)


@router.get("/status", response_model=SystemStatusResponse)
async def system_status(
    check: ReadinessDependency,
    settings: Annotated[Settings, Depends(get_settings)],
) -> SystemStatusResponse:
    try:
        await check()
    except Exception as error:
        raise APIError(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            code="database_unavailable",
            message="The database is unavailable",
        ) from error
    return SystemStatusResponse(
        service=settings.service_name,
        version=__version__,
        environment=settings.environment,
        timestamp=utc_now(),
    )
