from datetime import datetime
from uuid import UUID

from sqlalchemy import func, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.db.models.security import DeviceToken, DeviceTokenStatus


class DeviceTokenRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get_by_digest(self, digest: bytes) -> DeviceToken | None:
        return await self.session.scalar(
            select(DeviceToken).where(DeviceToken.token_digest == digest)
        )

    async def get(self, token_id: UUID, *, for_update: bool = False) -> DeviceToken | None:
        statement = select(DeviceToken).where(DeviceToken.id == token_id)
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def list_all(self) -> list[DeviceToken]:
        result = await self.session.scalars(
            select(DeviceToken).order_by(DeviceToken.created_at.desc(), DeviceToken.id.desc())
        )
        return list(result)

    async def add(self, token: DeviceToken) -> None:
        self.session.add(token)
        await self.session.flush()

    async def active_count(self, *, role: str | None = None) -> int:
        statement = (
            select(func.count())
            .select_from(DeviceToken)
            .where(DeviceToken.status == DeviceTokenStatus.ACTIVE)
        )
        if role is not None:
            statement = statement.where(DeviceToken.role == role)
        return int(await self.session.scalar(statement) or 0)

    async def pending_count(self) -> int:
        return int(
            await self.session.scalar(
                select(func.count())
                .select_from(DeviceToken)
                .where(DeviceToken.status == DeviceTokenStatus.PENDING)
            )
            or 0
        )

    async def find_live_successor(self, predecessor_id: UUID, now: datetime) -> DeviceToken | None:
        return await self.session.scalar(
            select(DeviceToken).where(
                DeviceToken.replaces_id == predecessor_id,
                DeviceToken.status == DeviceTokenStatus.PENDING,
                DeviceToken.pending_expires_at > now,
            )
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

    async def lock_operator_lifecycle(self) -> None:
        await self.session.execute(
            text("SELECT pg_advisory_xact_lock(hashtext('fiscal-device-token-operator'))")
        )
