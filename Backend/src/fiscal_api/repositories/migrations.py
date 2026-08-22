from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models import MigrationRun


class MigrationRunRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get(self, run_id: UUID) -> MigrationRun | None:
        return await self.session.scalar(select(MigrationRun).where(MigrationRun.id == run_id))
