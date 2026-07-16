from datetime import datetime
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
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


class TransactionKind(StrEnum):
    INCOME = "income"
    EXPENSE = "expense"
    TRANSFER = "transfer"
    CREDIT_PURCHASE = "credit_purchase"
    REPAYMENT = "repayment"
    INSTALLMENT_FEE = "installment_fee"
    INSTALLMENT_REFUND = "installment_refund"
    REIMBURSEMENT_RECEIPT = "reimbursement_receipt"


class PostingRole(StrEnum):
    ACCOUNT = "account"
    SOURCE = "source"
    DESTINATION = "destination"


class RevisionEvent(StrEnum):
    CREATED = "created"
    UPDATED = "updated"
    VOIDED = "voided"
    RESTORED = "restored"


class TransactionSource(StrEnum):
    MANUAL = "manual"
    SYSTEM = "system"
    AI_TEXT = "ai_text"


class LedgerTransaction(Base):
    __tablename__ = "transactions"
    __table_args__ = (
        CheckConstraint(
            "kind IN ('income', 'expense', 'transfer', 'credit_purchase', 'repayment', "
            "'installment_fee', 'installment_refund', 'reimbursement_receipt')",
            name="valid_kind",
        ),
        CheckConstraint("source IN ('manual', 'system', 'ai_text')", name="valid_source"),
        CheckConstraint("version >= 1", name="version_positive"),
        CheckConstraint("char_length(title) BETWEEN 1 AND 120", name="title_length"),
        CheckConstraint("note IS NULL OR char_length(note) <= 500", name="note_length"),
        UniqueConstraint("idempotency_key", name="uq_transactions_idempotency_key"),
        Index("ix_transactions_timeline", text("occurred_at DESC"), text("id DESC")),
        Index("ix_transactions_category_id", "category_id"),
        Index("ix_transactions_credit_cycle_id", "credit_cycle_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    title: Mapped[str] = mapped_column(String(120), nullable=False)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    category_id: Mapped[UUID | None] = mapped_column(
        Uuid,
        ForeignKey("categories.id", ondelete="RESTRICT"),
        nullable=True,
    )
    credit_cycle_id: Mapped[UUID | None] = mapped_column(
        Uuid,
        ForeignKey("credit_cycles.id", ondelete="RESTRICT"),
        nullable=True,
    )
    source: Mapped[str] = mapped_column(String(16), nullable=False, default="manual")
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    voided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )

    postings: Mapped[list["Posting"]] = relationship(
        "Posting",
        back_populates="transaction",
        order_by="(Posting.position, Posting.id)",
        cascade="all, delete-orphan",
    )
    revisions: Mapped[list["TransactionRevision"]] = relationship(
        "TransactionRevision",
        back_populates="transaction",
        order_by="TransactionRevision.version",
        cascade="all, delete-orphan",
    )


class Posting(Base):
    __tablename__ = "postings"
    __table_args__ = (
        CheckConstraint("role IN ('account', 'source', 'destination')", name="valid_role"),
        CheckConstraint("amount_minor <> 0", name="amount_nonzero"),
        CheckConstraint("position >= 0", name="position_nonnegative"),
        UniqueConstraint("transaction_id", "account_id", name="uq_postings_transaction_account"),
        UniqueConstraint("transaction_id", "role", name="uq_postings_transaction_role"),
        UniqueConstraint("transaction_id", "position", name="uq_postings_transaction_position"),
        Index("ix_postings_account_id", "account_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    transaction_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("transactions.id", ondelete="CASCADE"),
        nullable=False,
    )
    account_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("accounts.id", ondelete="RESTRICT"),
        nullable=False,
    )
    role: Mapped[str] = mapped_column(String(16), nullable=False)
    amount_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    position: Mapped[int] = mapped_column(Integer, nullable=False)

    transaction: Mapped[LedgerTransaction] = relationship(
        "LedgerTransaction", back_populates="postings"
    )


class TransactionRevision(Base):
    __tablename__ = "transaction_revisions"
    __table_args__ = (
        CheckConstraint(
            "event IN ('created', 'updated', 'voided', 'restored')", name="valid_event"
        ),
        UniqueConstraint(
            "transaction_id", "version", name="uq_transaction_revisions_transaction_version"
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    transaction_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("transactions.id", ondelete="CASCADE"),
        nullable=False,
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    event: Mapped[str] = mapped_column(String(16), nullable=False)
    snapshot: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )

    transaction: Mapped[LedgerTransaction] = relationship(
        "LedgerTransaction", back_populates="revisions"
    )
