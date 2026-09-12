from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, String, Uuid
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class CreditPayoffOperation(Base):
    __tablename__ = "credit_payoff_operations"
    __table_args__ = (CheckConstraint("status IN ('completed', 'reversed')", name="valid_status"),)
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    account_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), index=True
    )
    payment_account_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT")
    )
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, unique=True)
    request_hash: Mapped[str] = mapped_column(String(64))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    status: Mapped[str] = mapped_column(String(16), default="completed")
    payload: Mapped[dict[str, object]] = mapped_column(JSONB)
    receipt: Mapped[dict[str, object]] = mapped_column(JSONB)
    reverse_idempotency_key: Mapped[UUID | None] = mapped_column(Uuid, unique=True)
    reverse_request_hash: Mapped[str | None] = mapped_column(String(64))
    reversed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class CreditPayoffLink(Base):
    __tablename__ = "credit_payoff_links"
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    operation_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("credit_payoff_operations.id", ondelete="RESTRICT"), index=True
    )
    transaction_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), unique=True
    )
    role: Mapped[str] = mapped_column(String(32))
    credit_cycle_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("credit_cycles.id", ondelete="RESTRICT")
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
