"""Keep reimbursement cash-flow amounts derived from reimbursement facts.

Revision ID: 20260816_0034
Revises: 20260814_0033
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260816_0034"
down_revision: str | None = "20260814_0033"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column(
        "cash_flow_system_overrides",
        "planned_amount_minor",
        existing_type=sa.BigInteger(),
        nullable=True,
    )
    op.execute(
        "UPDATE cash_flow_system_overrides SET planned_amount_minor = NULL "
        "WHERE system_kind = 'reimbursement'"
    )


def downgrade() -> None:
    op.execute(
        """
        DO $$
        BEGIN
          IF EXISTS (
            SELECT 1 FROM cash_flow_system_overrides
            WHERE planned_amount_minor IS NULL
          ) THEN
            RAISE EXCEPTION
              'D5 downgrade blocked: system override amounts are derived facts';
          END IF;
        END
        $$
        """
    )
    op.alter_column(
        "cash_flow_system_overrides",
        "planned_amount_minor",
        existing_type=sa.BigInteger(),
        nullable=False,
    )
