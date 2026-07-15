from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import BigInteger, CheckConstraint, Index, Integer, String, Uuid, func, text
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.db.base import Base
from fiscal_api.db.models.common import MutableResourceMixin


class AccountKind(StrEnum):
    CASH = "cash"
    DEBIT = "debit"
    CREDIT = "credit"


class Account(MutableResourceMixin, Base):
    __tablename__ = "accounts"
    __table_args__ = (
        CheckConstraint("kind IN ('cash', 'debit', 'credit')", name="valid_kind"),
        CheckConstraint("usage_count >= 0", name="usage_count_nonnegative"),
        CheckConstraint("version >= 1", name="version_positive"),
        CheckConstraint(
            "last_four IS NULL OR last_four ~ '^[0-9]{4}$'", name="last_four_ascii_digits"
        ),
        CheckConstraint(
            "(kind = 'credit' AND credit_limit_minor > 0 "
            "AND statement_day BETWEEN 1 AND 28 AND due_day BETWEEN 1 AND 28 "
            "AND opening_balance_minor >= 0 AND opening_balance_minor <= credit_limit_minor) "
            "OR (kind IN ('cash', 'debit') AND credit_limit_minor IS NULL "
            "AND statement_day IS NULL AND due_day IS NULL)",
            name="kind_configuration",
        ),
        Index(
            "uq_accounts_active_name_ci",
            func.lower(text("name")),
            unique=True,
            postgresql_where=text("archived_at IS NULL"),
        ),
        Index("ix_accounts_stable_order", "sort_order", "created_at", "id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    institution: Mapped[str | None] = mapped_column(String(80), nullable=True)
    last_four: Mapped[str | None] = mapped_column(String(4), nullable=True)
    opening_balance_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    credit_limit_minor: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    statement_day: Mapped[int | None] = mapped_column(Integer, nullable=True)
    due_day: Mapped[int | None] = mapped_column(Integer, nullable=True)
