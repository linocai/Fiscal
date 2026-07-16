"""Add database-backed P11 device-token lifecycle.

Revision ID: 20260716_0010
Revises: 20260716_0009
Create Date: 2026-07-16
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260716_0010"
down_revision: str | None = "20260716_0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "device_tokens",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("label", sa.String(length=80), nullable=False),
        sa.Column("role", sa.String(length=16), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("token_digest", sa.LargeBinary(length=32), nullable=False),
        sa.Column("fingerprint", sa.String(length=12), nullable=False),
        sa.Column("pepper_version", sa.SmallInteger(), nullable=False),
        sa.Column("version", sa.SmallInteger(), nullable=False),
        sa.Column("issued_by_id", sa.Uuid(), nullable=True),
        sa.Column("replaces_id", sa.Uuid(), nullable=True),
        sa.Column("pending_expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("activated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "octet_length(token_digest) = 32", name="ck_device_tokens_digest_length"
        ),
        sa.CheckConstraint(
            "char_length(fingerprint) = 12", name="ck_device_tokens_fingerprint_length"
        ),
        sa.CheckConstraint(
            "char_length(label) BETWEEN 1 AND 80", name="ck_device_tokens_label_length"
        ),
        sa.CheckConstraint(
            "(status='pending' AND activated_at IS NULL AND revoked_at IS NULL "
            "AND pending_expires_at IS NOT NULL) OR "
            "(status='active' AND activated_at IS NOT NULL AND revoked_at IS NULL) OR "
            "(status='revoked' AND revoked_at IS NOT NULL)",
            name="ck_device_tokens_lifecycle_consistent",
        ),
        sa.CheckConstraint("pepper_version >= 1", name="ck_device_tokens_pepper_version_positive"),
        sa.CheckConstraint("role IN ('device','operator')", name="ck_device_tokens_valid_role"),
        sa.CheckConstraint(
            "status IN ('pending','active','revoked')", name="ck_device_tokens_valid_status"
        ),
        sa.CheckConstraint("version >= 1", name="ck_device_tokens_version_positive"),
        sa.ForeignKeyConstraint(
            ["issued_by_id"],
            ["device_tokens.id"],
            name="fk_device_tokens_issued_by_id_device_tokens",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["replaces_id"],
            ["device_tokens.id"],
            name="fk_device_tokens_replaces_id_device_tokens",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_device_tokens"),
    )
    op.create_index(
        "ix_device_tokens_active_role",
        "device_tokens",
        ["role"],
        unique=False,
        postgresql_where=sa.text("status='active'"),
    )
    op.create_index(
        "ix_device_tokens_status_created",
        "device_tokens",
        ["status", sa.text("created_at DESC")],
        unique=False,
    )
    op.create_index("uq_device_tokens_digest", "device_tokens", ["token_digest"], unique=True)
    op.create_index("uq_device_tokens_fingerprint", "device_tokens", ["fingerprint"], unique=True)


def downgrade() -> None:
    op.execute(
        "DO $$ BEGIN IF EXISTS(SELECT 1 FROM device_tokens) THEN "
        "RAISE EXCEPTION 'P11 downgrade blocked: device token records exist' "
        "USING ERRCODE='object_not_in_prerequisite_state'; END IF; END $$"
    )
    op.drop_index("uq_device_tokens_fingerprint", table_name="device_tokens")
    op.drop_index("uq_device_tokens_digest", table_name="device_tokens")
    op.drop_index("ix_device_tokens_status_created", table_name="device_tokens")
    op.drop_index("ix_device_tokens_active_role", table_name="device_tokens")
    op.drop_table("device_tokens")
