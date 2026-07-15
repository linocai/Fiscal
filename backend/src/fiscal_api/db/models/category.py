from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import JSON, CheckConstraint, ForeignKey, Index, String, Uuid, func, text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from fiscal_api.db.base import Base
from fiscal_api.db.models.common import MutableResourceMixin


class CategoryDirection(StrEnum):
    INCOME = "income"
    EXPENSE = "expense"


class Category(MutableResourceMixin, Base):
    __tablename__ = "categories"
    __table_args__ = (
        CheckConstraint("direction IN ('income', 'expense')", name="valid_direction"),
        CheckConstraint("color_hex ~ '^#[0-9A-F]{6}$'", name="valid_color_hex"),
        CheckConstraint("usage_count >= 0", name="usage_count_nonnegative"),
        CheckConstraint("version >= 1", name="version_positive"),
        Index(
            "uq_categories_active_sibling_name_ci",
            text("COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid)"),
            func.lower(text("name")),
            unique=True,
            postgresql_where=text("archived_at IS NULL"),
        ),
        Index("ix_categories_stable_order", "parent_id", "sort_order", "created_at", "id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    direction: Mapped[str] = mapped_column(String(16), nullable=False)
    parent_id: Mapped[UUID | None] = mapped_column(
        Uuid,
        ForeignKey("categories.id", ondelete="RESTRICT"),
        nullable=True,
    )
    icon: Mapped[str] = mapped_column(String(80), nullable=False)
    color_hex: Mapped[str] = mapped_column(String(7), nullable=False)
    aliases: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)
    examples: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)

    parent: Mapped["Category | None"] = relationship(
        "Category", remote_side="Category.id", back_populates="children"
    )
    children: Mapped[list["Category"]] = relationship(
        "Category",
        back_populates="parent",
        order_by="(Category.sort_order, Category.created_at, Category.id)",
    )
