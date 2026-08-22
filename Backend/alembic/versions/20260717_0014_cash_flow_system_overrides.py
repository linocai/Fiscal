"""Make system cash-flow items editable and completable.

Revision ID: 20260717_0014
Revises: 20260717_0013
Create Date: 2026-07-17
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260717_0014"
down_revision: str | None = "20260717_0013"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_constraint(op.f("ck_cash_flow_items_valid_status"), "cash_flow_items", type_="check")
    op.create_check_constraint(
        "valid_status",
        "cash_flow_items",
        "status IN ('expected', 'confirmed', 'settled', 'cancelled', 'completed')",
    )
    op.create_table(
        "cash_flow_system_overrides",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("system_kind", sa.String(24), nullable=False),
        sa.Column("system_reference_id", sa.Uuid(), nullable=False),
        sa.Column("title", sa.String(120), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("direction", sa.String(16), nullable=False),
        sa.Column("planned_amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("expected_date", sa.Date(), nullable=False),
        sa.Column("account_id", sa.Uuid(), nullable=True),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "system_kind IN ('credit_cycle', 'reimbursement')",
            name=op.f("ck_cash_flow_system_overrides_valid_system_kind"),
        ),
        sa.CheckConstraint(
            "status IN ('confirmed', 'completed')",
            name=op.f("ck_cash_flow_system_overrides_valid_status"),
        ),
        sa.CheckConstraint(
            "direction IN ('inflow', 'outflow')",
            name=op.f("ck_cash_flow_system_overrides_valid_direction"),
        ),
        sa.CheckConstraint(
            "planned_amount_minor > 0",
            name=op.f("ck_cash_flow_system_overrides_planned_amount_positive"),
        ),
        sa.CheckConstraint(
            "version >= 1", name=op.f("ck_cash_flow_system_overrides_version_positive")
        ),
        sa.CheckConstraint(
            "char_length(title) BETWEEN 1 AND 120",
            name=op.f("ck_cash_flow_system_overrides_title_length"),
        ),
        sa.CheckConstraint(
            "note IS NULL OR char_length(note) <= 500",
            name=op.f("ck_cash_flow_system_overrides_note_length"),
        ),
        sa.ForeignKeyConstraint(
            ["account_id"],
            ["accounts.id"],
            name=op.f("fk_cash_flow_system_overrides_account_id_accounts"),
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_cash_flow_system_overrides")),
        sa.UniqueConstraint(
            "system_kind",
            "system_reference_id",
            name="uq_cash_flow_system_override_source",
        ),
    )
    op.create_index(
        "ix_cash_flow_system_override_history",
        "cash_flow_system_overrides",
        ["status", "completed_at"],
    )


def downgrade() -> None:
    op.execute(
        """
        DO $$ BEGIN
          IF EXISTS (SELECT 1 FROM cash_flow_system_overrides) THEN
            RAISE EXCEPTION 'P14 downgrade blocked: system cash-flow overrides exist';
          END IF;
        END $$;
        """
    )
    op.drop_index("ix_cash_flow_system_override_history", table_name="cash_flow_system_overrides")
    op.drop_table("cash_flow_system_overrides")
    op.drop_constraint(op.f("ck_cash_flow_items_valid_status"), "cash_flow_items", type_="check")
    op.create_check_constraint(
        "valid_status",
        "cash_flow_items",
        "status IN ('expected', 'confirmed', 'settled', 'cancelled')",
    )
