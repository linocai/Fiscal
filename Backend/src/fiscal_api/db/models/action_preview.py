from __future__ import annotations

from datetime import datetime, timedelta
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class ActionPreviewSession(Base):
    """Short-lived proof for a user-reviewed formal action.

    These rows are operational state, not financial facts.  Archive excludes
    them and a commit may consume each preview at most once.
    """

    __tablename__ = "action_preview_sessions"
    __table_args__ = (
        CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        CheckConstraint("data_revision >= 0", name="data_revision_nonnegative"),
        Index("ix_action_preview_sessions_expiry", "expires_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    action: Mapped[str] = mapped_column(String(32), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    payload: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    data_revision: Mapped[int] = mapped_column(BigInteger, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: utc_now() + timedelta(minutes=30)
    )
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class ActionOperation(Base):
    """Durable replay receipt for a successfully committed preview."""

    __tablename__ = "action_operations"
    __table_args__ = (
        CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        CheckConstraint("data_revision >= 0", name="data_revision_nonnegative"),
        UniqueConstraint("preview_id", name="uq_action_operations_preview"),
        UniqueConstraint("idempotency_key", name="uq_action_operations_idempotency"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    preview_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("action_preview_sessions.id", ondelete="RESTRICT"), nullable=False
    )
    action: Mapped[str] = mapped_column(String(32), nullable=False)
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    data_revision: Mapped[int] = mapped_column(BigInteger, nullable=False)
    receipt: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
