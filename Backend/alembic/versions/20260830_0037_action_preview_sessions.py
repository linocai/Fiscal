"""Add shared preview sessions and replay receipts for v1.6 formal actions.

Revision ID: 20260830_0037
Revises: 20260823_0036
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260830_0037"
down_revision: str | None = "20260823_0036"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "action_preview_sessions",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("action", sa.String(length=32), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("data_revision", sa.BigInteger(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        sa.CheckConstraint("data_revision >= 0", name="data_revision_nonnegative"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_action_preview_sessions_expiry", "action_preview_sessions", ["expires_at"])
    op.create_table(
        "action_operations",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("preview_id", sa.UUID(), nullable=False),
        sa.Column("action", sa.String(length=32), nullable=False),
        sa.Column("idempotency_key", sa.UUID(), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("data_revision", sa.BigInteger(), nullable=False),
        sa.Column("receipt", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        sa.CheckConstraint("data_revision >= 0", name="data_revision_nonnegative"),
        sa.ForeignKeyConstraint(
            ["preview_id"], ["action_preview_sessions.id"], ondelete="RESTRICT"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("preview_id", name="uq_action_operations_preview"),
        sa.UniqueConstraint("idempotency_key", name="uq_action_operations_idempotency"),
    )


def downgrade() -> None:
    op.drop_table("action_operations")
    op.drop_index("ix_action_preview_sessions_expiry", table_name="action_preview_sessions")
    op.drop_table("action_preview_sessions")
