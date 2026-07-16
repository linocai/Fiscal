"""Add P9 OCR and Shortcuts AI input sources.

Revision ID: 20260716_0008
Revises: 20260716_0007
Create Date: 2026-07-16
"""

from collections.abc import Sequence
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

import sqlalchemy as sa
from alembic import op

revision: str = "20260716_0008"
down_revision: str | None = "20260716_0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _p8_module() -> object:
    path = Path(__file__).with_name("20260716_0007_ai_proposals.py")
    spec = spec_from_file_location("p8_migration", path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _p9_shape() -> str:
    module = _p8_module()
    shape = str(module._p6_shape(allow_ai_text=True))  # type: ignore[attr-defined]
    return shape.replace(
        "('manual','system','ai_text')", "('manual','system','ai_text','ocr')"
    ).replace("('manual','ai_text')", "('manual','ai_text','ocr')")


def _p9_installment_validator() -> str:
    module = _p8_module()
    validator = str(module._installment_validator(allow_ai_text=True))  # type: ignore[attr-defined]
    return validator.replace("('manual','ai_text')", "('manual','ai_text','ocr')")


def upgrade() -> None:
    p8 = _p8_module()
    op.drop_constraint(op.f("ck_transactions_valid_source"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_source",
        "transactions",
        "source IN ('manual','system','ai_text','ocr')",
    )
    op.execute(_p9_shape())
    p8._execute_function_definitions(_p9_installment_validator())  # type: ignore[attr-defined]
    op.add_column(
        "ai_settings",
        sa.Column("ocr_source_enabled", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.add_column(
        "ai_settings",
        sa.Column(
            "shortcut_text_source_enabled",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )
    op.alter_column("ai_settings", "ocr_source_enabled", server_default=None)
    op.alter_column("ai_settings", "shortcut_text_source_enabled", server_default=None)
    op.drop_constraint(op.f("ck_ai_proposals_valid_source"), "ai_proposals", type_="check")
    op.create_check_constraint(
        "valid_source",
        "ai_proposals",
        "source IN ('text','ocr','shortcut_text')",
    )


def downgrade() -> None:
    op.execute(
        "DO $$ BEGIN IF EXISTS(SELECT 1 FROM ai_proposals WHERE source<>'text') OR "
        "EXISTS(SELECT 1 FROM transactions WHERE source='ocr') THEN "
        "RAISE EXCEPTION 'P9 downgrade blocked: OCR or Shortcuts data exists' "
        "USING ERRCODE='object_not_in_prerequisite_state'; END IF; END $$"
    )
    op.drop_constraint(op.f("ck_ai_proposals_valid_source"), "ai_proposals", type_="check")
    op.create_check_constraint("valid_source", "ai_proposals", "source='text'")
    op.drop_column("ai_settings", "shortcut_text_source_enabled")
    op.drop_column("ai_settings", "ocr_source_enabled")
    p8 = _p8_module()
    op.drop_constraint(op.f("ck_transactions_valid_source"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_source",
        "transactions",
        "source IN ('manual','system','ai_text')",
    )
    op.execute(p8._p6_shape(allow_ai_text=True))  # type: ignore[attr-defined]
    p8._execute_function_definitions(  # type: ignore[attr-defined]
        p8._installment_validator(allow_ai_text=True)  # type: ignore[attr-defined]
    )
