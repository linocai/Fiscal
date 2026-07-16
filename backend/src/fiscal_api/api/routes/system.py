from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy import text
from starlette import status

from fiscal_api import __version__
from fiscal_api.api.dependencies import (
    DeviceTokenServiceDependency,
    ReadinessDependency,
    SessionDependency,
)
from fiscal_api.api.p11_schemas import (
    OperationsStatusResponse,
    RateLimitPolicy,
    SecurityStatusResponse,
    TokenCounts,
)
from fiscal_api.api.routes.device_tokens import device_token_summary
from fiscal_api.api.schemas import SystemStatusResponse
from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.errors import APIError
from fiscal_api.core.operations import OperationsStatusReader, read_release_metadata
from fiscal_api.core.security import AuthenticatedDeviceDependency, require_device_token
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


@router.get("/operations-status", response_model=OperationsStatusResponse)
async def operations_status(
    check: ReadinessDependency,
    session: SessionDependency,
    settings: Annotated[Settings, Depends(get_settings)],
) -> OperationsStatusResponse:
    try:
        await check()
        alembic_revision = await session.scalar(text("SELECT version_num FROM alembic_version"))
    except Exception as error:
        raise APIError(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            code="database_unavailable",
            message="The database is unavailable",
        ) from error
    if not isinstance(alembic_revision, str) or not alembic_revision:
        raise APIError(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            code="schema_state_unavailable",
            message="The database schema state is unavailable",
        )
    release_revision, release_head = read_release_metadata(settings.release_metadata_file)
    reader = OperationsStatusReader(
        settings.operations_status_directory,
        backup_stale_hours=settings.backup_max_age_hours,
        restore_stale_hours=settings.restore_verify_stale_hours,
        disk_stale_minutes=settings.disk_status_stale_minutes,
    )
    schema_state = (
        "unknown"
        if release_head is None
        else ("current" if release_head == alembic_revision else "mismatch")
    )
    return OperationsStatusResponse(
        service_version=__version__,
        release_revision=release_revision,
        alembic_revision=alembic_revision,
        release_alembic_revision=release_head,
        schema_state=schema_state,
        backup=reader.backup(),
        restore=reader.restore(),
        disk=reader.disk(),
    )


@router.get("/security-status", response_model=SecurityStatusResponse)
async def security_status(
    actor: AuthenticatedDeviceDependency,
    service: DeviceTokenServiceDependency,
    settings: Annotated[Settings, Depends(get_settings)],
) -> SecurityStatusResponse:
    active, pending = await service.counts() if actor.persistent else (0, 0)
    current = await service.current(actor)
    return SecurityStatusResponse(
        authentication_mode="database" if settings.uses_database_device_tokens else "static",
        server_time=utc_now(),
        current_device=device_token_summary(current) if current is not None else None,
        token_counts=TokenCounts(active=active, pending=pending),
        rate_limits=RateLimitPolicy(
            read_per_minute=settings.rate_limit_read_per_minute,
            write_per_minute=settings.rate_limit_write_per_minute,
            ai_per_minute=settings.rate_limit_ai_per_minute,
            failed_auth_per_minute=settings.rate_limit_failed_auth_per_minute,
        ),
    )
