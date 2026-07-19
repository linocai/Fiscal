from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    Index,
    Integer,
    LargeBinary,
    String,
    Uuid,
)
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class AccessCredential(Base):
    """Single-row personal passphrase credential.

    Only the PBKDF2 slow hash and its per-row salt are stored. Bumping
    ``credential_generation`` (a passphrase change) revokes every access key in
    one write because keys are only accepted when their generation matches.
    """

    __tablename__ = "access_credential"
    __table_args__ = (
        CheckConstraint("credential_generation >= 1", name="credential_generation_positive"),
        CheckConstraint("kdf_iterations >= 100000", name="kdf_iterations_minimum"),
        CheckConstraint("octet_length(passphrase_salt) = 16", name="passphrase_salt_length"),
        CheckConstraint("octet_length(passphrase_hash) = 32", name="passphrase_hash_length"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    passphrase_hash: Mapped[bytes] = mapped_column(LargeBinary(32), nullable=False)
    passphrase_salt: Mapped[bytes] = mapped_column(LargeBinary(16), nullable=False)
    kdf_iterations: Mapped[int] = mapped_column(Integer, nullable=False)
    credential_generation: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
    last_rotated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class AccessKey(Base):
    """Opaque bearer credential issued on login / set / change.

    Persisted as a keyed HMAC digest tagged with the generation it was minted
    at; a key is only valid while its generation equals the credential's.
    """

    __tablename__ = "access_keys"
    __table_args__ = (
        CheckConstraint("octet_length(key_digest) = 32", name="key_digest_length"),
        CheckConstraint("char_length(key_fingerprint) = 12", name="key_fingerprint_length"),
        CheckConstraint("credential_generation >= 1", name="access_key_generation_positive"),
        Index("uq_access_keys_digest", "key_digest", unique=True),
        Index("ix_access_keys_generation", "credential_generation"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    key_digest: Mapped[bytes] = mapped_column(LargeBinary(32), nullable=False)
    key_fingerprint: Mapped[str] = mapped_column(String(12), nullable=False)
    credential_generation: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    label: Mapped[str | None] = mapped_column(String(80), nullable=True)
