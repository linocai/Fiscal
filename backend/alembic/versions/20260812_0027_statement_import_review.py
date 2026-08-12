"""P27-A immutable statement-import validation and review drafts.

Revision ID: 20260812_0027
Revises: 20260812_0026
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260812_0027"
down_revision: str | None = "20260812_0026"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "statement_import_validation_runs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "statement_import_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_imports.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "provider_snapshot_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_import_provider_attempt_snapshots.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("evidence_sha256", sa.String(64), nullable=False),
        sa.Column("algorithm_version", sa.String(64), nullable=False),
        sa.Column("batch_version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(evidence_sha256) = 64", name="evidence_sha256_length"),
        sa.CheckConstraint(
            "char_length(algorithm_version) BETWEEN 1 AND 64", name="algorithm_version_length"
        ),
        sa.UniqueConstraint(
            "provider_snapshot_id",
            "evidence_sha256",
            "algorithm_version",
            name="uq_statement_import_validation_run_input",
        ),
    )
    op.create_table(
        "statement_import_validation_checks",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "validation_run_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_import_validation_runs.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("check_kind", sa.String(40), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("evidence_row_ids", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("status IN ('passed','failed','unavailable')", name="valid_status"),
        sa.UniqueConstraint(
            "validation_run_id", "check_kind", name="uq_statement_import_validation_check"
        ),
    )
    op.create_table(
        "statement_import_review_candidates",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "validation_run_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_import_validation_runs.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "statement_import_row_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_import_rows.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("candidate_kind", sa.String(32), nullable=False),
        sa.Column("provider_candidate_index", sa.Integer()),
        sa.Column(
            "transaction_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("transactions.id", ondelete="RESTRICT"),
        ),
        sa.Column("transaction_date", sa.Date()),
        sa.Column("amount_minor", sa.BigInteger()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "candidate_kind IN ('provider_candidate','existing_transaction')",
            name="valid_candidate_kind",
        ),
        sa.UniqueConstraint(
            "validation_run_id",
            "statement_import_row_id",
            "candidate_kind",
            "provider_candidate_index",
            "transaction_id",
            name="uq_statement_import_review_candidate",
        ),
    )
    op.create_table(
        "statement_import_draft_resolutions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "validation_run_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_import_validation_runs.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "statement_import_row_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_import_rows.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("resolution", sa.String(32), nullable=False),
        sa.Column(
            "matched_transaction_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("transactions.id", ondelete="RESTRICT"),
        ),
        sa.Column("ignored_reason", sa.String(160)),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "resolution IN ('unresolved','create_new','match_existing','ignore_non_transaction','ignore_intentional')",
            name="valid_resolution",
        ),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.CheckConstraint(
            "(resolution = 'match_existing') = (matched_transaction_id IS NOT NULL)",
            name="match_target",
        ),
        sa.CheckConstraint(
            "(resolution = 'ignore_intentional') = (ignored_reason IS NOT NULL)",
            name="ignore_reason",
        ),
        sa.UniqueConstraint(
            "validation_run_id",
            "statement_import_row_id",
            name="uq_statement_import_draft_resolution",
        ),
    )


def downgrade() -> None:
    op.drop_table("statement_import_draft_resolutions")
    op.drop_table("statement_import_review_candidates")
    op.drop_table("statement_import_validation_checks")
    op.drop_table("statement_import_validation_runs")
