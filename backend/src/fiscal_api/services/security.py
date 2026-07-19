import hmac
from dataclasses import dataclass
from datetime import timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.core.config import Settings
from fiscal_api.core.device_tokens import is_well_formed_database_token, token_digest
from fiscal_api.core.time import utc_now
from fiscal_api.db.models.security import DeviceTokenRole, DeviceTokenStatus
from fiscal_api.repositories.security import DeviceTokenRepository


@dataclass(frozen=True)
class AuthenticatedDevice:
    """Authenticated principal.

    Carries either a transition device token or (once a passphrase is set) a
    minted access key; both reach protected routes through the same seam.
    """

    id: UUID
    label: str
    role: str
    status: str
    version: int
    persistent: bool = True


class DeviceTokenService:
    """Transition-only device-token authentication.

    The device-token lifecycle (issue/rotate/activate/revoke) has been removed;
    only verification of already-issued tokens survives so existing devices stay
    connected until a passphrase is set. Retained for a later cleanup release.
    """

    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = DeviceTokenRepository(session)

    def _pepper(self) -> str:
        if self.settings.token_pepper is None:
            raise RuntimeError("Database token authentication requires a pepper")
        return self.settings.token_pepper.get_secret_value()

    async def authenticate(self, raw_token: str) -> AuthenticatedDevice | None:
        if not self.settings.uses_database_device_tokens:
            if raw_token and hmac.compare_digest(
                raw_token.encode(), self.settings.legacy_device_token.encode()
            ):
                return AuthenticatedDevice(
                    id=UUID(int=0),
                    label="Local static token",
                    role=DeviceTokenRole.OPERATOR,
                    status=DeviceTokenStatus.ACTIVE,
                    version=1,
                    persistent=False,
                )
            return None
        if not is_well_formed_database_token(raw_token):
            return None
        row = await self.repository.get_by_digest(token_digest(raw_token, self._pepper()))
        now = utc_now()
        if row is None:
            return None
        if row.status != DeviceTokenStatus.ACTIVE or (
            row.expires_at is not None and row.expires_at <= now
        ):
            return None
        changed = await self.repository.touch_last_used(row.id, now - timedelta(hours=1), now)
        if changed:
            await self.session.commit()
        return AuthenticatedDevice(
            id=row.id,
            label=row.label,
            role=row.role,
            status=row.status,
            version=row.version,
        )
