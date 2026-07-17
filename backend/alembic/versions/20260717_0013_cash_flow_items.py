"""Restore future cash flow plans as a first-class domain.

Revision ID: 20260717_0013
Revises: 20260717_0012
Create Date: 2026-07-17
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260717_0013"
down_revision: str | None = "20260717_0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

P13_SHAPE = r"""
CREATE OR REPLACE FUNCTION fiscal_validate_transaction_shape(p_transaction_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_kind varchar(32); v_source varchar(16); v_category uuid; v_cycle uuid; v_direction varchar(16);
 v_count int; v_account int; v_src int; v_dst int; v_sum numeric; v_min bigint; v_max bigint;
 v_primary_kind varchar(16); v_destination_kind varchar(16); v_primary uuid; v_destination uuid; v_cycle_account uuid;
 v_account_pos int; v_src_pos int; v_dst_pos int;
BEGIN
 SELECT kind,source,category_id,credit_cycle_id INTO v_kind,v_source,v_category,v_cycle FROM transactions WHERE id=p_transaction_id; IF NOT FOUND THEN RETURN; END IF;
 SELECT count(*),count(*) FILTER(WHERE role='account'),count(*) FILTER(WHERE role='source'),count(*) FILTER(WHERE role='destination'),
 count(*) FILTER(WHERE role='account' AND position=0),count(*) FILTER(WHERE role='source' AND position=0),count(*) FILTER(WHERE role='destination' AND position=1),
 coalesce(sum(amount_minor::numeric),0),min(amount_minor),max(amount_minor),
 (array_agg(account_id ORDER BY position) FILTER(WHERE role IN ('account','source')))[1],(array_agg(account_id ORDER BY position) FILTER(WHERE role='destination'))[1]
 INTO v_count,v_account,v_src,v_dst,v_account_pos,v_src_pos,v_dst_pos,v_sum,v_min,v_max,v_primary,v_destination FROM postings WHERE transaction_id=p_transaction_id;
 SELECT kind INTO v_primary_kind FROM accounts WHERE id=v_primary; SELECT kind INTO v_destination_kind FROM accounts WHERE id=v_destination;
 SELECT account_id INTO v_cycle_account FROM credit_cycles WHERE id=v_cycle; SELECT direction INTO v_direction FROM categories WHERE id=v_category;
 IF v_kind IN ('income','expense') THEN
  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','cash_flow') OR v_cycle IS NOT NULL OR v_category IS NULL OR v_direction<>v_kind OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR (v_kind='income' AND v_sum<=0) OR (v_kind='expense' AND v_sum>=0) OR v_primary_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid income/expense posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='transfer' THEN
  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','cash_flow') OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid transfer posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='credit_purchase' THEN
  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import') OR v_cycle IS NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_sum>=0 OR v_primary_kind<>'credit' OR v_cycle_account<>v_primary THEN RAISE EXCEPTION 'invalid credit purchase posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='repayment' THEN
  IF v_source NOT IN ('manual','system','ai_text','ocr','legacy_import') OR v_cycle IS NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind<>'credit' OR v_cycle_account<>v_destination THEN RAISE EXCEPTION 'invalid repayment posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind IN ('installment_fee','installment_refund') THEN
  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_primary_kind<>'credit' OR (v_kind='installment_fee' AND v_sum>=0) OR (v_kind='installment_refund' AND v_sum<=0) THEN RAISE EXCEPTION 'invalid installment posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='reimbursement_receipt' THEN
  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_sum<=0 OR v_primary_kind NOT IN ('cash','debit') OR (SELECT count(*) FROM reimbursement_receipts WHERE transaction_id=p_transaction_id)<>1 THEN RAISE EXCEPTION 'invalid reimbursement receipt shape' USING ERRCODE='check_violation'; END IF;
 ELSE RAISE EXCEPTION 'invalid transaction kind' USING ERRCODE='check_violation'; END IF;
END $$;
"""

P12_SHAPE = P13_SHAPE.replace(
    "'manual','ai_text','ocr','legacy_import','cash_flow'",
    "'manual','ai_text','ocr','legacy_import'",
)


def upgrade() -> None:
    op.drop_constraint(op.f("ck_transactions_valid_source"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_source",
        "transactions",
        "source IN ('manual', 'system', 'ai_text', 'ocr', 'legacy_import', 'cash_flow')",
    )
    op.execute(P13_SHAPE)
    op.create_table(
        "cash_flow_series",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("recurrence", sa.String(16), nullable=False),
        sa.Column("anchor_day", sa.Integer(), nullable=False),
        sa.Column("end_date", sa.Date(), nullable=False),
        sa.Column("idempotency_key", sa.Uuid(), nullable=False),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "recurrence = 'monthly'", name=op.f("ck_cash_flow_series_valid_recurrence")
        ),
        sa.CheckConstraint(
            "anchor_day BETWEEN 1 AND 31", name=op.f("ck_cash_flow_series_valid_anchor_day")
        ),
        sa.CheckConstraint("version >= 1", name=op.f("ck_cash_flow_series_version_positive")),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_cash_flow_series")),
        sa.UniqueConstraint("idempotency_key", name="uq_cash_flow_series_idempotency_key"),
    )
    op.create_table(
        "cash_flow_items",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("series_id", sa.Uuid(), nullable=True),
        sa.Column("title", sa.String(120), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("direction", sa.String(16), nullable=False),
        sa.Column("planned_amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("expected_date", sa.Date(), nullable=False),
        sa.Column("account_id", sa.Uuid(), nullable=True),
        sa.Column("destination_account_id", sa.Uuid(), nullable=True),
        sa.Column("category_id", sa.Uuid(), nullable=True),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("source", sa.String(16), nullable=False),
        sa.Column("idempotency_key", sa.Uuid(), nullable=False),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("legacy_source_id", sa.String(200), nullable=True),
        sa.Column("linked_transaction_id", sa.Uuid(), nullable=True),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("settled_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("cancelled_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "direction IN ('inflow', 'outflow', 'transfer')",
            name=op.f("ck_cash_flow_items_valid_direction"),
        ),
        sa.CheckConstraint(
            "status IN ('expected', 'confirmed', 'settled', 'cancelled')",
            name=op.f("ck_cash_flow_items_valid_status"),
        ),
        sa.CheckConstraint(
            "source IN ('manual', 'ai_text', 'legacy_import')",
            name=op.f("ck_cash_flow_items_valid_source"),
        ),
        sa.CheckConstraint(
            "planned_amount_minor > 0", name=op.f("ck_cash_flow_items_planned_amount_positive")
        ),
        sa.CheckConstraint("version >= 1", name=op.f("ck_cash_flow_items_version_positive")),
        sa.CheckConstraint(
            "char_length(title) BETWEEN 1 AND 120", name=op.f("ck_cash_flow_items_title_length")
        ),
        sa.CheckConstraint(
            "note IS NULL OR char_length(note) <= 500", name=op.f("ck_cash_flow_items_note_length")
        ),
        sa.CheckConstraint(
            "(direction = 'transfer' AND destination_account_id IS NOT NULL AND category_id IS NULL) OR "
            "(direction <> 'transfer' AND destination_account_id IS NULL)",
            name=op.f("ck_cash_flow_items_valid_destination"),
        ),
        sa.ForeignKeyConstraint(
            ["account_id"],
            ["accounts.id"],
            name=op.f("fk_cash_flow_items_account_id_accounts"),
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["category_id"],
            ["categories.id"],
            name=op.f("fk_cash_flow_items_category_id_categories"),
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["destination_account_id"],
            ["accounts.id"],
            name=op.f("fk_cash_flow_items_destination_account_id_accounts"),
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["linked_transaction_id"],
            ["transactions.id"],
            name=op.f("fk_cash_flow_items_linked_transaction_id_transactions"),
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["series_id"],
            ["cash_flow_series.id"],
            name=op.f("fk_cash_flow_items_series_id_cash_flow_series"),
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_cash_flow_items")),
        sa.UniqueConstraint("idempotency_key", name="uq_cash_flow_items_idempotency_key"),
        sa.UniqueConstraint("legacy_source_id", name="uq_cash_flow_items_legacy_source_id"),
        sa.UniqueConstraint(
            "linked_transaction_id", name="uq_cash_flow_items_linked_transaction_id"
        ),
    )
    op.create_index("ix_cash_flow_items_active", "cash_flow_items", ["status", "expected_date"])
    op.create_index("ix_cash_flow_items_series", "cash_flow_items", ["series_id", "expected_date"])
    op.create_index(
        "ix_cash_flow_items_account", "cash_flow_items", ["account_id", "expected_date"]
    )
    op.create_table(
        "cash_flow_item_revisions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("item_id", sa.Uuid(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("event", sa.String(16), nullable=False),
        sa.Column("snapshot", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "event IN ('created', 'updated', 'confirmed', 'settled', 'cancelled', 'reopened')",
            name=op.f("ck_cash_flow_item_revisions_valid_event"),
        ),
        sa.ForeignKeyConstraint(
            ["item_id"],
            ["cash_flow_items.id"],
            name=op.f("fk_cash_flow_item_revisions_item_id_cash_flow_items"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_cash_flow_item_revisions")),
        sa.UniqueConstraint("item_id", "version", name="uq_cash_flow_item_revisions_item_version"),
    )
    op.drop_constraint(op.f("ck_ai_proposals_transaction_state"), "ai_proposals", type_="check")
    op.add_column(
        "ai_proposals",
        sa.Column("target", sa.String(16), nullable=False, server_default="transaction"),
    )
    op.add_column("ai_proposals", sa.Column("cash_flow_item_id", sa.Uuid(), nullable=True))
    op.add_column("ai_proposals", sa.Column("cash_flow_item_version", sa.Integer(), nullable=True))
    op.create_foreign_key(
        op.f("fk_ai_proposals_cash_flow_item_id_cash_flow_items"),
        "ai_proposals",
        "cash_flow_items",
        ["cash_flow_item_id"],
        ["id"],
        ondelete="RESTRICT",
    )
    op.create_unique_constraint(
        "uq_ai_proposals_cash_flow_item_id", "ai_proposals", ["cash_flow_item_id"]
    )
    op.create_check_constraint(
        "valid_target", "ai_proposals", "target IN ('transaction','cash_flow')"
    )
    op.create_check_constraint(
        "execution_state",
        "ai_proposals",
        "(status IN ('executed','undone') AND "
        "((transaction_id IS NOT NULL)::int + (cash_flow_item_id IS NOT NULL)::int) = 1) "
        "OR (status NOT IN ('executed','undone') AND transaction_id IS NULL "
        "AND cash_flow_item_id IS NULL)",
    )
    op.create_check_constraint(
        "cash_flow_version_state",
        "ai_proposals",
        "((cash_flow_item_id IS NULL AND cash_flow_item_version IS NULL) OR "
        "(cash_flow_item_id IS NOT NULL AND cash_flow_item_version IS NOT NULL))",
    )


def downgrade() -> None:
    op.execute(
        """
        DO $$ BEGIN
          IF EXISTS (SELECT 1 FROM transactions WHERE source='cash_flow') THEN
            RAISE EXCEPTION 'P13 downgrade blocked: cash-flow ledger rows exist';
          END IF;
          IF EXISTS (SELECT 1 FROM ai_proposals WHERE target='cash_flow') THEN
            RAISE EXCEPTION 'P13 downgrade blocked: cash-flow AI proposals exist';
          END IF;
        END $$;
        """
    )
    op.drop_constraint(
        op.f("ck_ai_proposals_cash_flow_version_state"), "ai_proposals", type_="check"
    )
    op.drop_constraint(op.f("ck_ai_proposals_execution_state"), "ai_proposals", type_="check")
    op.drop_constraint(op.f("ck_ai_proposals_valid_target"), "ai_proposals", type_="check")
    op.create_check_constraint(
        "transaction_state",
        "ai_proposals",
        "((status IN ('executed','undone')) = (transaction_id IS NOT NULL))",
    )
    op.drop_constraint("uq_ai_proposals_cash_flow_item_id", "ai_proposals", type_="unique")
    op.drop_constraint(
        op.f("fk_ai_proposals_cash_flow_item_id_cash_flow_items"),
        "ai_proposals",
        type_="foreignkey",
    )
    op.drop_column("ai_proposals", "cash_flow_item_version")
    op.drop_column("ai_proposals", "cash_flow_item_id")
    op.drop_column("ai_proposals", "target")
    op.drop_table("cash_flow_item_revisions")
    op.drop_index("ix_cash_flow_items_account", table_name="cash_flow_items")
    op.drop_index("ix_cash_flow_items_series", table_name="cash_flow_items")
    op.drop_index("ix_cash_flow_items_active", table_name="cash_flow_items")
    op.drop_table("cash_flow_items")
    op.drop_table("cash_flow_series")
    op.drop_constraint(op.f("ck_transactions_valid_source"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_source",
        "transactions",
        "source IN ('manual', 'system', 'ai_text', 'ocr', 'legacy_import')",
    )
    op.execute(P12_SHAPE)
