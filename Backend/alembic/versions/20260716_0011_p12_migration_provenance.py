"""Add P12 migration provenance and legacy ledger source.

Revision ID: 20260716_0011
Revises: 20260716_0010
Create Date: 2026-07-16
"""

from collections.abc import Sequence
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

import sqlalchemy as sa
from alembic import op

revision: str = "20260716_0011"
down_revision: str | None = "20260716_0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _p10_module() -> object:
    path = Path(__file__).with_name("20260716_0009_p10_uncategorized.py")
    spec = spec_from_file_location("p10_migration", path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _p9_module() -> object:
    path = Path(__file__).with_name("20260716_0008_p9_input_sources.py")
    spec = spec_from_file_location("p9_migration", path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _p12_shape() -> str:
    shape = str(_p10_module()._p10_shape())  # type: ignore[attr-defined]
    return shape.replace(
        "('manual','ai_text','ocr')",
        "('manual','ai_text','ocr','legacy_import')",
    ).replace(
        "('manual','system','ai_text','ocr')",
        "('manual','system','ai_text','ocr','legacy_import')",
    )


def _p12_installment_validator() -> str:
    validator = str(_p9_module()._p9_installment_validator())  # type: ignore[attr-defined]
    return validator.replace(
        "('manual','ai_text','ocr')",
        "('manual','ai_text','ocr','legacy_import')",
    )


def upgrade() -> None:
    op.drop_constraint(op.f("ck_transactions_valid_source"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_source",
        "transactions",
        "source IN ('manual','system','ai_text','ocr','legacy_import')",
    )
    op.execute(_p12_shape())
    p9 = _p9_module()
    p9._p8_module()._execute_function_definitions(  # type: ignore[attr-defined]
        _p12_installment_validator()
    )

    op.create_table(
        "migration_runs",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("mode", sa.String(length=16), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("source_system", sa.String(length=64), nullable=False),
        sa.Column("source_database_fingerprint", sa.String(length=64), nullable=False),
        sa.Column("source_manifest_hash", sa.String(length=64), nullable=False),
        sa.Column("source_manifest", sa.dialects.postgresql.JSONB(), nullable=False),
        sa.Column("selection_scope", sa.dialects.postgresql.JSONB(), nullable=False),
        sa.Column("code_revision", sa.String(length=64), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "completed_at IS NULL OR completed_at >= started_at",
            name="ck_migration_runs_completion_not_before_start",
        ),
        sa.CheckConstraint(
            "(status='running' AND completed_at IS NULL) OR "
            "(status IN ('succeeded','failed') AND completed_at IS NOT NULL)",
            name="ck_migration_runs_lifecycle_consistent",
        ),
        sa.CheckConstraint(
            "mode IN ('dry_run','shadow','production')",
            name="ck_migration_runs_valid_mode",
        ),
        sa.CheckConstraint(
            "status IN ('running','succeeded','failed')",
            name="ck_migration_runs_valid_status",
        ),
        sa.CheckConstraint(
            "char_length(code_revision) BETWEEN 1 AND 64",
            name="ck_migration_runs_code_revision_length",
        ),
        sa.CheckConstraint(
            "char_length(source_database_fingerprint) = 64",
            name="ck_migration_runs_source_database_fingerprint_length",
        ),
        sa.CheckConstraint(
            "char_length(source_manifest_hash) = 64",
            name="ck_migration_runs_source_manifest_hash_length",
        ),
        sa.CheckConstraint(
            "char_length(source_system) BETWEEN 1 AND 64",
            name="ck_migration_runs_source_system_length",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_migration_runs"),
    )
    op.create_index(
        "ix_migration_runs_status_started",
        "migration_runs",
        ["status", sa.text("started_at DESC")],
        unique=False,
    )

    op.create_table(
        "migration_object_links",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("migration_run_id", sa.Uuid(), nullable=False),
        sa.Column("source_database_fingerprint", sa.String(length=64), nullable=False),
        sa.Column("source_object_type", sa.String(length=64), nullable=False),
        sa.Column("source_object_id", sa.String(length=160), nullable=False),
        sa.Column("source_content_hash", sa.String(length=64), nullable=False),
        sa.Column("target_object_type", sa.String(length=64), nullable=False),
        sa.Column("target_object_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "char_length(source_content_hash) = 64",
            name="ck_migration_object_links_source_content_hash_length",
        ),
        sa.CheckConstraint(
            "char_length(source_database_fingerprint) = 64",
            name="ck_migration_object_links_source_database_fingerprint_length",
        ),
        sa.CheckConstraint(
            "char_length(source_object_id) BETWEEN 1 AND 160",
            name="ck_migration_object_links_source_object_id_length",
        ),
        sa.CheckConstraint(
            "char_length(source_object_type) BETWEEN 1 AND 64",
            name="ck_migration_object_links_source_object_type_length",
        ),
        sa.CheckConstraint(
            "char_length(target_object_type) BETWEEN 1 AND 64",
            name="ck_migration_object_links_target_object_type_length",
        ),
        sa.ForeignKeyConstraint(
            ["migration_run_id"],
            ["migration_runs.id"],
            name="fk_migration_object_links_migration_run_id_migration_runs",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_migration_object_links"),
        sa.UniqueConstraint(
            "source_database_fingerprint",
            "source_object_type",
            "source_object_id",
            name="uq_migration_object_links_source_identity",
        ),
        sa.UniqueConstraint(
            "target_object_type",
            "target_object_id",
            name="uq_migration_object_links_target_identity",
        ),
    )
    op.create_index(
        "ix_migration_object_links_run_id",
        "migration_object_links",
        ["migration_run_id"],
        unique=False,
    )


def downgrade() -> None:
    op.execute(
        "DO $$ BEGIN IF EXISTS(SELECT 1 FROM migration_runs) OR "
        "EXISTS(SELECT 1 FROM transactions WHERE source='legacy_import') THEN "
        "RAISE EXCEPTION 'P12 downgrade blocked: migration provenance or legacy data exists' "
        "USING ERRCODE='object_not_in_prerequisite_state'; END IF; END $$"
    )
    op.drop_index(
        "ix_migration_object_links_run_id",
        table_name="migration_object_links",
    )
    op.drop_table("migration_object_links")
    op.drop_index("ix_migration_runs_status_started", table_name="migration_runs")
    op.drop_table("migration_runs")

    op.drop_constraint(op.f("ck_transactions_valid_source"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_source",
        "transactions",
        "source IN ('manual','system','ai_text','ocr')",
    )
    p10 = _p10_module()
    op.execute(p10._p10_shape())  # type: ignore[attr-defined]
    p9 = _p9_module()
    p9._p8_module()._execute_function_definitions(  # type: ignore[attr-defined]
        p9._p9_installment_validator()  # type: ignore[attr-defined]
    )
