"""Add durable Agent import batches.

Revision ID: 20261010_0043
Revises: 20260926_0042
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20261010_0043"
down_revision: str | None = "20260926_0042"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "import_batches",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("source", sa.String(length=16), nullable=False),
        sa.Column("original_content_sha256", sa.String(length=64), nullable=False),
        sa.Column("idempotency_key", sa.String(length=128), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("candidates", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("validation_errors", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("transaction_receipts", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("ignored_reason", sa.String(length=240), nullable=True),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("validated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("committed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("ignored_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "source IN ('text','structured','ocr','shortcut_text')",
            name="ck_import_batches_valid_source",
        ),
        sa.CheckConstraint(
            "status IN ('pending','validated','ignored','committed','failed')",
            name="ck_import_batches_valid_status",
        ),
        sa.CheckConstraint(
            "char_length(original_content_sha256) = 64",
            name="ck_import_batches_fingerprint_length",
        ),
        sa.CheckConstraint(
            "char_length(request_hash) = 64",
            name="ck_import_batches_request_hash_length",
        ),
        sa.CheckConstraint("version >= 1", name="ck_import_batches_version_positive"),
        sa.PrimaryKeyConstraint("id", name="pk_import_batches"),
        sa.UniqueConstraint("idempotency_key", name="uq_import_batches_idempotency_key"),
    )
    op.create_index(
        "ix_import_batches_timeline",
        "import_batches",
        [sa.text("created_at DESC"), sa.text("id DESC")],
    )
    op.create_index(
        "ix_import_batches_status_timeline",
        "import_batches",
        ["status", sa.text("created_at DESC")],
    )


def downgrade() -> None:
    op.drop_index("ix_import_batches_status_timeline", table_name="import_batches")
    op.drop_index("ix_import_batches_timeline", table_name="import_batches")
    op.drop_table("import_batches")
