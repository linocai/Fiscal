from __future__ import annotations

from datetime import datetime, timedelta
from uuid import UUID, uuid4

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, String, UniqueConstraint, Uuid
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class CategoryTransformPreview(Base):
    __tablename__ = "category_transform_previews"
    __table_args__ = (
        CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    payload: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: utc_now() + timedelta(minutes=30)
    )


class CategoryTransformOperation(Base):
    __tablename__ = "category_transform_operations"
    __table_args__ = (
        CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        UniqueConstraint("idempotency_key", name="uq_category_transform_operations_idempotency"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    preview_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("category_transform_previews.id", ondelete="RESTRICT"), nullable=False
    )
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    receipt: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
