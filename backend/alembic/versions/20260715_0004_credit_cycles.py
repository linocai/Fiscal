"""Add P4 credit cycles, purchases, and repayments.

Revision ID: 20260715_0004
Revises: 20260715_0003
Create Date: 2026-07-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260715_0004"
down_revision: str | None = "20260715_0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


P4_SHAPE_FUNCTION = """
CREATE OR REPLACE FUNCTION fiscal_validate_transaction_shape(p_transaction_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_kind varchar(16);
    v_category_id uuid;
    v_cycle_id uuid;
    v_category_direction varchar(16);
    v_count integer;
    v_account_count integer;
    v_source_count integer;
    v_destination_count integer;
    v_account_position_count integer;
    v_source_position_count integer;
    v_destination_position_count integer;
    v_sum bigint;
    v_min bigint;
    v_max bigint;
    v_primary_kind varchar(16);
    v_destination_kind varchar(16);
    v_primary_account uuid;
    v_destination_account uuid;
    v_cycle_account uuid;
BEGIN
    SELECT kind, category_id, credit_cycle_id
      INTO v_kind, v_category_id, v_cycle_id
      FROM transactions WHERE id = p_transaction_id;
    IF NOT FOUND THEN RETURN; END IF;

    SELECT count(*),
           count(*) FILTER (WHERE role = 'account'),
           count(*) FILTER (WHERE role = 'source'),
           count(*) FILTER (WHERE role = 'destination'),
           count(*) FILTER (WHERE role = 'account' AND position = 0),
           count(*) FILTER (WHERE role = 'source' AND position = 0),
           count(*) FILTER (WHERE role = 'destination' AND position = 1),
           COALESCE(sum(amount_minor), 0), min(amount_minor), max(amount_minor),
           (array_agg(account_id) FILTER (WHERE role IN ('account', 'source')))[1],
           (array_agg(account_id) FILTER (WHERE role = 'destination'))[1]
      INTO v_count, v_account_count, v_source_count, v_destination_count,
           v_account_position_count, v_source_position_count,
           v_destination_position_count, v_sum, v_min, v_max,
           v_primary_account, v_destination_account
      FROM postings WHERE transaction_id = p_transaction_id;

    SELECT kind INTO v_primary_kind FROM accounts WHERE id = v_primary_account;
    SELECT kind INTO v_destination_kind FROM accounts WHERE id = v_destination_account;
    SELECT account_id INTO v_cycle_account FROM credit_cycles WHERE id = v_cycle_id;

    IF v_kind IN ('income', 'expense') THEN
        SELECT direction INTO v_category_direction FROM categories WHERE id = v_category_id;
        IF v_cycle_id IS NOT NULL OR v_category_id IS NULL
           OR v_category_direction <> v_kind OR v_count <> 1 OR v_account_count <> 1
           OR v_account_position_count <> 1 OR v_source_count <> 0
           OR v_destination_count <> 0 OR v_primary_kind NOT IN ('cash', 'debit')
           OR (v_kind = 'income' AND v_sum <= 0)
           OR (v_kind = 'expense' AND v_sum >= 0) THEN
            RAISE EXCEPTION 'invalid income/expense posting shape'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF v_kind = 'transfer' THEN
        IF v_cycle_id IS NOT NULL OR v_category_id IS NOT NULL OR v_count <> 2
           OR v_account_count <> 0 OR v_source_count <> 1 OR v_destination_count <> 1
           OR v_source_position_count <> 1 OR v_destination_position_count <> 1
           OR v_sum <> 0 OR v_min >= 0 OR v_max <= 0
           OR v_primary_kind NOT IN ('cash', 'debit')
           OR v_destination_kind NOT IN ('cash', 'debit') THEN
            RAISE EXCEPTION 'invalid transfer posting shape'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF v_kind = 'credit_purchase' THEN
        SELECT direction INTO v_category_direction FROM categories WHERE id = v_category_id;
        IF v_cycle_id IS NULL OR v_category_id IS NULL OR v_category_direction <> 'expense'
           OR v_count <> 1 OR v_account_count <> 1 OR v_account_position_count <> 1
           OR v_source_count <> 0 OR v_destination_count <> 0 OR v_sum >= 0
           OR v_primary_kind <> 'credit' OR v_cycle_account <> v_primary_account THEN
            RAISE EXCEPTION 'invalid credit purchase posting shape'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF v_kind = 'repayment' THEN
        IF v_cycle_id IS NULL OR v_category_id IS NOT NULL OR v_count <> 2
           OR v_account_count <> 0 OR v_source_count <> 1 OR v_destination_count <> 1
           OR v_source_position_count <> 1 OR v_destination_position_count <> 1
           OR v_sum <> 0 OR v_min >= 0 OR v_max <= 0
           OR v_primary_kind NOT IN ('cash', 'debit') OR v_destination_kind <> 'credit'
           OR v_cycle_account <> v_destination_account THEN
            RAISE EXCEPTION 'invalid repayment posting shape'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        RAISE EXCEPTION 'invalid transaction kind' USING ERRCODE = 'check_violation';
    END IF;
END;
$$;
"""

P3_SHAPE_FUNCTION = """
CREATE OR REPLACE FUNCTION fiscal_validate_transaction_shape(p_transaction_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_kind varchar(16);
    v_category_id uuid;
    v_category_direction varchar(16);
    v_count integer;
    v_account_count integer;
    v_source_count integer;
    v_destination_count integer;
    v_account_position_count integer;
    v_source_position_count integer;
    v_destination_position_count integer;
    v_sum bigint;
    v_min bigint;
    v_max bigint;
BEGIN
    SELECT kind, category_id INTO v_kind, v_category_id
      FROM transactions WHERE id = p_transaction_id;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT count(*),
           count(*) FILTER (WHERE role = 'account'),
           count(*) FILTER (WHERE role = 'source'),
           count(*) FILTER (WHERE role = 'destination'),
           count(*) FILTER (WHERE role = 'account' AND position = 0),
           count(*) FILTER (WHERE role = 'source' AND position = 0),
           count(*) FILTER (WHERE role = 'destination' AND position = 1),
           COALESCE(sum(amount_minor), 0), min(amount_minor), max(amount_minor)
      INTO v_count, v_account_count, v_source_count, v_destination_count,
           v_account_position_count, v_source_position_count,
           v_destination_position_count, v_sum, v_min, v_max
      FROM postings WHERE transaction_id = p_transaction_id;
    IF EXISTS (
        SELECT 1 FROM postings p JOIN accounts a ON a.id = p.account_id
         WHERE p.transaction_id = p_transaction_id AND a.kind NOT IN ('cash', 'debit')
    ) THEN
        RAISE EXCEPTION 'P3 postings require cash/debit accounts'
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_kind IN ('income', 'expense') THEN
        SELECT direction INTO v_category_direction FROM categories WHERE id = v_category_id;
        IF v_category_id IS NULL OR v_category_direction <> v_kind
           OR v_count <> 1 OR v_account_count <> 1 OR v_account_position_count <> 1
           OR v_source_count <> 0 OR v_destination_count <> 0
           OR (v_kind = 'income' AND v_sum <= 0)
           OR (v_kind = 'expense' AND v_sum >= 0) THEN
            RAISE EXCEPTION 'invalid income/expense posting shape'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF v_kind = 'transfer' THEN
        IF v_category_id IS NOT NULL OR v_count <> 2 OR v_account_count <> 0
           OR v_source_count <> 1 OR v_destination_count <> 1
           OR v_source_position_count <> 1 OR v_destination_position_count <> 1
           OR v_sum <> 0 OR v_min >= 0 OR v_max <= 0 THEN
            RAISE EXCEPTION 'invalid transfer posting shape'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        RAISE EXCEPTION 'invalid transaction kind' USING ERRCODE = 'check_violation';
    END IF;
END;
$$;
"""

CREDIT_ACCOUNT_CYCLE_GUARD = """
CREATE FUNCTION fiscal_credit_account_cycle_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_account_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'accounts' THEN
        IF OLD.kind = 'credit' AND NEW.kind <> 'credit'
           AND EXISTS (SELECT 1 FROM credit_cycles WHERE account_id = OLD.id) THEN
            RAISE EXCEPTION 'an account with credit cycles must remain a credit account'
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    v_account_id := NEW.account_id;
    IF NOT EXISTS (
        SELECT 1 FROM accounts WHERE id = v_account_id AND kind = 'credit'
    ) THEN
        RAISE EXCEPTION 'credit cycles require a credit account'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
"""

DOWNGRADE_PREFLIGHT = """
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM transactions WHERE kind IN ('credit_purchase', 'repayment')
    ) OR EXISTS (
        SELECT 1 FROM credit_cycles
    ) OR EXISTS (
        SELECT 1 FROM accounts
         WHERE opening_balance_as_of_date IS NOT NULL OR opening_due_date IS NOT NULL
    ) OR EXISTS (
        SELECT 1 FROM accounts
         WHERE kind = 'credit' AND opening_balance_minor > credit_limit_minor
    ) THEN
        RAISE EXCEPTION
            'P4 downgrade blocked: remove P4 transactions, cycles, opening configuration, and over-limit state first'
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
END;
$$;
"""


def upgrade() -> None:
    op.add_column("accounts", sa.Column("opening_balance_as_of_date", sa.Date(), nullable=True))
    op.add_column("accounts", sa.Column("opening_due_date", sa.Date(), nullable=True))
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
    op.create_table(
        "credit_cycles",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("account_id", sa.Uuid(), nullable=False),
        sa.Column("period_start", sa.Date(), nullable=False),
        sa.Column("period_end", sa.Date(), nullable=False),
        sa.Column("statement_date", sa.Date(), nullable=False),
        sa.Column("due_date", sa.Date(), nullable=False),
        sa.Column("is_opening_cycle", sa.Boolean(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("period_start <= period_end", name="valid_period"),
        sa.CheckConstraint("statement_date = period_end", name="statement_matches_period"),
        sa.CheckConstraint("due_date >= statement_date", name="due_not_before_statement"),
        sa.CheckConstraint("version = 1", name="immutable_version"),
        sa.ForeignKeyConstraint(
            ["account_id"],
            ["accounts.id"],
            name="fk_credit_cycles_account_id_accounts",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_credit_cycles"),
        sa.UniqueConstraint(
            "account_id",
            "period_start",
            "period_end",
            name="uq_credit_cycles_account_period",
        ),
    )
    op.create_index(
        "uq_credit_cycles_opening_account",
        "credit_cycles",
        ["account_id"],
        unique=True,
        postgresql_where=sa.text("is_opening_cycle"),
    )
    op.execute(CREDIT_ACCOUNT_CYCLE_GUARD)
    op.execute(
        "CREATE TRIGGER ck_accounts_credit_cycle_kind "
        "BEFORE UPDATE OF kind ON accounts FOR EACH ROW "
        "EXECUTE FUNCTION fiscal_credit_account_cycle_guard()"
    )
    op.execute(
        "CREATE TRIGGER ck_credit_cycles_account_kind "
        "BEFORE INSERT OR UPDATE OF account_id ON credit_cycles FOR EACH ROW "
        "EXECUTE FUNCTION fiscal_credit_account_cycle_guard()"
    )
    op.create_index(
        "ix_credit_cycles_timeline",
        "credit_cycles",
        ["account_id", sa.text("period_end DESC"), sa.text("id DESC")],
    )

    op.add_column("transactions", sa.Column("credit_cycle_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        "fk_transactions_credit_cycle_id_credit_cycles",
        "transactions",
        "credit_cycles",
        ["credit_cycle_id"],
        ["id"],
        ondelete="RESTRICT",
    )
    op.create_index("ix_transactions_credit_cycle_id", "transactions", ["credit_cycle_id"])
    op.drop_constraint(op.f("ck_transactions_valid_kind"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_kind",
        "transactions",
        "kind IN ('income', 'expense', 'transfer', 'credit_purchase', 'repayment')",
    )
    op.execute(P4_SHAPE_FUNCTION)


def downgrade() -> None:
    op.execute(DOWNGRADE_PREFLIGHT)
    op.drop_constraint(op.f("ck_transactions_valid_kind"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_kind", "transactions", "kind IN ('income', 'expense', 'transfer')"
    )
    op.execute(P3_SHAPE_FUNCTION)
    op.drop_index("ix_transactions_credit_cycle_id", table_name="transactions")
    op.drop_constraint(
        "fk_transactions_credit_cycle_id_credit_cycles", "transactions", type_="foreignkey"
    )
    op.drop_column("transactions", "credit_cycle_id")
    op.drop_index("ix_credit_cycles_timeline", table_name="credit_cycles")
    op.drop_index("uq_credit_cycles_opening_account", table_name="credit_cycles")
    op.execute("DROP TRIGGER IF EXISTS ck_credit_cycles_account_kind ON credit_cycles")
    op.execute("DROP TRIGGER IF EXISTS ck_accounts_credit_cycle_kind ON accounts")
    op.execute("DROP FUNCTION IF EXISTS fiscal_credit_account_cycle_guard()")
    op.drop_table("credit_cycles")
    op.drop_constraint(op.f("ck_accounts_kind_configuration"), "accounts", type_="check")
    op.create_check_constraint(
        "kind_configuration",
        "accounts",
        "(kind = 'credit' AND credit_limit_minor > 0 "
        "AND statement_day BETWEEN 1 AND 28 AND due_day BETWEEN 1 AND 28 "
        "AND opening_balance_minor >= 0 AND opening_balance_minor <= credit_limit_minor) "
        "OR (kind IN ('cash', 'debit') AND credit_limit_minor IS NULL "
        "AND statement_day IS NULL AND due_day IS NULL)",
    )
    op.drop_column("accounts", "opening_due_date")
    op.drop_column("accounts", "opening_balance_as_of_date")
    # The P3 migration will recreate these on a full downgrade/upgrade. A direct downgrade
    # leaves P3 data valid; its application service remains the authoritative shape guard.
