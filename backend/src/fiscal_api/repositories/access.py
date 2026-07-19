from datetime import datetime
from uuid import UUID

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models.access import AccessCredential, AccessKey


class AccessRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get_credential(self, *, for_update: bool = False) -> AccessCredential | None:
        statement = select(AccessCredential).limit(1)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def add_credential(self, credential: AccessCredential) -> None:
        self.session.add(credential)
        await self.session.flush()

    async def get_access_key_by_digest(self, digest: bytes) -> AccessKey | None:
        return await self.session.scalar(select(AccessKey).where(AccessKey.key_digest == digest))

    async def add_access_key(self, access_key: AccessKey) -> None:
        self.session.add(access_key)
        await self.session.flush()

    async def active_access_key_count(self, generation: int) -> int:
        return int(
            await self.session.scalar(
                select(func.count())
                .select_from(AccessKey)
                .where(AccessKey.credential_generation == generation)
            )
            or 0
        )

    async def touch_last_used(self, key_id: UUID, threshold: datetime, now: datetime) -> bool:
        result = await self.session.execute(
            update(AccessKey)
            .where(
                AccessKey.id == key_id,
                (AccessKey.last_used_at.is_(None) | (AccessKey.last_used_at < threshold)),
            )
            .values(last_used_at=now)
            .returning(AccessKey.id)
        )
        return result.scalar_one_or_none() is not None
