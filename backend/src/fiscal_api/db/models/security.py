from datetime import datetime
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    LargeBinary,
    SmallInteger,
    String,
    Uuid,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class DeviceTokenRole(StrEnum):
    DEVICE = "device"
    OPERATOR = "operator"


class DeviceTokenStatus(StrEnum):
    PENDING = "pending"
    ACTIVE = "active"
    REVOKED = "revoked"


class DeviceToken(Base):
    __tablename__ = "device_tokens"
    __table_args__ = (
        CheckConstraint("char_length(label) BETWEEN 1 AND 80", name="label_length"),
        CheckConstraint("role IN ('device','operator')", name="valid_role"),
        CheckConstraint("status IN ('pending','active','revoked')", name="valid_status"),
        CheckConstraint("octet_length(token_digest) = 32", name="digest_length"),
        CheckConstraint("char_length(fingerprint) = 12", name="fingerprint_length"),
        CheckConstraint("pepper_version >= 1", name="pepper_version_positive"),
        CheckConstraint("version >= 1", name="version_positive"),
        CheckConstraint(
            "(status='pending' AND activated_at IS NULL AND revoked_at IS NULL "
            "AND pending_expires_at IS NOT NULL) OR "
            "(status='active' AND activated_at IS NOT NULL AND revoked_at IS NULL) OR "
            "(status='revoked' AND revoked_at IS NOT NULL)",
            name="lifecycle_consistent",
        ),
        Index("uq_device_tokens_digest", "token_digest", unique=True),
        Index("uq_device_tokens_fingerprint", "fingerprint", unique=True),
        Index(
            "ix_device_tokens_active_role",
            "role",
            postgresql_where=text("status='active'"),
        ),
        Index("ix_device_tokens_status_created", "status", text("created_at DESC")),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    label: Mapped[str] = mapped_column(String(80), nullable=False)
    role: Mapped[str] = mapped_column(String(16), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    token_digest: Mapped[bytes] = mapped_column(LargeBinary(32), nullable=False)
    fingerprint: Mapped[str] = mapped_column(String(12), nullable=False)
    pepper_version: Mapped[int] = mapped_column(SmallInteger, nullable=False, default=1)
    version: Mapped[int] = mapped_column(SmallInteger, nullable=False, default=1)
    issued_by_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("device_tokens.id", ondelete="RESTRICT"), nullable=True
    )
    replaces_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("device_tokens.id", ondelete="RESTRICT"), nullable=True
    )
    pending_expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    activated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
