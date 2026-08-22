"""Keep the current ledger trigger compatible with P10 uncategorized rows.

Later trigger rewrites accidentally restored the pre-P10 requirement that all
income and expense rows have a category. This migration reapplies the released
P10 rule to the current validator without relaxing credit-purchase semantics.

Revision ID: 20260811_0018
Revises: 20260811_0017
Create Date: 2026-08-11
"""

from collections.abc import Sequence
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

from alembic import op

revision: str = "20260811_0018"
down_revision: str | None = "20260811_0017"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _p13_shape() -> str:
    path = Path(__file__).with_name("20260717_0013_cash_flow_items.py")
    spec = spec_from_file_location("p13_migration", path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return str(module.P13_SHAPE)


def _p20_shape() -> str:
    return _p13_shape().replace(
        "v_category IS NULL OR v_direction<>v_kind",
        "(v_category IS NOT NULL AND v_direction<>v_kind)",
    )


def upgrade() -> None:
    op.execute(_p20_shape())


def downgrade() -> None:
    op.execute(_p13_shape())
