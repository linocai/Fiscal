from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy import text
from starlette import status

from fiscal_api import __version__
from fiscal_api.api.dependencies import ReadinessDependency, SessionDependency
from fiscal_api.api.p11_schemas import OperationsStatusResponse
from fiscal_api.api.schemas import SystemStatusResponse
from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.errors import APIError
from fiscal_api.core.operations import OperationsStatusReader, read_release_metadata
from fiscal_api.core.security import require_authenticated
from fiscal_api.core.time import utc_now

router = APIRouter(
    prefix="/system",
    tags=["system"],
    dependencies=[Depends(require_authenticated)],
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
