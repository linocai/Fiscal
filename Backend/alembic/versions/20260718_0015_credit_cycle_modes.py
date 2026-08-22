"""Unify credit schedules and remove editable credit cash-flow overrides.

Revision ID: 20260718_0015
Revises: 20260717_0014
Create Date: 2026-07-18
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260718_0015"
down_revision: str | None = "20260717_0014"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("accounts", sa.Column("cycle_mode", sa.String(32), nullable=True))
    op.execute("UPDATE accounts SET cycle_mode = 'statement_day_cutoff' WHERE kind = 'credit'")
    op.drop_constraint(op.f("ck_accounts_kind_configuration"), "accounts", type_="check")
    op.create_check_constraint(
        "kind_configuration",
        "accounts",
        "(kind = 'credit' AND credit_limit_minor > 0 "
        "AND statement_day BETWEEN 1 AND 28 AND due_day BETWEEN 1 AND 28 "
        "AND cycle_mode IN ('statement_day_cutoff', 'previous_calendar_month') "
        "AND opening_balance_minor >= 0 "
        "AND ((opening_balance_minor = 0 AND opening_balance_as_of_date IS NULL "
        "AND opening_due_date IS NULL) OR (opening_balance_minor > 0 "
        "AND ((opening_balance_as_of_date IS NULL AND opening_due_date IS NULL) "
        "OR (opening_balance_as_of_date IS NOT NULL AND opening_due_date IS NOT NULL "
        "AND opening_due_date >= opening_balance_as_of_date))))) "
        "OR (kind IN ('cash', 'debit') AND credit_limit_minor IS NULL "
        "AND statement_day IS NULL AND due_day IS NULL AND cycle_mode IS NULL "
        "AND opening_balance_as_of_date IS NULL AND opening_due_date IS NULL)",
    )
    op.drop_constraint(
        op.f("ck_credit_cycles_statement_matches_period"),
        "credit_cycles",
        type_="check",
    )
    op.create_check_constraint(
        "statement_not_before_period_end",
        "credit_cycles",
        "statement_date >= period_end",
    )
    # Credit cash flow is a projection of ledger debt. Historical overrides intentionally
    # reappear as outstanding instead of silently masking the authoritative cycle balance.
    op.execute("DELETE FROM cash_flow_system_overrides WHERE system_kind = 'credit_cycle'")


def downgrade() -> None:
    op.execute(
        """
        DO $$ BEGIN
          IF EXISTS (
            SELECT 1 FROM credit_cycles
            WHERE NOT is_opening_cycle AND statement_date <> period_end
          ) THEN
            RAISE EXCEPTION 'P17 downgrade blocked: natural-month credit cycles exist';
          END IF;
        END $$;
        """
    )
    op.drop_constraint(
        op.f("ck_credit_cycles_statement_not_before_period_end"),
        "credit_cycles",
        type_="check",
    )
    op.create_check_constraint(
        "statement_matches_period", "credit_cycles", "statement_date = period_end"
    )
    op.drop_constraint(op.f("ck_accounts_kind_configuration"), "accounts", type_="check")
    op.create_check_constraint(
        "kind_configuration",
        "accounts",
        "(kind = 'credit' AND credit_limit_minor > 0 "
        "AND statement_day BETWEEN 1 AND 28 AND due_day BETWEEN 1 AND 28 "
        "AND opening_balance_minor >= 0 "
        "AND ((opening_balance_minor = 0 AND opening_balance_as_of_date IS NULL "
        "AND opening_due_date IS NULL) OR (opening_balance_minor > 0 "
        "AND ((opening_balance_as_of_date IS NULL AND opening_due_date IS NULL) "
        "OR (opening_balance_as_of_date IS NOT NULL AND opening_due_date IS NOT NULL "
        "AND opening_due_date >= opening_balance_as_of_date))))) "
        "OR (kind IN ('cash', 'debit') AND credit_limit_minor IS NULL "
        "AND statement_day IS NULL AND due_day IS NULL "
        "AND opening_balance_as_of_date IS NULL AND opening_due_date IS NULL)",
    )
    op.drop_column("accounts", "cycle_mode")
