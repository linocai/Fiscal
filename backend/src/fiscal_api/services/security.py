import hmac
from dataclasses import dataclass
from datetime import timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from starlette import status as http_status

from fiscal_api.core.config import Settings
from fiscal_api.core.device_tokens import (
    generate_device_token,
    is_well_formed_database_token,
    token_digest,
    token_fingerprint,
)
from fiscal_api.core.errors import APIError
from fiscal_api.core.time import utc_now
from fiscal_api.db.models.security import DeviceToken, DeviceTokenRole, DeviceTokenStatus
from fiscal_api.repositories.security import DeviceTokenRepository


@dataclass(frozen=True)
class AuthenticatedDevice:
    id: UUID
    label: str
    role: str
    status: str
    version: int
    persistent: bool = True


@dataclass(frozen=True)
class IssuedDeviceToken:
    raw_token: str
    token: DeviceToken


class DeviceTokenService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = DeviceTokenRepository(session)

    def _pepper(self) -> str:
        if self.settings.token_pepper is None:
            raise RuntimeError("Database token authentication requires a pepper")
        return self.settings.token_pepper.get_secret_value()

    async def authenticate(
        self, raw_token: str, *, allow_pending: bool = False
    ) -> AuthenticatedDevice | None:
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
        if row.status == DeviceTokenStatus.PENDING:
            if not allow_pending or row.pending_expires_at is None or row.pending_expires_at <= now:
                return None
        elif row.status != DeviceTokenStatus.ACTIVE or (
            row.expires_at is not None and row.expires_at <= now
        ):
            return None
        if row.status == DeviceTokenStatus.ACTIVE:
            changed = await self.repository.touch_last_used(row.id, now - timedelta(hours=1), now)
            if changed:
                await self.session.commit()
        return self._authenticated(row)

    async def list_visible(self, actor: AuthenticatedDevice) -> list[DeviceToken]:
        if not actor.persistent:
            return []
        if actor.role == DeviceTokenRole.OPERATOR:
            return await self.repository.list_all()
        row = await self.repository.get(actor.id)
        return [row] if row is not None else []

    async def issue_device(self, actor: AuthenticatedDevice, label: str) -> IssuedDeviceToken:
        self._require_operator(actor)
        self._require_persistent(actor)
        return await self._issue(
            label=label,
            role=DeviceTokenRole.DEVICE,
            issued_by_id=actor.id if actor.persistent else None,
            replaces_id=None,
        )

    async def prepare_rotation(
        self, actor: AuthenticatedDevice, expected_version: int
    ) -> IssuedDeviceToken:
        self._require_persistent(actor)
        current = await self.repository.get(actor.id, for_update=True)
        if current is None or current.status != DeviceTokenStatus.ACTIVE:
            self._state_conflict("The current device token is not active")
        assert current is not None
        self._require_version(current, expected_version)
        now = utc_now()
        if await self.repository.find_live_successor(current.id, now) is not None:
            self._state_conflict("A pending rotation already exists")
        return await self._issue(
            label=current.label,
            role=current.role,
            issued_by_id=current.id,
            replaces_id=current.id,
        )

    async def activate(
        self, actor: AuthenticatedDevice, expected_version: int
    ) -> tuple[DeviceToken, UUID | None]:
        self._require_persistent(actor)
        successor = await self.repository.get(actor.id, for_update=True)
        now = utc_now()
        if (
            successor is None
            or successor.status != DeviceTokenStatus.PENDING
            or successor.pending_expires_at is None
            or successor.pending_expires_at <= now
        ):
            self._state_conflict("The pending device token cannot be activated")
        assert successor is not None
        self._require_version(successor, expected_version)
        predecessor_id = successor.replaces_id
        predecessor: DeviceToken | None = None
        if predecessor_id is not None:
            predecessor = await self.repository.get(predecessor_id, for_update=True)
            if predecessor is None or predecessor.status != DeviceTokenStatus.ACTIVE:
                self._state_conflict("The predecessor device token is no longer active")
            if successor.role == DeviceTokenRole.OPERATOR:
                await self.repository.lock_operator_lifecycle()
        successor.status = DeviceTokenStatus.ACTIVE
        successor.activated_at = now
        successor.pending_expires_at = None
        successor.version += 1
        successor.updated_at = now
        if predecessor is not None:
            predecessor.status = DeviceTokenStatus.REVOKED
            predecessor.revoked_at = now
            predecessor.version += 1
            predecessor.updated_at = now
        await self.session.commit()
        return successor, predecessor_id

    async def revoke(
        self, actor: AuthenticatedDevice, token_id: UUID, expected_version: int
    ) -> DeviceToken:
        self._require_persistent(actor)
        if actor.role != DeviceTokenRole.OPERATOR and actor.id != token_id:
            self._permission_denied()
        target = await self.repository.get(token_id, for_update=True)
        if target is None:
            raise APIError(
                status_code=http_status.HTTP_404_NOT_FOUND,
                code="device_token_not_found",
                message="The device token was not found",
            )
        self._require_version(target, expected_version)
        if target.status == DeviceTokenStatus.REVOKED:
            return target
        if target.role == DeviceTokenRole.OPERATOR and target.status == DeviceTokenStatus.ACTIVE:
            await self.repository.lock_operator_lifecycle()
            if await self.repository.active_count(role=DeviceTokenRole.OPERATOR) <= 1:
                raise APIError(
                    status_code=http_status.HTTP_409_CONFLICT,
                    code="last_operator_required",
                    message="The last active operator cannot be revoked",
                )
        now = utc_now()
        target.status = DeviceTokenStatus.REVOKED
        target.revoked_at = now
        target.pending_expires_at = None
        target.version += 1
        target.updated_at = now
        await self.session.commit()
        return target

    async def counts(self) -> tuple[int, int]:
        return await self.repository.active_count(), await self.repository.pending_count()

    async def current(self, actor: AuthenticatedDevice) -> DeviceToken | None:
        if not actor.persistent:
            return None
        return await self.repository.get(actor.id)

    async def _issue(
        self,
        *,
        label: str,
        role: str,
        issued_by_id: UUID | None,
        replaces_id: UUID | None,
    ) -> IssuedDeviceToken:
        normalized_label = label.strip()
        raw_token = generate_device_token()
        now = utc_now()
        row = DeviceToken(
            label=normalized_label,
            role=role,
            status=DeviceTokenStatus.PENDING,
            token_digest=token_digest(raw_token, self._pepper()),
            fingerprint=token_fingerprint(raw_token),
            pepper_version=self.settings.token_pepper_version,
            version=1,
            issued_by_id=issued_by_id,
            replaces_id=replaces_id,
            pending_expires_at=now + timedelta(minutes=self.settings.token_pending_ttl_minutes),
            created_at=now,
            updated_at=now,
        )
        await self.repository.add(row)
        await self.session.commit()
        return IssuedDeviceToken(raw_token=raw_token, token=row)

    @staticmethod
    def _authenticated(row: DeviceToken) -> AuthenticatedDevice:
        return AuthenticatedDevice(
            id=row.id,
            label=row.label,
            role=row.role,
            status=row.status,
            version=row.version,
        )

    @staticmethod
    def _require_version(row: DeviceToken, expected_version: int) -> None:
        if row.version != expected_version:
            raise APIError(
                status_code=http_status.HTTP_409_CONFLICT,
                code="stale_version",
                message="The device token changed since it was loaded",
                details={"current_version": row.version},
            )

    @staticmethod
    def _require_operator(actor: AuthenticatedDevice) -> None:
        if actor.role != DeviceTokenRole.OPERATOR:
            DeviceTokenService._permission_denied()

    @staticmethod
    def _require_persistent(actor: AuthenticatedDevice) -> None:
        if not actor.persistent:
            DeviceTokenService._permission_denied()

    @staticmethod
    def _permission_denied() -> None:
        raise APIError(
            status_code=http_status.HTTP_403_FORBIDDEN,
            code="device_token_permission_denied",
            message="This device token cannot perform that operation",
        )

    @staticmethod
    def _state_conflict(message: str) -> None:
        raise APIError(
            status_code=http_status.HTTP_409_CONFLICT,
            code="token_state_conflict",
            message=message,
        )
