"""Keep the balance-adjustment marker additive for raw historical imports.

Revision ID: 20260811_0019
Revises: 20260811_0018
Create Date: 2026-08-11
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260811_0019"
down_revision: str | None = "20260811_0018"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column("categories", "is_balance_adjustment", server_default=sa.false())


def downgrade() -> None:
    op.alter_column("categories", "is_balance_adjustment", server_default=None)
