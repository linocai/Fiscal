"""Persist the historical balancing-category reporting semantics.

Existing imported roots named ``平账`` become explicit balance-adjustment
categories. Descendants continue to be excluded by ReportingService traversal,
so a later rename cannot change historical reporting scope.

Revision ID: 20260811_0017
Revises: 20260719_0016
Create Date: 2026-08-11
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260811_0017"
down_revision: str | None = "20260719_0016"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "categories",
        sa.Column("is_balance_adjustment", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    # The released system used this exact display name as the sole marker. The
    # migration is the one-time conversion point; runtime reporting uses only
    # the stable boolean afterwards.
    op.execute(sa.text("UPDATE categories SET is_balance_adjustment = true WHERE name = '平账'"))
    op.alter_column("categories", "is_balance_adjustment", server_default=None)


def downgrade() -> None:
    op.drop_column("categories", "is_balance_adjustment")
