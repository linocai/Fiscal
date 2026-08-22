"""Add P2 account and category master data.

Revision ID: 20260715_0002
Revises: 20260714_0001
Create Date: 2026-07-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260715_0002"
down_revision: str | None = "20260714_0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "accounts",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=80), nullable=False),
        sa.Column("kind", sa.String(length=16), nullable=False),
        sa.Column("institution", sa.String(length=80), nullable=True),
        sa.Column("last_four", sa.String(length=4), nullable=True),
        sa.Column("opening_balance_minor", sa.BigInteger(), nullable=False),
        sa.Column("credit_limit_minor", sa.BigInteger(), nullable=True),
        sa.Column("statement_day", sa.Integer(), nullable=True),
        sa.Column("due_day", sa.Integer(), nullable=True),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("usage_count", sa.Integer(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("kind IN ('cash', 'debit', 'credit')", name="valid_kind"),
        sa.CheckConstraint("usage_count >= 0", name="usage_count_nonnegative"),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.CheckConstraint(
            "last_four IS NULL OR last_four ~ '^[0-9]{4}$'",
            name="last_four_ascii_digits",
        ),
        sa.CheckConstraint(
            "(kind = 'credit' AND credit_limit_minor > 0 "
            "AND statement_day BETWEEN 1 AND 28 AND due_day BETWEEN 1 AND 28 "
            "AND opening_balance_minor >= 0 AND opening_balance_minor <= credit_limit_minor) "
            "OR (kind IN ('cash', 'debit') AND credit_limit_minor IS NULL "
            "AND statement_day IS NULL AND due_day IS NULL)",
            name="kind_configuration",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_accounts"),
    )
    op.create_index(
        "uq_accounts_active_name_ci",
        "accounts",
        [sa.text("lower(name)")],
        unique=True,
        postgresql_where=sa.text("archived_at IS NULL"),
    )
    op.create_index("ix_accounts_stable_order", "accounts", ["sort_order", "created_at", "id"])

    op.create_table(
        "categories",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=80), nullable=False),
        sa.Column("direction", sa.String(length=16), nullable=False),
        sa.Column("parent_id", sa.Uuid(), nullable=True),
        sa.Column("icon", sa.String(length=80), nullable=False),
        sa.Column("color_hex", sa.String(length=7), nullable=False),
        sa.Column("aliases", sa.JSON(), nullable=False),
        sa.Column("examples", sa.JSON(), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("usage_count", sa.Integer(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("direction IN ('income', 'expense')", name="valid_direction"),
        sa.CheckConstraint("color_hex ~ '^#[0-9A-F]{6}$'", name="valid_color_hex"),
        sa.CheckConstraint("usage_count >= 0", name="usage_count_nonnegative"),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.ForeignKeyConstraint(
            ["parent_id"],
            ["categories.id"],
            name="fk_categories_parent_id_categories",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_categories"),
    )
    op.create_index(
        "uq_categories_active_sibling_name_ci",
        "categories",
        [
            sa.text("COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid)"),
            sa.text("lower(name)"),
        ],
        unique=True,
        postgresql_where=sa.text("archived_at IS NULL"),
    )
    op.create_index(
        "ix_categories_stable_order",
        "categories",
        ["parent_id", "sort_order", "created_at", "id"],
    )


def downgrade() -> None:
    op.drop_index("ix_categories_stable_order", table_name="categories")
    op.drop_index("uq_categories_active_sibling_name_ci", table_name="categories")
    op.drop_table("categories")
    op.drop_index("ix_accounts_stable_order", table_name="accounts")
    op.drop_index("uq_accounts_active_name_ci", table_name="accounts")
    op.drop_table("accounts")
