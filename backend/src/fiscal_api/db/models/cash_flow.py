from datetime import date, datetime
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class CashFlowDirection(StrEnum):
    INFLOW = "inflow"
    OUTFLOW = "outflow"
    TRANSFER = "transfer"


class CashFlowStatus(StrEnum):
    EXPECTED = "expected"
    CONFIRMED = "confirmed"
    SETTLED = "settled"
    CANCELLED = "cancelled"


class CashFlowSource(StrEnum):
    MANUAL = "manual"
    AI_TEXT = "ai_text"
    LEGACY_IMPORT = "legacy_import"


class CashFlowRecurrence(StrEnum):
    MONTHLY = "monthly"


class CashFlowRevisionEvent(StrEnum):
    CREATED = "created"
    UPDATED = "updated"
    CONFIRMED = "confirmed"
    SETTLED = "settled"
    CANCELLED = "cancelled"
    REOPENED = "reopened"


class CashFlowSeries(Base):
    __tablename__ = "cash_flow_series"
    __table_args__ = (
        CheckConstraint("recurrence = 'monthly'", name="valid_recurrence"),
        CheckConstraint("anchor_day BETWEEN 1 AND 31", name="valid_anchor_day"),
        CheckConstraint("version >= 1", name="version_positive"),
        UniqueConstraint("idempotency_key", name="uq_cash_flow_series_idempotency_key"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    recurrence: Mapped[str] = mapped_column(String(16), nullable=False)
    anchor_day: Mapped[int] = mapped_column(Integer, nullable=False)
    end_date: Mapped[date] = mapped_column(Date, nullable=False)
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )

    items: Mapped[list["CashFlowItem"]] = relationship(
        "CashFlowItem", back_populates="series", order_by="CashFlowItem.expected_date"
    )


class CashFlowItem(Base):
    __tablename__ = "cash_flow_items"
    __table_args__ = (
        CheckConstraint("direction IN ('inflow', 'outflow', 'transfer')", name="valid_direction"),
        CheckConstraint(
            "status IN ('expected', 'confirmed', 'settled', 'cancelled')", name="valid_status"
        ),
        CheckConstraint("source IN ('manual', 'ai_text', 'legacy_import')", name="valid_source"),
        CheckConstraint("planned_amount_minor > 0", name="planned_amount_positive"),
        CheckConstraint("version >= 1", name="version_positive"),
        CheckConstraint("char_length(title) BETWEEN 1 AND 120", name="title_length"),
        CheckConstraint("note IS NULL OR char_length(note) <= 500", name="note_length"),
        CheckConstraint(
            "(direction = 'transfer' AND destination_account_id IS NOT NULL "
            "AND category_id IS NULL) "
            "OR (direction <> 'transfer' AND destination_account_id IS NULL)",
            name="valid_destination",
        ),
        UniqueConstraint("idempotency_key", name="uq_cash_flow_items_idempotency_key"),
        UniqueConstraint("linked_transaction_id", name="uq_cash_flow_items_linked_transaction_id"),
        UniqueConstraint("legacy_source_id", name="uq_cash_flow_items_legacy_source_id"),
        Index("ix_cash_flow_items_active", "status", "expected_date"),
        Index("ix_cash_flow_items_series", "series_id", "expected_date"),
        Index("ix_cash_flow_items_account", "account_id", "expected_date"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    series_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("cash_flow_series.id", ondelete="RESTRICT"), nullable=True
    )
    title: Mapped[str] = mapped_column(String(120), nullable=False)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    direction: Mapped[str] = mapped_column(String(16), nullable=False)
    planned_amount_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    expected_date: Mapped[date] = mapped_column(Date, nullable=False)
    account_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=True
    )
    destination_account_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=True
    )
    category_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("categories.id", ondelete="RESTRICT"), nullable=True
    )
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="expected")
    source: Mapped[str] = mapped_column(String(16), nullable=False, default="manual")
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    legacy_source_id: Mapped[str | None] = mapped_column(String(200), nullable=True)
    linked_transaction_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=True
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    settled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )

    series: Mapped[CashFlowSeries | None] = relationship("CashFlowSeries", back_populates="items")
    revisions: Mapped[list["CashFlowItemRevision"]] = relationship(
        "CashFlowItemRevision",
        back_populates="item",
        order_by="CashFlowItemRevision.version",
        cascade="all, delete-orphan",
    )


class CashFlowItemRevision(Base):
    __tablename__ = "cash_flow_item_revisions"
    __table_args__ = (
        CheckConstraint(
            "event IN ('created', 'updated', 'confirmed', 'settled', 'cancelled', 'reopened')",
            name="valid_event",
        ),
        UniqueConstraint("item_id", "version", name="uq_cash_flow_item_revisions_item_version"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    item_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("cash_flow_items.id", ondelete="CASCADE"), nullable=False
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    event: Mapped[str] = mapped_column(String(16), nullable=False)
    snapshot: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )

    item: Mapped[CashFlowItem] = relationship("CashFlowItem", back_populates="revisions")
