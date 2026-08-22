from uuid import UUID

from fastapi import APIRouter, Depends

from fiscal_api.api.dependencies import MigrationRunServiceDependency
from fiscal_api.api.p30_schemas import MigrationRunResponse
from fiscal_api.core.security import require_authenticated

router = APIRouter(
    prefix="/migrations/runs",
    tags=["migrations"],
    dependencies=[Depends(require_authenticated)],
)


@router.get("/{run_id}", response_model=MigrationRunResponse)
async def get_migration_run(
    run_id: UUID, service: MigrationRunServiceDependency
) -> MigrationRunResponse:
    return await service.get(run_id)
