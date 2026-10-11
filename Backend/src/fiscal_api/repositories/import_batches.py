from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models import ImportBatch


class ImportBatchRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def by_id(self, batch_id: UUID, *, for_update: bool = False) -> ImportBatch | None:
        statement = select(ImportBatch).where(ImportBatch.id == batch_id)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def by_idempotency_key(
        self, idempotency_key: str, *, for_update: bool = False
    ) -> ImportBatch | None:
        statement = select(ImportBatch).where(ImportBatch.idempotency_key == idempotency_key)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def page(
        self,
        *,
        status: str | None,
        cursor_time: datetime | None,
        cursor_id: UUID | None,
        limit: int,
    ) -> list[ImportBatch]:
        statement = select(ImportBatch)
        if status is not None:
            statement = statement.where(ImportBatch.status == status)
        if cursor_time is not None and cursor_id is not None:
            statement = statement.where(
                or_(
                    ImportBatch.created_at < cursor_time,
                    (ImportBatch.created_at == cursor_time) & (ImportBatch.id < cursor_id),
                )
            )
        statement = statement.order_by(ImportBatch.created_at.desc(), ImportBatch.id.desc()).limit(
            limit + 1
        )
        return list((await self.session.scalars(statement)).all())

    def add(self, batch: ImportBatch) -> None:
        self.session.add(batch)
