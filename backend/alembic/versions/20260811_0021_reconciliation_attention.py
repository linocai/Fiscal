"""P21 reconciliation evidence and derived-attention dismissals.

Checkpoint rows are new evidence only: no historical balance is inferred or
backfilled, and this migration does not touch transactions or postings.

Revision ID: 20260811_0021
Revises: 20260811_0020
Create Date: 2026-08-11
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260811_0021"
down_revision: str | None = "20260811_0020"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "reconciliation_checkpoints",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("target_kind", sa.String(length=16), nullable=False),
        sa.Column("account_id", sa.Uuid(), nullable=True),
        sa.Column("credit_cycle_id", sa.Uuid(), nullable=True),
        sa.Column("as_of", sa.DateTime(timezone=True), nullable=False),
        sa.Column("actual_balance_minor", sa.BigInteger(), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("target_kind IN ('account', 'credit_cycle')", name="valid_target_kind"),
        sa.CheckConstraint(
            "(target_kind = 'account' AND account_id IS NOT NULL AND credit_cycle_id IS NULL) OR (target_kind = 'credit_cycle' AND account_id IS NULL AND credit_cycle_id IS NOT NULL)",
            name="target_shape",
        ),
        sa.ForeignKeyConstraint(["account_id"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["credit_cycle_id"], ["credit_cycles.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_reconciliation_checkpoints_target_time",
        "reconciliation_checkpoints",
        ["account_id", "credit_cycle_id", "as_of"],
    )
    op.create_table(
        "attention_dismissals",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("source_type", sa.String(length=48), nullable=False),
        sa.Column("source_id", sa.Uuid(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("source_type", "source_id", name="uq_attention_dismissal_source"),
    )


def downgrade() -> None:
    op.drop_table("attention_dismissals")
    op.drop_index(
        "ix_reconciliation_checkpoints_target_time", table_name="reconciliation_checkpoints"
    )
    op.drop_table("reconciliation_checkpoints")
