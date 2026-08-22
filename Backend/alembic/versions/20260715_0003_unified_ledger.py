"""Add the P3 unified ledger and deferred shape validation.

Revision ID: 20260715_0003
Revises: 20260715_0002
Create Date: 2026-07-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260715_0003"
down_revision: str | None = "20260715_0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "transactions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.String(length=16), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("title", sa.String(length=120), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("category_id", sa.Uuid(), nullable=True),
        sa.Column("source", sa.String(length=16), nullable=False),
        sa.Column("idempotency_key", sa.Uuid(), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("voided_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("kind IN ('income', 'expense', 'transfer')", name="valid_kind"),
        sa.CheckConstraint("source = 'manual'", name="manual_source"),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.CheckConstraint("char_length(title) BETWEEN 1 AND 120", name="title_length"),
        sa.CheckConstraint("note IS NULL OR char_length(note) <= 500", name="note_length"),
        sa.ForeignKeyConstraint(
            ["category_id"],
            ["categories.id"],
            name="fk_transactions_category_id_categories",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_transactions"),
        sa.UniqueConstraint("idempotency_key", name="uq_transactions_idempotency_key"),
    )
    op.create_index(
        "ix_transactions_timeline",
        "transactions",
        [sa.text("occurred_at DESC"), sa.text("id DESC")],
    )
    op.create_index("ix_transactions_category_id", "transactions", ["category_id"])

    op.create_table(
        "postings",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("transaction_id", sa.Uuid(), nullable=False),
        sa.Column("account_id", sa.Uuid(), nullable=False),
        sa.Column("role", sa.String(length=16), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.CheckConstraint("role IN ('account', 'source', 'destination')", name="valid_role"),
        sa.CheckConstraint("amount_minor <> 0", name="amount_nonzero"),
        sa.CheckConstraint("position >= 0", name="position_nonnegative"),
        sa.ForeignKeyConstraint(
            ["account_id"],
            ["accounts.id"],
            name="fk_postings_account_id_accounts",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["transaction_id"],
            ["transactions.id"],
            name="fk_postings_transaction_id_transactions",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_postings"),
        sa.UniqueConstraint("transaction_id", "account_id", name="uq_postings_transaction_account"),
        sa.UniqueConstraint("transaction_id", "role", name="uq_postings_transaction_role"),
        sa.UniqueConstraint("transaction_id", "position", name="uq_postings_transaction_position"),
    )
    op.create_index("ix_postings_account_id", "postings", ["account_id"])

    op.create_table(
        "transaction_revisions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("transaction_id", sa.Uuid(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("event", sa.String(length=16), nullable=False),
        sa.Column("snapshot", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "event IN ('created', 'updated', 'voided', 'restored')", name="valid_event"
        ),
        sa.ForeignKeyConstraint(
            ["transaction_id"],
            ["transactions.id"],
            name="fk_transaction_revisions_transaction_id_transactions",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_transaction_revisions"),
        sa.UniqueConstraint(
            "transaction_id",
            "version",
            name="uq_transaction_revisions_transaction_version",
        ),
    )

    op.execute(
        """
        CREATE FUNCTION fiscal_validate_transaction_shape(p_transaction_id uuid)
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
            SELECT kind, category_id
              INTO v_kind, v_category_id
              FROM transactions
             WHERE id = p_transaction_id;
            IF NOT FOUND THEN
                RETURN;
            END IF;

            SELECT count(*),
                   count(*) FILTER (WHERE role = 'account'),
                   count(*) FILTER (WHERE role = 'source'),
                   count(*) FILTER (WHERE role = 'destination'),
                   count(*) FILTER (WHERE role = 'account' AND position = 0),
                   count(*) FILTER (WHERE role = 'source' AND position = 0),
                   count(*) FILTER (WHERE role = 'destination' AND position = 1),
                   COALESCE(sum(amount_minor), 0),
                   min(amount_minor),
                   max(amount_minor)
              INTO v_count, v_account_count, v_source_count, v_destination_count,
                   v_account_position_count, v_source_position_count,
                   v_destination_position_count,
                   v_sum, v_min, v_max
              FROM postings
             WHERE transaction_id = p_transaction_id;

            IF EXISTS (
                SELECT 1
                  FROM postings p
                  JOIN accounts a ON a.id = p.account_id
                 WHERE p.transaction_id = p_transaction_id
                   AND a.kind NOT IN ('cash', 'debit')
            ) THEN
                RAISE EXCEPTION 'P3 postings require cash/debit accounts'
                    USING ERRCODE = 'check_violation';
            END IF;

            IF v_kind IN ('income', 'expense') THEN
                SELECT direction INTO v_category_direction
                  FROM categories WHERE id = v_category_id;
                IF v_category_id IS NULL OR v_category_direction <> v_kind
                   OR v_count <> 1 OR v_account_count <> 1
                   OR v_account_position_count <> 1
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
                RAISE EXCEPTION 'invalid transaction kind'
                    USING ERRCODE = 'check_violation';
            END IF;
        END;
        $$;
        """
    )
    op.execute(
        """
        CREATE FUNCTION fiscal_transaction_shape_trigger()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
            IF TG_TABLE_NAME = 'transactions' THEN
                PERFORM fiscal_validate_transaction_shape(NEW.id);
            ELSE
                IF TG_OP = 'UPDATE' AND OLD.transaction_id <> NEW.transaction_id THEN
                    PERFORM fiscal_validate_transaction_shape(OLD.transaction_id);
                END IF;
                PERFORM fiscal_validate_transaction_shape(
                    CASE WHEN TG_OP = 'DELETE' THEN OLD.transaction_id ELSE NEW.transaction_id END
                );
            END IF;
            IF TG_OP = 'DELETE' THEN
                RETURN OLD;
            END IF;
            RETURN NEW;
        END;
        $$;
        """
    )
    op.execute(
        """
        CREATE CONSTRAINT TRIGGER ck_transactions_posting_shape
        AFTER INSERT OR UPDATE ON transactions
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION fiscal_transaction_shape_trigger();
        """
    )
    op.execute(
        """
        CREATE CONSTRAINT TRIGGER ck_postings_transaction_shape
        AFTER INSERT OR UPDATE OR DELETE ON postings
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION fiscal_transaction_shape_trigger();
        """
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS ck_postings_transaction_shape ON postings")
    op.execute("DROP TRIGGER IF EXISTS ck_transactions_posting_shape ON transactions")
    op.execute("DROP FUNCTION IF EXISTS fiscal_transaction_shape_trigger()")
    op.execute("DROP FUNCTION IF EXISTS fiscal_validate_transaction_shape(uuid)")
    op.drop_table("transaction_revisions")
    op.drop_index("ix_postings_account_id", table_name="postings")
    op.drop_table("postings")
    op.drop_index("ix_transactions_category_id", table_name="transactions")
    op.drop_index("ix_transactions_timeline", table_name="transactions")
    op.drop_table("transactions")
