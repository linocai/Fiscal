"""P23 AI quality snapshots, append-only events, policy history and learning rules.

Revision ID: 20260811_0023
Revises: 20260811_0022
Create Date: 2026-08-11
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260811_0023"
down_revision: str | None = "20260811_0022"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "ai_settings",
        sa.Column("prompt_version", sa.String(length=80), server_default="p23-v1", nullable=False),
    )
    op.add_column("ai_proposals", sa.Column("prompt_version", sa.String(length=80), nullable=True))
    op.add_column(
        "ai_proposals",
        sa.Column("initial_parse_snapshot", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
    )
    op.add_column(
        "ai_proposals",
        sa.Column(
            "final_confirmed_snapshot", postgresql.JSONB(astext_type=sa.Text()), nullable=True
        ),
    )
    op.add_column(
        "ai_proposals",
        sa.Column("final_field_diff", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
    )
    op.create_table(
        "ai_quality_events",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("proposal_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("event_type", sa.String(length=32), nullable=False),
        sa.Column("reason", sa.String(length=120), nullable=True),
        sa.Column(
            "details", postgresql.JSONB(astext_type=sa.Text()), server_default="{}", nullable=False
        ),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "event_type IN ('parsed','confirm_unchanged','confirm_edited','ignored','execute_failed','automatic_execute','manual_execute','undone','provider_retry','final_failure')",
            name="valid_event_type",
        ),
        sa.ForeignKeyConstraint(["proposal_id"], ["ai_proposals.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_ai_quality_events_proposal_occurred",
        "ai_quality_events",
        ["proposal_id", "occurred_at"],
    )
    op.create_index(
        "ix_ai_quality_events_type_occurred", "ai_quality_events", ["event_type", "occurred_at"]
    )
    op.create_table(
        "ai_execution_policies",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("effective_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("source", sa.String(length=16), nullable=True),
        sa.Column("transaction_kind", sa.String(length=32), nullable=True),
        sa.Column("auto_execute_enabled", sa.Boolean(), nullable=False),
        sa.Column("auto_execute_limit_minor", sa.BigInteger(), nullable=False),
        sa.Column("minimum_confidence_bps", sa.Integer(), nullable=False),
        sa.Column("minimum_sample_size", sa.Integer(), nullable=False),
        sa.Column("change_reason", sa.String(length=120), nullable=False),
        sa.Column("changed_automatically", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.CheckConstraint(
            "minimum_confidence_bps BETWEEN 9000 AND 10000", name="confidence_range"
        ),
        sa.CheckConstraint("auto_execute_limit_minor BETWEEN 1 AND 100000", name="limit_range"),
        sa.CheckConstraint("minimum_sample_size >= 1", name="sample_size_positive"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_ai_execution_policies_effective", "ai_execution_policies", ["effective_at", "version"]
    )
    op.create_table(
        "ai_learning_rules",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("rule_kind", sa.String(length=32), nullable=False),
        sa.Column("normalized_key", sa.String(length=240), nullable=False),
        sa.Column("source", sa.String(length=16), nullable=True),
        sa.Column("category_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("account_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("evidence_count", sa.Integer(), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "rule_kind IN ('merchant_category','title_account','category_alias')",
            name="valid_rule_kind",
        ),
        sa.CheckConstraint("evidence_count >= 2", name="minimum_evidence"),
        sa.ForeignKeyConstraint(["account_id"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["category_id"], ["categories.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "rule_kind", "normalized_key", "source", name="uq_ai_learning_rule_key"
        ),
    )
    op.create_index("ix_ai_learning_rules_active", "ai_learning_rules", ["enabled", "rule_kind"])
    op.create_table(
        "ai_shadow_evaluations",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("provider", sa.String(length=40), nullable=False),
        sa.Column("model", sa.String(length=200), nullable=False),
        sa.Column("prompt_version", sa.String(length=80), nullable=False),
        sa.Column("corpus_fingerprint", sa.String(length=64), nullable=False),
        sa.Column("sample_size", sa.Integer(), nullable=False),
        sa.Column("passed_cases", sa.Integer(), nullable=False),
        sa.Column("evaluator_version", sa.String(length=80), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(corpus_fingerprint) = 64", name="fingerprint_length"),
        sa.CheckConstraint("sample_size >= 30", name="minimum_sample"),
        sa.CheckConstraint("passed_cases BETWEEN 0 AND sample_size", name="passed_cases_range"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("provider", "model", "prompt_version", name="uq_ai_shadow_candidate"),
    )
    # PostgreSQL permissions are intentionally not widened.  The trigger makes quality
    # evidence immutable even for accidental application updates/deletes.
    op.execute("""
        CREATE FUNCTION fiscal_prevent_ai_quality_event_mutation() RETURNS trigger AS $$
        BEGIN RAISE EXCEPTION 'ai_quality_events are immutable'; END; $$ LANGUAGE plpgsql;
    """)
    op.execute("""
        CREATE TRIGGER ai_quality_events_immutable
        BEFORE UPDATE OR DELETE ON ai_quality_events
        FOR EACH ROW EXECUTE FUNCTION fiscal_prevent_ai_quality_event_mutation();
    """)
    op.execute("""
        CREATE FUNCTION fiscal_preserve_ai_proposal_evidence() RETURNS trigger AS $$
        BEGIN
          IF NEW.raw_input IS DISTINCT FROM OLD.raw_input THEN
            RAISE EXCEPTION 'ai proposal raw input is immutable';
          END IF;
          IF OLD.initial_parse_snapshot IS NOT NULL
             AND NEW.initial_parse_snapshot IS DISTINCT FROM OLD.initial_parse_snapshot THEN
            RAISE EXCEPTION 'ai proposal initial parse snapshot is immutable';
          END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql;
    """)
    op.execute("""
        CREATE TRIGGER ai_proposals_evidence_immutable
        BEFORE UPDATE ON ai_proposals
        FOR EACH ROW EXECUTE FUNCTION fiscal_preserve_ai_proposal_evidence();
    """)


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS ai_proposals_evidence_immutable ON ai_proposals")
    op.execute("DROP FUNCTION IF EXISTS fiscal_preserve_ai_proposal_evidence()")
    op.execute("DROP TRIGGER IF EXISTS ai_quality_events_immutable ON ai_quality_events")
    op.execute("DROP FUNCTION IF EXISTS fiscal_prevent_ai_quality_event_mutation()")
    op.drop_table("ai_shadow_evaluations")
    op.drop_index("ix_ai_learning_rules_active", table_name="ai_learning_rules")
    op.drop_table("ai_learning_rules")
    op.drop_index("ix_ai_execution_policies_effective", table_name="ai_execution_policies")
    op.drop_table("ai_execution_policies")
    op.drop_index("ix_ai_quality_events_type_occurred", table_name="ai_quality_events")
    op.drop_index("ix_ai_quality_events_proposal_occurred", table_name="ai_quality_events")
    op.drop_table("ai_quality_events")
    op.drop_column("ai_proposals", "final_field_diff")
    op.drop_column("ai_proposals", "final_confirmed_snapshot")
    op.drop_column("ai_proposals", "initial_parse_snapshot")
    op.drop_column("ai_proposals", "prompt_version")
    op.drop_column("ai_settings", "prompt_version")
