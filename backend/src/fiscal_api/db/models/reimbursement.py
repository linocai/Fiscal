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
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class ReimbursementClaimStatus(StrEnum):
    DRAFT = "draft"
    PENDING = "pending"
    PARTIAL_RECEIVED = "partial_received"
    RECEIVED = "received"
    CANCELLED = "cancelled"
    PARTIALLY_RECEIVED_CANCELLED = "partially_received_cancelled"


class ReimbursementRelationRole(StrEnum):
    EXPENSE = "expense"
    RECEIPT = "receipt"


class ReimbursementClaim(Base):
    __tablename__ = "reimbursement_claims"
    __table_args__ = (
        CheckConstraint("char_length(title) BETWEEN 1 AND 120", name="title_length"),
        CheckConstraint("note IS NULL OR char_length(note) <= 500", name="note_length"),
        CheckConstraint("version >= 1", name="version_positive"),
        UniqueConstraint(
            "create_idempotency_key",
            name="uq_reimbursement_claims_create_idempotency_key",
        ),
        Index("ix_reimbursement_claims_timeline", text("created_at DESC"), text("id DESC")),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    title: Mapped[str] = mapped_column(String(120), nullable=False)
    note: Mapped[str | None] = mapped_column(Text)
    submitted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    voided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    create_idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    create_request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
    parties: Mapped[list["ReimbursementParty"]] = relationship(
        back_populates="claim",
        order_by="(ReimbursementParty.position, ReimbursementParty.id)",
        cascade="all, delete-orphan",
    )
    allocations: Mapped[list["ReimbursementAllocation"]] = relationship(
        back_populates="claim",
        order_by="(ReimbursementAllocation.position, ReimbursementAllocation.id)",
        cascade="all, delete-orphan",
    )
    receipts: Mapped[list["ReimbursementReceipt"]] = relationship(
        back_populates="claim",
        order_by="(ReimbursementReceipt.created_at, ReimbursementReceipt.id)",
        cascade="all, delete-orphan",
    )


class ReimbursementParty(Base):
    __tablename__ = "reimbursement_parties"
    __table_args__ = (
        CheckConstraint("char_length(name) BETWEEN 1 AND 120", name="name_length"),
        CheckConstraint("note IS NULL OR char_length(note) <= 500", name="note_length"),
        CheckConstraint("position >= 0", name="position_nonnegative"),
        UniqueConstraint("claim_id", "position", name="uq_reimbursement_parties_position"),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    claim_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("reimbursement_claims.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    expected_date: Mapped[date | None] = mapped_column(Date)
    note: Mapped[str | None] = mapped_column(Text)
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    claim: Mapped[ReimbursementClaim] = relationship(back_populates="parties")


class ReimbursementAllocation(Base):
    __tablename__ = "reimbursement_allocations"
    __table_args__ = (
        CheckConstraint("amount_minor > 0", name="amount_positive"),
        CheckConstraint("position >= 0", name="position_nonnegative"),
        UniqueConstraint(
            "claim_id", "party_id", "transaction_id", name="uq_reimbursement_allocations_matrix"
        ),
        UniqueConstraint("claim_id", "position", name="uq_reimbursement_allocations_position"),
        Index("ix_reimbursement_allocations_transaction", "transaction_id"),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    claim_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("reimbursement_claims.id", ondelete="CASCADE"), nullable=False
    )
    party_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("reimbursement_parties.id", ondelete="RESTRICT"), nullable=False
    )
    transaction_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=False
    )
    amount_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    claim: Mapped[ReimbursementClaim] = relationship(back_populates="allocations")


class ReimbursementReceipt(Base):
    __tablename__ = "reimbursement_receipts"
    __table_args__ = (
        CheckConstraint("version >= 1", name="version_positive"),
        UniqueConstraint("transaction_id", name="uq_reimbursement_receipts_transaction_id"),
        Index("ix_reimbursement_receipts_claim", "claim_id", text("created_at DESC")),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    claim_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("reimbursement_claims.id", ondelete="RESTRICT"), nullable=False
    )
    party_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("reimbursement_parties.id", ondelete="RESTRICT"), nullable=False
    )
    transaction_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=False
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
    claim: Mapped[ReimbursementClaim] = relationship(back_populates="receipts")
    allocations: Mapped[list["ReimbursementReceiptAllocation"]] = relationship(
        back_populates="receipt",
        order_by="(ReimbursementReceiptAllocation.position, ReimbursementReceiptAllocation.id)",
        cascade="all, delete-orphan",
    )


class ReimbursementReceiptAllocation(Base):
    __tablename__ = "reimbursement_receipt_allocations"
    __table_args__ = (
        CheckConstraint("amount_minor > 0", name="amount_positive"),
        CheckConstraint("position >= 0", name="position_nonnegative"),
        UniqueConstraint(
            "receipt_id", "allocation_id", name="uq_reimbursement_receipt_allocations_row"
        ),
        UniqueConstraint(
            "receipt_id", "position", name="uq_reimbursement_receipt_allocations_position"
        ),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    receipt_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("reimbursement_receipts.id", ondelete="CASCADE"), nullable=False
    )
    allocation_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("reimbursement_allocations.id", ondelete="RESTRICT"), nullable=False
    )
    amount_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    receipt: Mapped[ReimbursementReceipt] = relationship(back_populates="allocations")


class ReimbursementClaimRevision(Base):
    __tablename__ = "reimbursement_claim_revisions"
    __table_args__ = (
        UniqueConstraint("claim_id", "version", name="uq_reimbursement_claim_revisions_version"),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    claim_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("reimbursement_claims.id", ondelete="CASCADE"), nullable=False
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    event: Mapped[str] = mapped_column(String(32), nullable=False)
    snapshot: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class ReimbursementReceiptRevision(Base):
    __tablename__ = "reimbursement_receipt_revisions"
    __table_args__ = (
        UniqueConstraint(
            "receipt_id", "version", name="uq_reimbursement_receipt_revisions_version"
        ),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    receipt_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("reimbursement_receipts.id", ondelete="CASCADE"), nullable=False
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    event: Mapped[str] = mapped_column(String(32), nullable=False)
    snapshot: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class ReimbursementOperation(Base):
    __tablename__ = "reimbursement_operations"
    __table_args__ = (
        UniqueConstraint("idempotency_key", name="uq_reimbursement_operations_idempotency_key"),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    claim_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("reimbursement_claims.id", ondelete="RESTRICT"), nullable=False
    )
    receipt_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("reimbursement_receipts.id", ondelete="RESTRICT")
    )
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    result_snapshot: Mapped[dict[str, object] | None] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
