from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p30_schemas import MigrationRunResponse
from fiscal_api.db.models import MigrationRunMode, MigrationRunStatus
from fiscal_api.repositories.migrations import MigrationRunRepository
from fiscal_api.services.common import not_found


class MigrationRunService:
    def __init__(self, session: AsyncSession) -> None:
        self.repository = MigrationRunRepository(session)

    async def get(self, run_id: UUID) -> MigrationRunResponse:
        run = await self.repository.get(run_id)
        if run is None:
            not_found("migration_run_not_found", "The migration run does not exist")
        return MigrationRunResponse(
            id=run.id,
            mode=MigrationRunMode(run.mode),
            status=MigrationRunStatus(run.status),
            source_system=run.source_system,
            code_revision=run.code_revision,
            started_at=run.started_at,
            completed_at=run.completed_at,
            deep_link=f"fiscal://settings/migrations/{run.id}",
        )
