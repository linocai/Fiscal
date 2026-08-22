from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class Merchant(Base):
    """A user-visible counterparty; never a replacement for transaction evidence."""

    __tablename__ = "merchants"
    __table_args__ = (
        CheckConstraint("char_length(name) BETWEEN 1 AND 120", name="name_length"),
        CheckConstraint("version >= 1", name="version_positive"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )


class MerchantIdentifier(Base):
    """The single, permanently reserved namespace for merchant names and aliases."""

    __tablename__ = "merchant_identifiers"
    __table_args__ = (
        CheckConstraint("char_length(display_value) BETWEEN 1 AND 120", name="value_length"),
        CheckConstraint("kind IN ('canonical', 'alias')", name="valid_kind"),
        UniqueConstraint("normalized_key", name="uq_merchant_identifiers_normalized_key"),
        Index(
            "uq_merchant_identifiers_one_canonical",
            "merchant_id",
            unique=True,
            postgresql_where="kind = 'canonical'",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    merchant_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("merchants.id", ondelete="RESTRICT"), nullable=False
    )
    normalized_key: Mapped[str] = mapped_column(String(240), nullable=False)
    display_value: Mapped[str] = mapped_column(String(120), nullable=False)
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class TransactionMerchantMapping(Base):
    """Confirmed analysis relationship.  Ledger evidence itself remains untouched."""

    __tablename__ = "transaction_merchant_mappings"
    __table_args__ = (
        CheckConstraint("version >= 1", name="version_positive"),
        UniqueConstraint("transaction_id", name="uq_transaction_merchant_mapping_transaction"),
        Index("ix_transaction_merchant_mappings_merchant_id", "merchant_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    transaction_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=False
    )
    merchant_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("merchants.id", ondelete="RESTRICT"), nullable=False
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    confirmed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )


class MerchantOperation(Base):
    """Idempotent receipts for merchant mapping confirmations/corrections/releases."""

    __tablename__ = "merchant_operations"
    __table_args__ = (
        CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        UniqueConstraint("idempotency_key", name="uq_merchant_operations_idempotency"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    action: Mapped[str] = mapped_column(String(32), nullable=False)
    receipt: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
