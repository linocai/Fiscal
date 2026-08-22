"""P26-A isolated redacted statement provider attempts.

Revision ID: 20260812_0026
Revises: 20260812_0025
Create Date: 2026-08-12
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260812_0026"
down_revision: str | None = "20260812_0025"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "statement_import_provider_attempts",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("statement_import_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("statement_import_attempt_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("idempotency_key", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("evidence_sha256", sa.String(length=64), nullable=False),
        sa.Column("provider", sa.String(length=40), nullable=False),
        sa.Column("provider_model", sa.String(length=200), nullable=False),
        sa.Column("prompt_version", sa.String(length=80), nullable=False),
        sa.Column("schema_version", sa.String(length=80), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(evidence_sha256) = 64", name="evidence_sha256_length"),
        sa.CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        sa.ForeignKeyConstraint(
            ["statement_import_id"], ["statement_imports.id"], ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(
            ["statement_import_attempt_id"], ["statement_import_attempts.id"], ondelete="RESTRICT"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "statement_import_attempt_id", name="uq_statement_provider_attempt_source"
        ),
        sa.UniqueConstraint("idempotency_key", name="uq_statement_provider_attempt_idempotency"),
    )
    op.create_table(
        "statement_import_provider_attempt_snapshots",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("provider_attempt_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("snapshot_kind", sa.String(length=24), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "snapshot_kind IN ('authorization','outbound_request','validated_result')",
            name="valid_snapshot_kind",
        ),
        sa.ForeignKeyConstraint(
            ["provider_attempt_id"], ["statement_import_provider_attempts.id"], ondelete="RESTRICT"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "provider_attempt_id", "snapshot_kind", name="uq_provider_attempt_snapshot_kind"
        ),
    )
    op.create_table(
        "statement_import_provider_snapshot_source_refs",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("provider_attempt_snapshot_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("statement_import_row_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("candidate_index", sa.Integer(), nullable=False),
        sa.CheckConstraint("candidate_index >= 0", name="candidate_index_nonnegative"),
        sa.ForeignKeyConstraint(
            ["provider_attempt_snapshot_id"],
            ["statement_import_provider_attempt_snapshots.id"],
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["statement_import_row_id"], ["statement_import_rows.id"], ondelete="RESTRICT"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "provider_attempt_snapshot_id",
            "candidate_index",
            "statement_import_row_id",
            name="uq_provider_snapshot_source_ref",
        ),
    )
    op.drop_constraint("valid_operation", "statement_import_operations", type_="check")
    op.create_check_constraint(
        "valid_operation",
        "statement_import_operations",
        "operation IN ('registered','attempt_started','evidence_received','provider_attempt_started','provider_attempt_succeeded','provider_attempt_failed','attempt_failed','abandoned')",
    )


def downgrade() -> None:
    # P25 cannot represent P26 attempt audit events. Removing the dependent P26 data and its
    # event markers is required before restoring the narrower historical check constraint.
    op.execute(
        "DELETE FROM statement_import_operations WHERE operation IN "
        "('provider_attempt_started','provider_attempt_succeeded','provider_attempt_failed')"
    )
    op.drop_constraint("valid_operation", "statement_import_operations", type_="check")
    op.create_check_constraint(
        "valid_operation",
        "statement_import_operations",
        "operation IN ('registered','attempt_started','evidence_received','attempt_failed','abandoned')",
    )
    op.drop_table("statement_import_provider_snapshot_source_refs")
    op.drop_table("statement_import_provider_attempt_snapshots")
    op.drop_table("statement_import_provider_attempts")
