"""P24 statement-import lifecycle, review evidence, and privacy-safe audit data.

The migration is deliberately ledger-isolated: no transaction/posting tables,
balances, or transaction sources are changed.  Original PDF bytes have no
column in this schema; only metadata and already-redacted review evidence may
be persisted by later phases.

Revision ID: 20260812_0024
Revises: 20260811_0023
Create Date: 2026-08-12
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260812_0024"
down_revision: str | None = "20260811_0023"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "statement_imports",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("document_sha256", sa.String(length=64), nullable=False),
        sa.Column("byte_size", sa.BigInteger(), nullable=False),
        sa.Column("page_count", sa.Integer(), nullable=False),
        sa.Column("mime_type", sa.String(length=100), nullable=False),
        sa.Column("display_name", sa.String(length=255), nullable=False),
        sa.Column("institution_name_raw", sa.String(length=200), nullable=True),
        sa.Column("account_hint_masked", sa.String(length=80), nullable=True),
        sa.Column("statement_period_start", sa.Date(), nullable=True),
        sa.Column("statement_period_end", sa.Date(), nullable=True),
        sa.Column("currency", sa.String(length=3), server_default="CNY", nullable=False),
        sa.Column("status", sa.String(length=24), server_default="created", nullable=False),
        sa.Column("latest_attempt_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("version", sa.Integer(), server_default="1", nullable=False),
        sa.Column("confirmed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("abandoned_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(document_sha256) = 64", name="document_sha256_length"),
        sa.CheckConstraint("byte_size > 0", name="byte_size_positive"),
        sa.CheckConstraint("page_count > 0", name="page_count_positive"),
        sa.CheckConstraint("currency = 'CNY'", name="currency_cny"),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.CheckConstraint(
            "status IN ('created','extracting','parsing','review_required','ready_to_confirm','partially_confirmed','confirmed','failed','abandoned')",
            name="valid_status",
        ),
        sa.CheckConstraint(
            "(status = 'confirmed') = (confirmed_at IS NOT NULL)", name="confirmed_timestamp"
        ),
        sa.CheckConstraint(
            "(status = 'abandoned') = (abandoned_at IS NOT NULL)", name="abandoned_timestamp"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("document_sha256", name="uq_statement_imports_document_sha256"),
    )
    op.create_index(
        "ix_statement_imports_status_updated",
        "statement_imports",
        ["status", sa.text("updated_at DESC")],
    )
    op.create_table(
        "statement_import_pages",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("statement_import_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("page_number", sa.Integer(), nullable=False),
        sa.Column("source_kind", sa.String(length=20), nullable=True),
        sa.Column("evidence_text_masked", sa.Text(), nullable=True),
        sa.Column("bounding_boxes", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("page_number > 0", name="page_number_positive"),
        sa.CheckConstraint(
            "source_kind IS NULL OR source_kind IN ('text','scanned_image','mixed','unsupported')",
            name="valid_source_kind",
        ),
        sa.CheckConstraint(
            "evidence_text_masked IS NULL OR char_length(evidence_text_masked) <= 20000",
            name="evidence_text_length",
        ),
        sa.ForeignKeyConstraint(
            ["statement_import_id"], ["statement_imports.id"], ondelete="RESTRICT"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "statement_import_id", "page_number", name="uq_statement_import_pages_number"
        ),
    )
    op.create_table(
        "statement_import_rows",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("statement_import_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("row_number", sa.Integer(), nullable=False),
        sa.Column("page_number", sa.Integer(), nullable=True),
        sa.Column("evidence_text_masked", sa.Text(), nullable=True),
        sa.Column("bounding_box", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("raw_transaction_date", sa.String(length=64), nullable=True),
        sa.Column("raw_posted_date", sa.String(length=64), nullable=True),
        sa.Column("raw_summary_masked", sa.Text(), nullable=True),
        sa.Column("raw_amount", sa.String(length=80), nullable=True),
        sa.Column("raw_direction", sa.String(length=32), nullable=True),
        sa.Column("amount_minor", sa.BigInteger(), nullable=True),
        sa.Column("currency", sa.String(length=3), nullable=True),
        sa.Column("transaction_kind_candidate", sa.String(length=32), nullable=True),
        sa.Column("account_id_candidate", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("category_id_candidate", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("credit_cycle_id_candidate", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("initial_parse_snapshot", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("final_value_snapshot", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("field_diff", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column(
            "validation_warnings",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default="[]",
            nullable=False,
        ),
        sa.Column(
            "duplicate_candidates",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default="[]",
            nullable=False,
        ),
        sa.Column("transaction_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("version", sa.Integer(), server_default="1", nullable=False),
        sa.Column("confirmed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("confirmation_operation_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("row_number > 0", name="row_number_positive"),
        sa.CheckConstraint("amount_minor IS NULL OR amount_minor > 0", name="amount_positive"),
        sa.CheckConstraint("currency IS NULL OR currency = 'CNY'", name="currency_cny"),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.ForeignKeyConstraint(["account_id_candidate"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["category_id_candidate"], ["categories.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(
            ["credit_cycle_id_candidate"], ["credit_cycles.id"], ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(
            ["statement_import_id"], ["statement_imports.id"], ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(["transaction_id"], ["transactions.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "statement_import_id", "row_number", name="uq_statement_import_rows_number"
        ),
    )
    op.create_index(
        "ix_statement_import_rows_import_page",
        "statement_import_rows",
        ["statement_import_id", "page_number"],
    )
    op.create_table(
        "statement_import_attempts",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("statement_import_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("attempt_number", sa.SmallInteger(), nullable=False),
        sa.Column("kind", sa.String(length=24), nullable=False),
        sa.Column("status", sa.String(length=16), server_default="started", nullable=False),
        sa.Column("provider", sa.String(length=40), nullable=True),
        sa.Column("provider_model", sa.String(length=200), nullable=True),
        sa.Column("prompt_version", sa.String(length=80), nullable=True),
        sa.Column("schema_version", sa.String(length=80), nullable=True),
        sa.Column("authorized_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("error_code", sa.String(length=64), nullable=True),
        sa.Column("error_summary", sa.String(length=200), nullable=True),
        sa.Column("duration_ms", sa.Integer(), nullable=True),
        sa.Column("input_page_count", sa.Integer(), nullable=True),
        sa.Column("input_token_count", sa.Integer(), nullable=True),
        sa.Column("output_token_count", sa.Integer(), nullable=True),
        sa.Column("version", sa.Integer(), server_default="1", nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("attempt_number > 0", name="attempt_number_positive"),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.CheckConstraint("kind IN ('local_extraction','provider_parse')", name="valid_kind"),
        sa.CheckConstraint(
            "status IN ('started','succeeded','failed','abandoned')", name="valid_status"
        ),
        sa.CheckConstraint(
            "(status IN ('succeeded','failed','abandoned')) = (completed_at IS NOT NULL)",
            name="terminal_timestamp",
        ),
        sa.CheckConstraint(
            "error_code IS NULL OR char_length(error_code) BETWEEN 1 AND 64",
            name="error_code_length",
        ),
        sa.ForeignKeyConstraint(
            ["statement_import_id"], ["statement_imports.id"], ondelete="RESTRICT"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "statement_import_id", "attempt_number", name="uq_statement_import_attempts_number"
        ),
    )
    op.create_index(
        "ix_statement_import_attempts_import_created",
        "statement_import_attempts",
        ["statement_import_id", "created_at"],
    )
    op.create_foreign_key(
        "fk_statement_imports_latest_attempt",
        "statement_imports",
        "statement_import_attempts",
        ["latest_attempt_id"],
        ["id"],
        ondelete="SET NULL",
        deferrable=True,
        initially="DEFERRED",
    )
    op.create_table(
        "statement_import_resolutions",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("statement_import_row_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("resolution", sa.String(length=32), server_default="unresolved", nullable=False),
        sa.Column("matched_transaction_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("ignored_reason", sa.String(length=160), nullable=True),
        sa.Column("version", sa.Integer(), server_default="1", nullable=False),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("confirmation_operation_id", postgresql.UUID(as_uuid=True), nullable=True),
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
        sa.ForeignKeyConstraint(
            ["matched_transaction_id"], ["transactions.id"], ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(
            ["statement_import_row_id"], ["statement_import_rows.id"], ondelete="RESTRICT"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("statement_import_row_id", name="uq_statement_import_resolutions_row"),
    )
    op.create_table(
        "statement_import_operations",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("statement_import_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("attempt_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("operation", sa.String(length=32), nullable=False),
        sa.Column("error_code", sa.String(length=64), nullable=False),
        sa.Column(
            "details", postgresql.JSONB(astext_type=sa.Text()), server_default="{}", nullable=False
        ),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "operation IN ('registered','attempt_started','attempt_failed','abandoned')",
            name="valid_operation",
        ),
        sa.CheckConstraint("char_length(error_code) BETWEEN 1 AND 64", name="error_code_length"),
        sa.ForeignKeyConstraint(
            ["attempt_id"], ["statement_import_attempts.id"], ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(
            ["statement_import_id"], ["statement_imports.id"], ondelete="RESTRICT"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_statement_import_operations_import_occurred",
        "statement_import_operations",
        ["statement_import_id", "occurred_at"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_statement_import_operations_import_occurred", table_name="statement_import_operations"
    )
    op.drop_table("statement_import_operations")
    op.drop_table("statement_import_resolutions")
    op.drop_constraint(
        "fk_statement_imports_latest_attempt", "statement_imports", type_="foreignkey"
    )
    op.drop_index(
        "ix_statement_import_attempts_import_created", table_name="statement_import_attempts"
    )
    op.drop_table("statement_import_attempts")
    op.drop_index("ix_statement_import_rows_import_page", table_name="statement_import_rows")
    op.drop_table("statement_import_rows")
    op.drop_table("statement_import_pages")
    op.drop_index("ix_statement_imports_status_updated", table_name="statement_imports")
    op.drop_table("statement_imports")
