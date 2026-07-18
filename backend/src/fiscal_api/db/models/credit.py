from datetime import date, datetime
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    UniqueConstraint,
    Uuid,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class CreditCycleStatus(StrEnum):
    OPEN = "open"
    SETTLED = "settled"
    PARTIAL = "partial"
    UNPAID = "unpaid"
    OVERDUE = "overdue"


class CreditCycle(Base):
    __tablename__ = "credit_cycles"
    __table_args__ = (
        CheckConstraint("period_start <= period_end", name="valid_period"),
        CheckConstraint("statement_date >= period_end", name="statement_not_before_period_end"),
        CheckConstraint("due_date >= statement_date", name="due_not_before_statement"),
        CheckConstraint("version = 1", name="immutable_version"),
        UniqueConstraint(
            "account_id", "period_start", "period_end", name="uq_credit_cycles_account_period"
        ),
        Index(
            "uq_credit_cycles_opening_account",
            "account_id",
            unique=True,
            postgresql_where=text("is_opening_cycle"),
        ),
        Index("ix_credit_cycles_timeline", "account_id", text("period_end DESC"), text("id DESC")),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    account_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False
    )
    period_start: Mapped[date] = mapped_column(Date, nullable=False)
    period_end: Mapped[date] = mapped_column(Date, nullable=False)
    statement_date: Mapped[date] = mapped_column(Date, nullable=False)
    due_date: Mapped[date] = mapped_column(Date, nullable=False)
    is_opening_cycle: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
