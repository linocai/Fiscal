"""P27-B formal statement import confirmation receipts.

Revision ID: 20260812_0028
Revises: 20260812_0027
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260812_0028"
down_revision: str | None = "20260812_0027"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# P13's current deferred shape validator, with only the four internal adapter
# source allowlists extended. Every account/category/cycle/count/position/sign
# predicate remains byte-for-byte equivalent in intent.
P27_SHAPE = r"""
CREATE OR REPLACE FUNCTION fiscal_validate_transaction_shape(p_transaction_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_kind varchar(32); v_source varchar(16); v_category uuid; v_cycle uuid; v_direction varchar(16);
 v_count int; v_account int; v_src int; v_dst int; v_sum numeric; v_min bigint; v_max bigint;
 v_primary_kind varchar(16); v_destination_kind varchar(16); v_primary uuid; v_destination uuid; v_cycle_account uuid;
 v_account_pos int; v_src_pos int; v_dst_pos int;
BEGIN
 SELECT kind,source,category_id,credit_cycle_id INTO v_kind,v_source,v_category,v_cycle FROM transactions WHERE id=p_transaction_id; IF NOT FOUND THEN RETURN; END IF;
 SELECT count(*),count(*) FILTER(WHERE role='account'),count(*) FILTER(WHERE role='source'),count(*) FILTER(WHERE role='destination'), count(*) FILTER(WHERE role='account' AND position=0),count(*) FILTER(WHERE role='source' AND position=0),count(*) FILTER(WHERE role='destination' AND position=1), coalesce(sum(amount_minor::numeric),0),min(amount_minor),max(amount_minor), (array_agg(account_id ORDER BY position) FILTER(WHERE role IN ('account','source')))[1],(array_agg(account_id ORDER BY position) FILTER(WHERE role='destination'))[1] INTO v_count,v_account,v_src,v_dst,v_account_pos,v_src_pos,v_dst_pos,v_sum,v_min,v_max,v_primary,v_destination FROM postings WHERE transaction_id=p_transaction_id;
 SELECT kind INTO v_primary_kind FROM accounts WHERE id=v_primary; SELECT kind INTO v_destination_kind FROM accounts WHERE id=v_destination; SELECT account_id INTO v_cycle_account FROM credit_cycles WHERE id=v_cycle; SELECT direction INTO v_direction FROM categories WHERE id=v_category;
 IF v_kind IN ('income','expense') THEN
  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','cash_flow','statement_import') OR v_cycle IS NOT NULL OR v_category IS NULL OR v_direction<>v_kind OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR (v_kind='income' AND v_sum<=0) OR (v_kind='expense' AND v_sum>=0) OR v_primary_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid income/expense posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='transfer' THEN
  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','cash_flow','statement_import') OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid transfer posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='credit_purchase' THEN
  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','statement_import') OR v_cycle IS NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_sum>=0 OR v_primary_kind<>'credit' OR v_cycle_account<>v_primary THEN RAISE EXCEPTION 'invalid credit purchase posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='repayment' THEN
  IF v_source NOT IN ('manual','system','ai_text','ocr','legacy_import','statement_import') OR v_cycle IS NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind<>'credit' OR v_cycle_account<>v_destination THEN RAISE EXCEPTION 'invalid repayment posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind IN ('installment_fee','installment_refund') THEN
  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_primary_kind<>'credit' OR (v_kind='installment_fee' AND v_sum>=0) OR (v_kind='installment_refund' AND v_sum<=0) THEN RAISE EXCEPTION 'invalid installment posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='reimbursement_receipt' THEN
  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_sum<=0 OR v_primary_kind NOT IN ('cash','debit') OR (SELECT count(*) FROM reimbursement_receipts WHERE transaction_id=p_transaction_id)<>1 THEN RAISE EXCEPTION 'invalid reimbursement receipt shape' USING ERRCODE='check_violation'; END IF;
 ELSE RAISE EXCEPTION 'invalid transaction kind' USING ERRCODE='check_violation'; END IF;
END $$;
"""
# P20 restored the released P10 rule: income/expense category is optional but,
# when selected, its direction must match. Keep that current validation too.
P13_SHAPE = P27_SHAPE.replace(",'statement_import'", "").replace(
    "v_category IS NULL OR v_direction<>v_kind",
    "(v_category IS NOT NULL AND v_direction<>v_kind)",
)
P27_SHAPE = P27_SHAPE.replace(
    "v_category IS NULL OR v_direction<>v_kind",
    "(v_category IS NOT NULL AND v_direction<>v_kind)",
)


def upgrade() -> None:
    op.drop_constraint("valid_source", "transactions", type_="check")
    op.create_check_constraint(
        "valid_source",
        "transactions",
        "source IN ('manual','system','ai_text','ocr','legacy_import','cash_flow','statement_import')",
    )
    op.execute(P27_SHAPE)
    op.create_table(
        "statement_import_confirmation_operations",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "statement_import_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_imports.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("idempotency_key", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("payload_hash", sa.String(64), nullable=False),
        sa.Column("receipt", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(payload_hash) = 64", name="payload_hash_length"),
        sa.UniqueConstraint("idempotency_key", name="uq_statement_import_confirmation_idempotency"),
    )
    op.create_table(
        "statement_import_transaction_provenance",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "statement_import_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_imports.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "statement_import_row_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_import_rows.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "confirmation_operation_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_import_confirmation_operations.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "transaction_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("transactions.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("resolution", sa.String(32), nullable=False),
        sa.Column("draft_version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("statement_import_row_id", name="uq_statement_import_provenance_row"),
    )
    op.create_table(
        "statement_import_final_create_drafts",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "statement_import_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_imports.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "statement_import_row_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_import_rows.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "draft_resolution_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("statement_import_draft_resolutions.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("version >= 1", name="version_positive"),
        sa.UniqueConstraint(
            "statement_import_row_id", name="uq_statement_import_final_create_draft_row"
        ),
    )


def downgrade() -> None:
    if (
        op.get_bind()
        .execute(
            sa.text(
                "SELECT EXISTS(SELECT 1 FROM transactions WHERE source='statement_import') OR EXISTS(SELECT 1 FROM statement_import_transaction_provenance)"
            )
        )
        .scalar()
    ):
        raise RuntimeError("cannot downgrade P27-B while statement-import confirmations exist")
    op.drop_table("statement_import_final_create_drafts")
    op.drop_table("statement_import_transaction_provenance")
    op.drop_table("statement_import_confirmation_operations")
    op.drop_constraint("valid_source", "transactions", type_="check")
    op.execute(P13_SHAPE)
    op.create_check_constraint(
        "valid_source",
        "transactions",
        "source IN ('manual','system','ai_text','ocr','legacy_import','cash_flow')",
    )
