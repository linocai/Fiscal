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
    UniqueConstraint,
    Uuid,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class InstallmentPlanLifecycle(StrEnum):
    ACTIVE = "active"
    SETTLED_EARLY = "settled_early"
    PARTIALLY_CANCELLED = "partially_cancelled"
    CANCELLED = "cancelled"


class InstallmentLedgerRole(StrEnum):
    PURCHASE = "purchase"
    FEE = "fee"
    PRINCIPAL_REFUND = "principal_refund"
    FEE_REFUND = "fee_refund"
    SETTLEMENT_REPAYMENT = "settlement_repayment"


class InstallmentOperationKind(StrEnum):
    SETTLE_EARLY = "settle_early"
    REVERSE_SETTLEMENT = "reverse_settlement"
    CANCEL_FUTURE = "cancel_future"


class InstallmentPlan(Base):
    __tablename__ = "installment_plans"
    __table_args__ = (
        CheckConstraint("installment_count BETWEEN 2 AND 60", name="count_range"),
        CheckConstraint(
            "lifecycle IN ('active','settled_early','partially_cancelled','cancelled')",
            name="valid_lifecycle",
        ),
        CheckConstraint("version >= 1", name="version_positive"),
        UniqueConstraint("purchase_transaction_id", name="uq_installment_plans_purchase"),
        UniqueConstraint("create_idempotency_key", name="uq_installment_plans_idempotency"),
        Index("ix_installment_plans_account", "credit_account_id", text("created_at DESC")),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    purchase_transaction_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=False
    )
    credit_account_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False
    )
    fee_transaction_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT")
    )
    fee_category_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("categories.id", ondelete="RESTRICT")
    )
    installment_count: Mapped[int] = mapped_column(Integer, nullable=False)
    start_cycle_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("credit_cycles.id", ondelete="RESTRICT"), nullable=False
    )
    lifecycle: Mapped[str] = mapped_column(String(24), nullable=False, default="active")
    create_idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    create_request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
    periods: Mapped[list["InstallmentPeriod"]] = relationship(
        back_populates="plan", order_by="InstallmentPeriod.sequence", cascade="all, delete-orphan"
    )


class InstallmentPeriod(Base):
    __tablename__ = "installment_periods"
    __table_args__ = (
        CheckConstraint("sequence >= 1", name="sequence_positive"),
        CheckConstraint(
            "principal_minor >= 0 AND fee_minor >= 0 AND principal_minor + fee_minor > 0",
            name="nonzero_allocation",
        ),
        CheckConstraint("version >= 1", name="version_positive"),
        UniqueConstraint("plan_id", "sequence", name="uq_installment_periods_plan_sequence"),
        Index("ix_installment_periods_effective_cycle", "effective_cycle_id"),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    plan_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("installment_plans.id", ondelete="CASCADE"), nullable=False
    )
    sequence: Mapped[int] = mapped_column(Integer, nullable=False)
    scheduled_cycle_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("credit_cycles.id", ondelete="RESTRICT"), nullable=False
    )
    effective_cycle_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("credit_cycles.id", ondelete="RESTRICT"), nullable=False
    )
    principal_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    fee_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    settled_early_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
    plan: Mapped[InstallmentPlan] = relationship(back_populates="periods")


class InstallmentOperation(Base):
    __tablename__ = "installment_operations"
    __table_args__ = (
        CheckConstraint(
            "kind IN ('settle_early','reverse_settlement','cancel_future')", name="valid_kind"
        ),
        UniqueConstraint("idempotency_key", name="uq_installment_operations_idempotency"),
        Index("ix_installment_operations_plan", "plan_id", text("created_at DESC")),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    plan_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("installment_plans.id", ondelete="RESTRICT"), nullable=False
    )
    kind: Mapped[str] = mapped_column(String(24), nullable=False)
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    target_statement_date: Mapped[date | None] = mapped_column(Date)
    payment_account_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT")
    )
    occurred_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    reversed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    result_snapshot: Mapped[dict[str, object] | None] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class InstallmentLedgerLink(Base):
    __tablename__ = "installment_ledger_links"
    __table_args__ = (
        CheckConstraint(
            "role IN ('purchase','fee','principal_refund','fee_refund','settlement_repayment')",
            name="valid_role",
        ),
        UniqueConstraint("transaction_id", name="uq_installment_ledger_links_transaction"),
        Index(
            "uq_installment_ledger_links_plan_purchase",
            "plan_id",
            unique=True,
            postgresql_where=text("role = 'purchase'"),
        ),
        Index(
            "uq_installment_ledger_links_plan_fee",
            "plan_id",
            unique=True,
            postgresql_where=text("role = 'fee'"),
        ),
        Index(
            "uq_installment_ledger_links_operation_role",
            "operation_id",
            "role",
            unique=True,
            postgresql_where=text("operation_id IS NOT NULL"),
        ),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    transaction_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=False
    )
    plan_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("installment_plans.id", ondelete="RESTRICT"), nullable=False
    )
    operation_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("installment_operations.id", ondelete="RESTRICT")
    )
    role: Mapped[str] = mapped_column(String(32), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class InstallmentPlanRevision(Base):
    __tablename__ = "installment_plan_revisions"
    __table_args__ = (
        UniqueConstraint("plan_id", "version", name="uq_installment_plan_revisions_version"),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    plan_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("installment_plans.id", ondelete="CASCADE"), nullable=False
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    event: Mapped[str] = mapped_column(String(32), nullable=False)
    snapshot: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
