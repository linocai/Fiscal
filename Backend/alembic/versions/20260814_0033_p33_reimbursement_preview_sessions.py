"""P33 binds reimbursement previews to their formal commits.

Revision ID: 20260814_0033
Revises: 20260814_0032
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260814_0033"
down_revision: str | None = "20260814_0032"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "reimbursement_previews",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("kind", sa.String(length=32), nullable=False),
        sa.Column("claim_id", sa.UUID(), nullable=False),
        sa.Column("receipt_id", sa.UUID(), nullable=True),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        sa.ForeignKeyConstraint(["claim_id"], ["reimbursement_claims.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["receipt_id"], ["reimbursement_receipts.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_reimbursement_previews_expiry", "reimbursement_previews", ["expires_at"])
    op.add_column("reimbursement_operations", sa.Column("preview_id", sa.UUID(), nullable=True))
    op.create_foreign_key(
        "fk_reimbursement_operations_preview_id_reimbursement_previews",
        "reimbursement_operations",
        "reimbursement_previews",
        ["preview_id"],
        ["id"],
        ondelete="RESTRICT",
    )
    op.create_unique_constraint(
        "uq_reimbursement_operations_preview_id", "reimbursement_operations", ["preview_id"]
    )


def downgrade() -> None:
    op.drop_constraint(
        "uq_reimbursement_operations_preview_id", "reimbursement_operations", type_="unique"
    )
    op.drop_constraint(
        "fk_reimbursement_operations_preview_id_reimbursement_previews",
        "reimbursement_operations",
        type_="foreignkey",
    )
    op.drop_column("reimbursement_operations", "preview_id")
    op.drop_index("ix_reimbursement_previews_expiry", table_name="reimbursement_previews")
    op.drop_table("reimbursement_previews")
