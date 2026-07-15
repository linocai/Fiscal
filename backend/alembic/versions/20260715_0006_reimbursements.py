"""Add P6 multi-party reimbursements and receipt ledger links.

Revision ID: 20260715_0006
Revises: 20260715_0005
Create Date: 2026-07-15
"""

import re
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260715_0006"
down_revision: str | None = "20260715_0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


P6_SHAPE = r"""
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
  IF v_source<>'manual' OR v_cycle IS NOT NULL OR v_category IS NULL OR v_direction<>v_kind OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR (v_kind='income' AND v_sum<=0) OR (v_kind='expense' AND v_sum>=0) OR v_primary_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid income/expense posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='transfer' THEN
  IF v_source<>'manual' OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid transfer posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='credit_purchase' THEN
  IF v_source<>'manual' OR v_cycle IS NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_sum>=0 OR v_primary_kind<>'credit' OR v_cycle_account<>v_primary THEN RAISE EXCEPTION 'invalid credit purchase posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='repayment' THEN
  IF v_source NOT IN ('manual','system') OR v_cycle IS NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind<>'credit' OR v_cycle_account<>v_destination THEN RAISE EXCEPTION 'invalid repayment posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind IN ('installment_fee','installment_refund') THEN
  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_primary_kind<>'credit' OR (v_kind='installment_fee' AND v_sum>=0) OR (v_kind='installment_refund' AND v_sum<=0) THEN RAISE EXCEPTION 'invalid installment posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='reimbursement_receipt' THEN
  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_sum<=0 OR v_primary_kind NOT IN ('cash','debit') OR (SELECT count(*) FROM reimbursement_receipts WHERE transaction_id=p_transaction_id)<>1 THEN RAISE EXCEPTION 'invalid reimbursement receipt shape' USING ERRCODE='check_violation'; END IF;
 ELSE RAISE EXCEPTION 'invalid transaction kind' USING ERRCODE='check_violation'; END IF;
END $$;
"""


VALIDATORS = r"""
CREATE OR REPLACE FUNCTION fiscal_reimbursement_expense_capacity(p_transaction_id uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN t.kind NOT IN ('expense','credit_purchase') OR t.voided_at IS NOT NULL THEN 0
 ELSE abs(p.amount_minor::numeric) - COALESCE((SELECT sum(abs(rp.amount_minor::numeric)) FROM installment_ledger_links il
 JOIN installment_plans ip ON ip.id=il.plan_id AND ip.purchase_transaction_id=t.id
 JOIN transactions rt ON rt.id=il.transaction_id AND rt.voided_at IS NULL
 JOIN postings rp ON rp.transaction_id=rt.id WHERE il.role='principal_refund'),0) END
 FROM transactions t JOIN postings p ON p.transaction_id=t.id AND p.role='account' WHERE t.id=p_transaction_id
$$;

CREATE OR REPLACE FUNCTION fiscal_validate_reimbursement_claim(p_claim_id uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE c record; rid uuid; aid uuid; total numeric; tx_amount numeric; tx_voided timestamptz; allocated numeric;
BEGIN
 SELECT * INTO c FROM reimbursement_claims WHERE id=p_claim_id FOR UPDATE; IF NOT FOUND THEN RETURN; END IF;
 IF c.voided_at IS NULL AND (NOT EXISTS(SELECT 1 FROM reimbursement_parties WHERE claim_id=c.id) OR NOT EXISTS(SELECT 1 FROM reimbursement_allocations WHERE claim_id=c.id)) THEN RAISE EXCEPTION 'reimbursement claim requires matrix rows' USING ERRCODE='check_violation'; END IF;
 IF EXISTS(SELECT 1 FROM reimbursement_allocations a LEFT JOIN reimbursement_parties p ON p.id=a.party_id WHERE a.claim_id=c.id AND (p.id IS NULL OR p.claim_id<>c.id)) THEN RAISE EXCEPTION 'reimbursement matrix ownership mismatch' USING ERRCODE='check_violation'; END IF;
 IF EXISTS(SELECT 1 FROM reimbursement_allocations a JOIN transactions t ON t.id=a.transaction_id WHERE a.claim_id=c.id AND (t.kind NOT IN ('expense','credit_purchase') OR t.voided_at IS NOT NULL)) THEN RAISE EXCEPTION 'reimbursement expense not eligible' USING ERRCODE='check_violation'; END IF;
 FOR aid IN SELECT DISTINCT transaction_id FROM reimbursement_allocations LOOP
  SELECT COALESCE(sum(CASE WHEN cl.voided_at IS NOT NULL THEN 0 WHEN cl.cancelled_at IS NULL THEN a.amount_minor ELSE COALESCE((SELECT sum(ra.amount_minor) FROM reimbursement_receipt_allocations ra JOIN reimbursement_receipts r ON r.id=ra.receipt_id JOIN transactions rt ON rt.id=r.transaction_id AND rt.voided_at IS NULL WHERE ra.allocation_id=a.id),0) END),0) INTO allocated FROM reimbursement_allocations a JOIN reimbursement_claims cl ON cl.id=a.claim_id WHERE a.transaction_id=aid;
  IF allocated > fiscal_reimbursement_expense_capacity(aid) THEN RAISE EXCEPTION 'reimbursement expense overallocated' USING ERRCODE='check_violation'; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM reimbursement_receipts r JOIN reimbursement_parties p ON p.id=r.party_id WHERE r.claim_id=c.id AND p.claim_id<>c.id) THEN RAISE EXCEPTION 'reimbursement receipt party mismatch' USING ERRCODE='check_violation'; END IF;
 FOR rid IN SELECT id FROM reimbursement_receipts WHERE claim_id=c.id LOOP
  SELECT p.amount_minor::numeric,t.voided_at INTO tx_amount,tx_voided FROM reimbursement_receipts r JOIN transactions t ON t.id=r.transaction_id JOIN postings p ON p.transaction_id=t.id AND p.role='account' WHERE r.id=rid AND t.kind='reimbursement_receipt' AND t.source='system';
  SELECT COALESCE(sum(ra.amount_minor::numeric),0) INTO total FROM reimbursement_receipt_allocations ra WHERE ra.receipt_id=rid;
  IF tx_amount IS NULL OR (tx_voided IS NULL AND total<>tx_amount) OR (tx_voided IS NOT NULL AND total<>0) THEN RAISE EXCEPTION 'reimbursement receipt allocation mismatch' USING ERRCODE='check_violation'; END IF;
  IF EXISTS(SELECT 1 FROM reimbursement_receipt_allocations ra JOIN reimbursement_allocations a ON a.id=ra.allocation_id JOIN reimbursement_receipts r ON r.id=ra.receipt_id WHERE ra.receipt_id=rid AND (a.claim_id<>c.id OR a.party_id<>r.party_id)) THEN RAISE EXCEPTION 'reimbursement receipt allocation ownership mismatch' USING ERRCODE='check_violation'; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM reimbursement_allocations a WHERE a.claim_id=c.id AND COALESCE((SELECT sum(ra.amount_minor::numeric) FROM reimbursement_receipt_allocations ra JOIN reimbursement_receipts r ON r.id=ra.receipt_id JOIN transactions t ON t.id=r.transaction_id AND t.voided_at IS NULL WHERE ra.allocation_id=a.id),0)>a.amount_minor) THEN RAISE EXCEPTION 'reimbursement allocation overpaid' USING ERRCODE='check_violation'; END IF;
END $$;

CREATE OR REPLACE FUNCTION fiscal_reimbursement_claim_trigger() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cid uuid; old_cid uuid;
BEGIN
 IF TG_TABLE_NAME='reimbursement_claims' THEN
  IF TG_OP='DELETE' THEN cid:=OLD.id; ELSE cid:=NEW.id; END IF;
 ELSE
 IF TG_OP='DELETE' THEN cid:=OLD.claim_id; ELSE cid:=NEW.claim_id; END IF;
 END IF;
 IF TG_OP='UPDATE' AND TG_TABLE_NAME<>'reimbursement_claims' THEN
  old_cid:=OLD.claim_id;
  IF old_cid<>cid THEN PERFORM fiscal_validate_reimbursement_claim(old_cid); END IF;
 END IF;
 PERFORM fiscal_validate_reimbursement_claim(cid); RETURN NULL;
END $$;
CREATE OR REPLACE FUNCTION fiscal_reimbursement_receipt_child_trigger() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cid uuid; old_cid uuid; rr uuid; old_rr uuid;
BEGIN
 rr:=CASE WHEN TG_OP='DELETE' THEN OLD.receipt_id ELSE NEW.receipt_id END;
 IF TG_OP='UPDATE' THEN
  old_rr:=OLD.receipt_id;
  IF old_rr<>rr THEN
   SELECT claim_id INTO old_cid FROM reimbursement_receipts WHERE id=old_rr;
   IF old_cid IS NOT NULL THEN PERFORM fiscal_validate_reimbursement_claim(old_cid); END IF;
  END IF;
 END IF;
 SELECT claim_id INTO cid FROM reimbursement_receipts WHERE id=rr;
 IF cid IS NOT NULL THEN PERFORM fiscal_validate_reimbursement_claim(cid); END IF;
 RETURN NULL;
END $$;
CREATE OR REPLACE FUNCTION fiscal_reimbursement_transaction_trigger() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE tid uuid; old_tid uuid; cid uuid;
BEGIN
 IF TG_TABLE_NAME='transactions' THEN
  IF TG_OP='DELETE' THEN tid:=OLD.id; ELSE tid:=NEW.id; END IF;
 ELSE
 IF TG_OP='DELETE' THEN tid:=OLD.transaction_id; ELSE tid:=NEW.transaction_id; END IF;
 END IF;
 IF TG_OP='UPDATE' AND TG_TABLE_NAME<>'transactions' THEN
  old_tid:=OLD.transaction_id;
  IF old_tid<>tid THEN
   FOR cid IN
    SELECT claim_id FROM reimbursement_allocations WHERE transaction_id=old_tid
    UNION SELECT claim_id FROM reimbursement_receipts WHERE transaction_id=old_tid
    UNION SELECT a.claim_id FROM installment_ledger_links il
      JOIN installment_plans ip ON ip.id=il.plan_id
      JOIN reimbursement_allocations a ON a.transaction_id=ip.purchase_transaction_id
     WHERE il.transaction_id=old_tid AND il.role='principal_refund'
   LOOP PERFORM fiscal_validate_reimbursement_claim(cid); END LOOP;
  END IF;
 END IF;
 FOR cid IN
  SELECT claim_id FROM reimbursement_allocations WHERE transaction_id=tid
  UNION SELECT claim_id FROM reimbursement_receipts WHERE transaction_id=tid
  UNION SELECT a.claim_id FROM installment_ledger_links il
    JOIN installment_plans ip ON ip.id=il.plan_id
    JOIN reimbursement_allocations a ON a.transaction_id=ip.purchase_transaction_id
   WHERE il.transaction_id=tid AND il.role='principal_refund'
 LOOP PERFORM fiscal_validate_reimbursement_claim(cid); END LOOP; RETURN NULL; END $$;
"""


def upgrade() -> None:
    op.drop_constraint(op.f("ck_transactions_valid_kind"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_kind",
        "transactions",
        "kind IN ('income','expense','transfer','credit_purchase','repayment','installment_fee','installment_refund','reimbursement_receipt')",
    )
    op.execute(P6_SHAPE)
    op.create_table(
        "reimbursement_claims",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("title", sa.String(120), nullable=False),
        sa.Column("note", sa.Text()),
        sa.Column("submitted_at", sa.DateTime(timezone=True)),
        sa.Column("cancelled_at", sa.DateTime(timezone=True)),
        sa.Column("voided_at", sa.DateTime(timezone=True)),
        sa.Column("archived_at", sa.DateTime(timezone=True)),
        sa.Column("create_idempotency_key", sa.Uuid(), nullable=False, unique=True),
        sa.Column("create_request_hash", sa.String(64), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("char_length(title) BETWEEN 1 AND 120", name="title_length"),
        sa.CheckConstraint("note IS NULL OR char_length(note)<=500", name="note_length"),
        sa.CheckConstraint("version>=1", name="version_positive"),
    )
    op.create_index(
        "ix_reimbursement_claims_timeline",
        "reimbursement_claims",
        [sa.text("created_at DESC"), sa.text("id DESC")],
    )
    op.create_table(
        "reimbursement_parties",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("expected_date", sa.Date()),
        sa.Column("note", sa.Text()),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(["claim_id"], ["reimbursement_claims.id"], ondelete="CASCADE"),
        sa.CheckConstraint("char_length(name) BETWEEN 1 AND 120", name="name_length"),
        sa.CheckConstraint("note IS NULL OR char_length(note)<=500", name="note_length"),
        sa.CheckConstraint("position>=0", name="position_nonnegative"),
        sa.UniqueConstraint("claim_id", "position", name="uq_reimbursement_parties_position"),
    )
    op.create_table(
        "reimbursement_allocations",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("party_id", sa.Uuid(), nullable=False),
        sa.Column("transaction_id", sa.Uuid(), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(["claim_id"], ["reimbursement_claims.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["party_id"], ["reimbursement_parties.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["transaction_id"], ["transactions.id"], ondelete="RESTRICT"),
        sa.CheckConstraint("amount_minor>0", name="amount_positive"),
        sa.CheckConstraint("position>=0", name="position_nonnegative"),
        sa.UniqueConstraint(
            "claim_id", "party_id", "transaction_id", name="uq_reimbursement_allocations_matrix"
        ),
        sa.UniqueConstraint("claim_id", "position", name="uq_reimbursement_allocations_position"),
    )
    op.create_index(
        "ix_reimbursement_allocations_transaction", "reimbursement_allocations", ["transaction_id"]
    )
    op.create_table(
        "reimbursement_receipts",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("party_id", sa.Uuid(), nullable=False),
        sa.Column("transaction_id", sa.Uuid(), nullable=False, unique=True),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["claim_id"], ["reimbursement_claims.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["party_id"], ["reimbursement_parties.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["transaction_id"], ["transactions.id"], ondelete="RESTRICT"),
        sa.CheckConstraint("version>=1", name="version_positive"),
    )
    op.create_index(
        "ix_reimbursement_receipts_claim",
        "reimbursement_receipts",
        ["claim_id", sa.text("created_at DESC")],
    )
    op.create_table(
        "reimbursement_receipt_allocations",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("receipt_id", sa.Uuid(), nullable=False),
        sa.Column("allocation_id", sa.Uuid(), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(["receipt_id"], ["reimbursement_receipts.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(
            ["allocation_id"], ["reimbursement_allocations.id"], ondelete="RESTRICT"
        ),
        sa.CheckConstraint("amount_minor>0", name="amount_positive"),
        sa.CheckConstraint("position>=0", name="position_nonnegative"),
        sa.UniqueConstraint(
            "receipt_id", "allocation_id", name="uq_reimbursement_receipt_allocations_row"
        ),
        sa.UniqueConstraint(
            "receipt_id", "position", name="uq_reimbursement_receipt_allocations_position"
        ),
    )
    for table, parent in (
        ("reimbursement_claim_revisions", "claim"),
        ("reimbursement_receipt_revisions", "receipt"),
    ):
        parent_table = "reimbursement_claims" if parent == "claim" else "reimbursement_receipts"
        op.create_table(
            table,
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column(f"{parent}_id", sa.Uuid(), nullable=False),
            sa.Column("version", sa.Integer(), nullable=False),
            sa.Column("event", sa.String(32), nullable=False),
            sa.Column("snapshot", postgresql.JSONB(), nullable=False),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
            sa.ForeignKeyConstraint([f"{parent}_id"], [f"{parent_table}.id"], ondelete="CASCADE"),
            sa.UniqueConstraint(f"{parent}_id", "version", name=f"uq_{table}_version"),
        )
    op.create_table(
        "reimbursement_operations",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("receipt_id", sa.Uuid()),
        sa.Column("kind", sa.String(32), nullable=False),
        sa.Column("idempotency_key", sa.Uuid(), nullable=False, unique=True),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("result_snapshot", postgresql.JSONB()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["claim_id"], ["reimbursement_claims.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["receipt_id"], ["reimbursement_receipts.id"], ondelete="RESTRICT"),
    )
    for statement in re.split(r"(?=CREATE OR REPLACE FUNCTION)", VALIDATORS.strip()):
        if not statement.strip():
            continue
        op.execute(statement)
    for table in (
        "reimbursement_claims",
        "reimbursement_parties",
        "reimbursement_allocations",
        "reimbursement_receipts",
    ):
        op.execute(
            f"CREATE CONSTRAINT TRIGGER ck_{table}_reimbursement AFTER INSERT OR UPDATE OR DELETE ON {table} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fiscal_reimbursement_claim_trigger()"
        )
    op.execute(
        "CREATE CONSTRAINT TRIGGER ck_reimbursement_receipt_allocations_reimbursement AFTER INSERT OR UPDATE OR DELETE ON reimbursement_receipt_allocations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fiscal_reimbursement_receipt_child_trigger()"
    )
    for table in ("transactions", "postings", "installment_ledger_links"):
        op.execute(
            f"CREATE CONSTRAINT TRIGGER ck_{table}_reimbursement AFTER INSERT OR UPDATE OR DELETE ON {table} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fiscal_reimbursement_transaction_trigger()"
        )


def downgrade() -> None:
    op.execute(
        "DO $$ BEGIN IF EXISTS(SELECT 1 FROM reimbursement_claims) OR EXISTS(SELECT 1 FROM transactions WHERE kind='reimbursement_receipt') THEN RAISE EXCEPTION 'P6 downgrade blocked: reimbursement data exists' USING ERRCODE='object_not_in_prerequisite_state'; END IF; END $$"
    )
    for table in (
        "transactions",
        "postings",
        "installment_ledger_links",
        "reimbursement_receipt_allocations",
        "reimbursement_claims",
        "reimbursement_parties",
        "reimbursement_allocations",
        "reimbursement_receipts",
    ):
        op.execute(f"DROP TRIGGER IF EXISTS ck_{table}_reimbursement ON {table}")
    for fn in (
        "fiscal_reimbursement_transaction_trigger()",
        "fiscal_reimbursement_receipt_child_trigger()",
        "fiscal_reimbursement_claim_trigger()",
        "fiscal_validate_reimbursement_claim(uuid)",
        "fiscal_reimbursement_expense_capacity(uuid)",
    ):
        op.execute(f"DROP FUNCTION IF EXISTS {fn}")
    for table in (
        "reimbursement_operations",
        "reimbursement_receipt_revisions",
        "reimbursement_claim_revisions",
        "reimbursement_receipt_allocations",
        "reimbursement_receipts",
        "reimbursement_allocations",
        "reimbursement_parties",
    ):
        op.drop_table(table)
    op.drop_index("ix_reimbursement_claims_timeline", table_name="reimbursement_claims")
    op.drop_table("reimbursement_claims")
    op.drop_constraint(op.f("ck_transactions_valid_kind"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_kind",
        "transactions",
        "kind IN ('income','expense','transfer','credit_purchase','repayment','installment_fee','installment_refund')",
    )
    from importlib.util import module_from_spec, spec_from_file_location
    from pathlib import Path

    path = Path(__file__).with_name("20260715_0005_installments.py")
    spec = spec_from_file_location("p5_migration", path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    op.execute(module.P5_SHAPE_FUNCTION)
