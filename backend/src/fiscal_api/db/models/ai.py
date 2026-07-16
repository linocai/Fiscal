from datetime import datetime
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    String,
    Text,
    UniqueConstraint,
    Uuid,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class AIProposalSource(StrEnum):
    TEXT = "text"
    OCR = "ocr"
    SHORTCUT_TEXT = "shortcut_text"


class AIProposalStatus(StrEnum):
    PROCESSING = "processing"
    PENDING = "pending"
    EXECUTED = "executed"
    FAILED = "failed"
    IGNORED = "ignored"
    UNDONE = "undone"


class AISettings(Base):
    __tablename__ = "ai_settings"
    __table_args__ = (
        CheckConstraint("id = 1", name="singleton"),
        CheckConstraint("auto_execute_limit_minor BETWEEN 1 AND 100000", name="auto_limit_range"),
        CheckConstraint("minimum_confidence_bps BETWEEN 9000 AND 10000", name="confidence_range"),
        CheckConstraint("version >= 1", name="version_positive"),
    )

    id: Mapped[int] = mapped_column(SmallInteger, primary_key=True, default=1)
    auto_execute_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    ocr_source_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    shortcut_text_source_enabled: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False
    )
    auto_execute_limit_minor: Mapped[int] = mapped_column(
        BigInteger, nullable=False, default=100_000
    )
    minimum_confidence_bps: Mapped[int] = mapped_column(Integer, nullable=False, default=9_000)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )


class AIProposal(Base):
    __tablename__ = "ai_proposals"
    __table_args__ = (
        CheckConstraint("source IN ('text','ocr','shortcut_text')", name="valid_source"),
        CheckConstraint(
            "status IN ('processing','pending','executed','failed','ignored','undone')",
            name="valid_status",
        ),
        CheckConstraint(
            "kind IS NULL OR kind IN ('income','expense','transfer','credit_purchase','repayment')",
            name="valid_kind",
        ),
        CheckConstraint("char_length(raw_input) BETWEEN 1 AND 2000", name="raw_input_length"),
        CheckConstraint("char_length(content_fingerprint) = 64", name="fingerprint_length"),
        CheckConstraint("char_length(create_request_hash) = 64", name="request_hash_length"),
        CheckConstraint("amount_minor IS NULL OR amount_minor > 0", name="amount_positive"),
        CheckConstraint("currency IS NULL OR currency = 'CNY'", name="valid_currency"),
        CheckConstraint(
            "overall_confidence_bps IS NULL OR overall_confidence_bps BETWEEN 0 AND 10000",
            name="confidence_range",
        ),
        CheckConstraint("version >= 1", name="version_positive"),
        CheckConstraint(
            "transaction_version IS NULL OR transaction_version >= 1",
            name="transaction_version_positive",
        ),
        CheckConstraint(
            "((status IN ('executed','undone')) = (transaction_id IS NOT NULL))",
            name="transaction_state",
        ),
        CheckConstraint(
            "((transaction_id IS NULL AND transaction_version IS NULL) OR "
            "(transaction_id IS NOT NULL AND transaction_version IS NOT NULL))",
            name="transaction_version_state",
        ),
        UniqueConstraint("create_idempotency_key", name="uq_ai_proposals_create_idempotency_key"),
        UniqueConstraint("transaction_id", name="uq_ai_proposals_transaction_id"),
        Index("ix_ai_proposals_fingerprint", "content_fingerprint"),
        Index(
            "ix_ai_proposals_pending_timeline",
            text("created_at DESC"),
            text("id DESC"),
            postgresql_where=text("status = 'pending'"),
        ),
        Index("ix_ai_proposals_timeline", text("created_at DESC"), text("id DESC")),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    source: Mapped[str] = mapped_column(String(16), nullable=False)
    raw_input: Mapped[str] = mapped_column(Text, nullable=False)
    content_fingerprint: Mapped[str] = mapped_column(String(64), nullable=False)
    create_idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    create_request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    provider: Mapped[str | None] = mapped_column(String(40), nullable=True)
    provider_model: Mapped[str | None] = mapped_column(String(120), nullable=True)

    kind: Mapped[str | None] = mapped_column(String(32), nullable=True)
    amount_minor: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    currency: Mapped[str | None] = mapped_column(String(3), nullable=True)
    occurred_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    title: Mapped[str | None] = mapped_column(String(120), nullable=True)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    account_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=True
    )
    category_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("categories.id", ondelete="RESTRICT"), nullable=True
    )
    destination_account_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=True
    )
    credit_cycle_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("credit_cycles.id", ondelete="RESTRICT"), nullable=True
    )

    field_confidences: Mapped[dict[str, int]] = mapped_column(JSONB, nullable=False, default=dict)
    overall_confidence_bps: Mapped[int | None] = mapped_column(Integer, nullable=True)
    missing_fields: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    reason_codes: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    explanation: Mapped[str | None] = mapped_column(String(500), nullable=True)
    error_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    error_message: Mapped[str | None] = mapped_column(String(200), nullable=True)

    status: Mapped[str] = mapped_column(String(16), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    transaction_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=True
    )
    transaction_version: Mapped[int | None] = mapped_column(Integer, nullable=True)
    parsed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    executed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    ignored_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    undone_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
