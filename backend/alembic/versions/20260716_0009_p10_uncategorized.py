"""Allow actionable P10 uncategorized ledger rows.

Revision ID: 20260716_0009
Revises: 20260716_0008
Create Date: 2026-07-16
"""

from collections.abc import Sequence
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

from alembic import op

revision: str = "20260716_0009"
down_revision: str | None = "20260716_0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _p9_module() -> object:
    path = Path(__file__).with_name("20260716_0008_p9_input_sources.py")
    spec = spec_from_file_location("p9_migration", path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _p10_shape() -> str:
    module = _p9_module()
    shape = str(module._p9_shape())  # type: ignore[attr-defined]
    return shape.replace(
        "v_category IS NULL OR v_direction<>v_kind",
        "(v_category IS NOT NULL AND v_direction<>v_kind)",
    ).replace(
        "v_category IS NULL OR v_direction<>'expense'",
        "(v_category IS NOT NULL AND v_direction<>'expense')",
    )


def upgrade() -> None:
    op.execute(_p10_shape())


def downgrade() -> None:
    op.execute(
        "DO $$ BEGIN IF EXISTS(SELECT 1 FROM transactions "
        "WHERE category_id IS NULL AND kind IN ('income','expense','credit_purchase')) THEN "
        "RAISE EXCEPTION 'P10 downgrade blocked: uncategorized ledger data exists' "
        "USING ERRCODE='object_not_in_prerequisite_state'; END IF; END $$"
    )
    module = _p9_module()
    op.execute(module._p9_shape())  # type: ignore[attr-defined]
