"""P31 merchant normalization and category transformation contracts.

Revision ID: 20260814_0030
Revises: 20260813_0029
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260814_0030"
down_revision: str | None = "20260813_0029"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "merchants",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(name) BETWEEN 1 AND 120", name="name_length"),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "merchant_identifiers",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("merchant_id", sa.UUID(), nullable=False),
        sa.Column("normalized_key", sa.String(length=240), nullable=False),
        sa.Column("display_value", sa.String(length=120), nullable=False),
        sa.Column("kind", sa.String(length=16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(display_value) BETWEEN 1 AND 120", name="value_length"),
        sa.CheckConstraint("kind IN ('canonical', 'alias')", name="valid_kind"),
        sa.ForeignKeyConstraint(["merchant_id"], ["merchants.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("normalized_key", name="uq_merchant_identifiers_normalized_key"),
    )
    op.create_index(
        "uq_merchant_identifiers_one_canonical",
        "merchant_identifiers",
        ["merchant_id"],
        unique=True,
        postgresql_where=sa.text("kind = 'canonical'"),
    )
    op.create_table(
        "transaction_merchant_mappings",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("transaction_id", sa.UUID(), nullable=False),
        sa.Column("merchant_id", sa.UUID(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("confirmed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.ForeignKeyConstraint(["merchant_id"], ["merchants.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["transaction_id"], ["transactions.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("transaction_id", name="uq_transaction_merchant_mapping_transaction"),
    )
    op.create_index(
        "ix_transaction_merchant_mappings_merchant_id",
        "transaction_merchant_mappings",
        ["merchant_id"],
    )
    op.create_table(
        "merchant_operations",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("idempotency_key", sa.UUID(), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("action", sa.String(length=32), nullable=False),
        sa.Column("receipt", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("idempotency_key", name="uq_merchant_operations_idempotency"),
    )
    op.create_table(
        "category_transform_previews",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("kind", sa.String(length=16), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "category_transform_operations",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("preview_id", sa.UUID(), nullable=False),
        sa.Column("idempotency_key", sa.UUID(), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("receipt", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        sa.ForeignKeyConstraint(
            ["preview_id"], ["category_transform_previews.id"], ondelete="RESTRICT"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("idempotency_key", name="uq_category_transform_operations_idempotency"),
    )


def downgrade() -> None:
    op.drop_table("category_transform_operations")
    op.drop_table("category_transform_previews")
    op.drop_table("merchant_operations")
    op.drop_index(
        "ix_transaction_merchant_mappings_merchant_id", table_name="transaction_merchant_mappings"
    )
    op.drop_table("transaction_merchant_mappings")
    op.drop_index("uq_merchant_identifiers_one_canonical", table_name="merchant_identifiers")
    op.drop_table("merchant_identifiers")
    op.drop_table("merchants")
