from dataclasses import dataclass
from datetime import timedelta

from sqlalchemy.ext.asyncio import AsyncSession
from starlette import status as http_status

from fiscal_api.core.access_keys import (
    access_key_digest,
    access_key_fingerprint,
    derive_passphrase_hash,
    generate_access_key,
    generate_salt,
    is_well_formed_access_key,
    verify_passphrase,
)
from fiscal_api.core.config import Settings
from fiscal_api.core.errors import APIError
from fiscal_api.core.time import utc_now
from fiscal_api.db.models.access import AccessCredential, AccessKey
from fiscal_api.db.models.security import DeviceTokenRole, DeviceTokenStatus
from fiscal_api.repositories.access import AccessRepository
from fiscal_api.services.security import AuthenticatedDevice


@dataclass(frozen=True)
class MintedAccessKey:
    raw_key: str
    credential_generation: int


class AccessService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = AccessRepository(session)

    def _pepper(self) -> str:
        if self.settings.token_pepper is None:
            raise RuntimeError("Access credentials require a pepper")
        return self.settings.token_pepper.get_secret_value()

    async def get_credential(self) -> AccessCredential | None:
        return await self.repository.get_credential()

    def verify_passphrase(self, credential: AccessCredential, passphrase: str) -> bool:
        return verify_passphrase(
            passphrase,
            credential.passphrase_salt,
            credential.kdf_iterations,
            credential.passphrase_hash,
        )

    async def authenticate_access_key(
        self, raw_key: str, credential: AccessCredential
    ) -> AuthenticatedDevice | None:
        if not is_well_formed_access_key(raw_key):
            return None
        row = await self.repository.get_access_key_by_digest(
            access_key_digest(raw_key, self._pepper())
        )
        if row is None or row.credential_generation != credential.credential_generation:
            return None
        now = utc_now()
        changed = await self.repository.touch_last_used(row.id, now - timedelta(hours=1), now)
        if changed:
            await self.session.commit()
        return AuthenticatedDevice(
            id=row.id,
            label=row.label or "Access key",
            role=DeviceTokenRole.OPERATOR,
            status=DeviceTokenStatus.ACTIVE,
            version=credential.credential_generation,
            persistent=True,
        )

    async def active_access_key_count(self, generation: int) -> int:
        return await self.repository.active_access_key_count(generation)

    async def login(self, credential: AccessCredential) -> MintedAccessKey:
        """Mint a fresh access key at the current generation for a verified login."""
        raw = await self._mint(credential.credential_generation)
        await self.session.commit()
        return MintedAccessKey(raw_key=raw, credential_generation=credential.credential_generation)

    async def initialize(self, passphrase: str) -> MintedAccessKey:
        """Create the credential row (generation 1) and mint the first access key.

        Refuses if a credential already exists; the existence of the credential
        row is itself the switch that permanently closes the device-token layer.
        """
        existing = await self.repository.get_credential(for_update=True)
        if existing is not None:
            raise APIError(
                status_code=http_status.HTTP_409_CONFLICT,
                code="passphrase_already_set",
                message="The access passphrase is already set",
            )
        salt = generate_salt()
        iterations = self.settings.passphrase_kdf_iterations
        now = utc_now()
        credential = AccessCredential(
            passphrase_hash=derive_passphrase_hash(passphrase, salt, iterations),
            passphrase_salt=salt,
            kdf_iterations=iterations,
            credential_generation=1,
            created_at=now,
            updated_at=now,
            last_rotated_at=None,
        )
        await self.repository.add_credential(credential)
        raw = await self._mint(1)
        await self.session.commit()
        return MintedAccessKey(raw_key=raw, credential_generation=1)

    async def change(self, new_passphrase: str) -> MintedAccessKey:
        """Rotate the passphrase: bump generation (global revoke) and mint a new key.

        The caller has already verified the old passphrase.
        """
        credential = await self.repository.get_credential(for_update=True)
        if credential is None:
            raise APIError(
                status_code=http_status.HTTP_409_CONFLICT,
                code="passphrase_not_set",
                message="The access passphrase has not been set",
            )
        salt = generate_salt()
        iterations = self.settings.passphrase_kdf_iterations
        now = utc_now()
        credential.passphrase_hash = derive_passphrase_hash(new_passphrase, salt, iterations)
        credential.passphrase_salt = salt
        credential.kdf_iterations = iterations
        credential.credential_generation += 1
        credential.last_rotated_at = now
        credential.updated_at = now
        new_generation = credential.credential_generation
        raw = await self._mint(new_generation)
        await self.session.commit()
        return MintedAccessKey(raw_key=raw, credential_generation=new_generation)

    async def _mint(self, generation: int) -> str:
        raw = generate_access_key()
        now = utc_now()
        row = AccessKey(
            key_digest=access_key_digest(raw, self._pepper()),
            key_fingerprint=access_key_fingerprint(raw),
            credential_generation=generation,
            created_at=now,
        )
        await self.repository.add_access_key(row)
        return raw
