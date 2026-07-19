from datetime import datetime
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models.security import DeviceToken


class DeviceTokenRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get_by_digest(self, digest: bytes) -> DeviceToken | None:
        return await self.session.scalar(
            select(DeviceToken).where(DeviceToken.token_digest == digest)
        )

    async def touch_last_used(self, token_id: UUID, threshold: datetime, now: datetime) -> bool:
        result = await self.session.execute(
            update(DeviceToken)
            .where(
                DeviceToken.id == token_id,
                (DeviceToken.last_used_at.is_(None) | (DeviceToken.last_used_at < threshold)),
            )
            .values(last_used_at=now, updated_at=now)
            .returning(DeviceToken.id)
        )
        return result.scalar_one_or_none() is not None
