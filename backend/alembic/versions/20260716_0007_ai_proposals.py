"""Add P8 AI text proposals and behavior settings.

Revision ID: 20260716_0007
Revises: 20260715_0006
Create Date: 2026-07-16
"""

import re
from collections.abc import Sequence
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260716_0007"
down_revision: str | None = "20260715_0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _previous_module(filename: str, module_name: str) -> object:
    path = Path(__file__).with_name(filename)
    spec = spec_from_file_location(module_name, path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _p6_shape(*, allow_ai_text: bool) -> str:
    module = _previous_module("20260715_0006_reimbursements.py", "p6_migration")
    shape = str(module.P6_SHAPE)  # type: ignore[attr-defined]
    if not allow_ai_text:
        return shape
    return shape.replace("v_source<>'manual'", "v_source NOT IN ('manual','ai_text')").replace(
        "v_source NOT IN ('manual','system')",
        "v_source NOT IN ('manual','system','ai_text')",
    )


def _installment_validator(*, allow_ai_text: bool) -> str:
    module = _previous_module("20260715_0005_installments.py", "p5_migration")
    validator = str(module.INSTALLMENT_VALIDATOR)  # type: ignore[attr-defined]
    if not allow_ai_text:
        return validator
    return validator.replace(
        "purchase.source<>'manual'", "purchase.source NOT IN ('manual','ai_text')"
    )


def _execute_function_definitions(definitions: str) -> None:
    """Execute complete PostgreSQL function definitions one prepared statement at a time."""
    statements = re.split(r"(?=CREATE OR REPLACE FUNCTION)", definitions.strip())
    for statement in statements:
        if statement.strip():
            op.execute(statement)


def upgrade() -> None:
    op.drop_constraint(op.f("ck_transactions_valid_source"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_source",
        "transactions",
        "source IN ('manual','system','ai_text')",
    )
    op.execute(_p6_shape(allow_ai_text=True))
    _execute_function_definitions(_installment_validator(allow_ai_text=True))

    op.create_table(
        "ai_settings",
        sa.Column("id", sa.SmallInteger(), primary_key=True),
        sa.Column("auto_execute_enabled", sa.Boolean(), nullable=False),
        sa.Column("auto_execute_limit_minor", sa.BigInteger(), nullable=False),
        sa.Column("minimum_confidence_bps", sa.Integer(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("id=1", name="singleton"),
        sa.CheckConstraint(
            "auto_execute_limit_minor BETWEEN 1 AND 100000", name="auto_limit_range"
        ),
        sa.CheckConstraint(
            "minimum_confidence_bps BETWEEN 9000 AND 10000", name="confidence_range"
        ),
        sa.CheckConstraint("version>=1", name="version_positive"),
    )
    op.execute(
        "INSERT INTO ai_settings(id,auto_execute_enabled,auto_execute_limit_minor,"
        "minimum_confidence_bps,version,created_at,updated_at) "
        "VALUES (1,false,100000,9000,1,now(),now())"
    )

    op.create_table(
        "ai_proposals",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("source", sa.String(16), nullable=False),
        sa.Column("raw_input", sa.Text(), nullable=False),
        sa.Column("content_fingerprint", sa.String(64), nullable=False),
        sa.Column("create_idempotency_key", sa.Uuid(), nullable=False),
        sa.Column("create_request_hash", sa.String(64), nullable=False),
        sa.Column("provider", sa.String(40)),
        sa.Column("provider_model", sa.String(120)),
        sa.Column("kind", sa.String(32)),
        sa.Column("amount_minor", sa.BigInteger()),
        sa.Column("currency", sa.String(3)),
        sa.Column("occurred_at", sa.DateTime(timezone=True)),
        sa.Column("title", sa.String(120)),
        sa.Column("note", sa.Text()),
        sa.Column("account_id", sa.Uuid()),
        sa.Column("category_id", sa.Uuid()),
        sa.Column("destination_account_id", sa.Uuid()),
        sa.Column("credit_cycle_id", sa.Uuid()),
        sa.Column("field_confidences", postgresql.JSONB(), nullable=False),
        sa.Column("overall_confidence_bps", sa.Integer()),
        sa.Column("missing_fields", postgresql.JSONB(), nullable=False),
        sa.Column("reason_codes", postgresql.JSONB(), nullable=False),
        sa.Column("explanation", sa.String(500)),
        sa.Column("error_code", sa.String(64)),
        sa.Column("error_message", sa.String(200)),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("transaction_id", sa.Uuid()),
        sa.Column("transaction_version", sa.Integer()),
        sa.Column("parsed_at", sa.DateTime(timezone=True)),
        sa.Column("executed_at", sa.DateTime(timezone=True)),
        sa.Column("ignored_at", sa.DateTime(timezone=True)),
        sa.Column("undone_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("source='text'", name="valid_source"),
        sa.CheckConstraint(
            "status IN ('processing','pending','executed','failed','ignored','undone')",
            name="valid_status",
        ),
        sa.CheckConstraint(
            "kind IS NULL OR kind IN ('income','expense','transfer','credit_purchase','repayment')",
            name="valid_kind",
        ),
        sa.CheckConstraint("char_length(raw_input) BETWEEN 1 AND 2000", name="raw_input_length"),
        sa.CheckConstraint("char_length(content_fingerprint)=64", name="fingerprint_length"),
        sa.CheckConstraint("char_length(create_request_hash)=64", name="request_hash_length"),
        sa.CheckConstraint("amount_minor IS NULL OR amount_minor>0", name="amount_positive"),
        sa.CheckConstraint("currency IS NULL OR currency='CNY'", name="valid_currency"),
        sa.CheckConstraint(
            "overall_confidence_bps IS NULL OR overall_confidence_bps BETWEEN 0 AND 10000",
            name="confidence_range",
        ),
        sa.CheckConstraint("version>=1", name="version_positive"),
        sa.CheckConstraint(
            "transaction_version IS NULL OR transaction_version>=1",
            name="transaction_version_positive",
        ),
        sa.CheckConstraint(
            "((status IN ('executed','undone'))=(transaction_id IS NOT NULL))",
            name="transaction_state",
        ),
        sa.CheckConstraint(
            "((transaction_id IS NULL AND transaction_version IS NULL) OR "
            "(transaction_id IS NOT NULL AND transaction_version IS NOT NULL))",
            name="transaction_version_state",
        ),
        sa.ForeignKeyConstraint(["account_id"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["category_id"], ["categories.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["destination_account_id"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["credit_cycle_id"], ["credit_cycles.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["transaction_id"], ["transactions.id"], ondelete="RESTRICT"),
        sa.UniqueConstraint(
            "create_idempotency_key", name="uq_ai_proposals_create_idempotency_key"
        ),
        sa.UniqueConstraint("transaction_id", name="uq_ai_proposals_transaction_id"),
    )
    op.create_index("ix_ai_proposals_fingerprint", "ai_proposals", ["content_fingerprint"])
    op.create_index(
        "ix_ai_proposals_pending_timeline",
        "ai_proposals",
        [sa.text("created_at DESC"), sa.text("id DESC")],
        postgresql_where=sa.text("status='pending'"),
    )
    op.create_index(
        "ix_ai_proposals_timeline",
        "ai_proposals",
        [sa.text("created_at DESC"), sa.text("id DESC")],
    )


def downgrade() -> None:
    op.execute(
        "DO $$ BEGIN IF EXISTS(SELECT 1 FROM ai_proposals) OR "
        "EXISTS(SELECT 1 FROM transactions WHERE source='ai_text') THEN "
        "RAISE EXCEPTION 'P8 downgrade blocked: AI proposal or ledger data exists' "
        "USING ERRCODE='object_not_in_prerequisite_state'; END IF; END $$"
    )
    op.drop_index("ix_ai_proposals_timeline", table_name="ai_proposals")
    op.drop_index("ix_ai_proposals_pending_timeline", table_name="ai_proposals")
    op.drop_index("ix_ai_proposals_fingerprint", table_name="ai_proposals")
    op.drop_table("ai_proposals")
    op.drop_table("ai_settings")

    op.drop_constraint(op.f("ck_transactions_valid_source"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_source",
        "transactions",
        "source IN ('manual','system')",
    )
    op.execute(_p6_shape(allow_ai_text=False))
    _execute_function_definitions(_installment_validator(allow_ai_text=False))
