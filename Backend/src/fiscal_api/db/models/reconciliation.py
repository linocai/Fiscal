from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class ReconciliationTargetKind(StrEnum):
    ACCOUNT = "account"
    CREDIT_CYCLE = "credit_cycle"


class ReconciliationCheckpoint(Base):
    """A user supplied real-world balance anchor; it never owns ledger state."""

    __tablename__ = "reconciliation_checkpoints"
    __table_args__ = (
        CheckConstraint("target_kind IN ('account', 'credit_cycle')", name="valid_target_kind"),
        CheckConstraint(
            "(target_kind = 'account' AND account_id IS NOT NULL AND credit_cycle_id IS NULL) OR "
            "(target_kind = 'credit_cycle' AND account_id IS NULL AND credit_cycle_id IS NOT NULL)",
            name="target_shape",
        ),
        Index(
            "ix_reconciliation_checkpoints_target_time",
            "account_id",
            "credit_cycle_id",
            "as_of",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    target_kind: Mapped[str] = mapped_column(String(16), nullable=False)
    account_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=True
    )
    credit_cycle_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("credit_cycles.id", ondelete="RESTRICT"), nullable=True
    )
    as_of: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    actual_balance_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class AttentionDismissal(Base):
    __tablename__ = "attention_dismissals"
    __table_args__ = (
        UniqueConstraint("source_type", "source_id", name="uq_attention_dismissal_source"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    source_type: Mapped[str] = mapped_column(String(48), nullable=False)
    source_id: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
