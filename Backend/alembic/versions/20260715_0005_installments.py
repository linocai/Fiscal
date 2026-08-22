"""Add P5 installment plans, allocations, operations, and ledger links.

Revision ID: 20260715_0005
Revises: 20260715_0004
Create Date: 2026-07-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260715_0005"
down_revision: str | None = "20260715_0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


P5_SHAPE_FUNCTION = r"""
CREATE OR REPLACE FUNCTION fiscal_validate_transaction_shape(p_transaction_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
 v_kind varchar(32); v_source varchar(16); v_category uuid; v_cycle uuid;
 v_direction varchar(16); v_count int; v_account int; v_src int; v_dst int;
 v_sum bigint; v_min bigint; v_max bigint; v_primary_kind varchar(16); v_account_pos int; v_src_pos int; v_dst_pos int;
 v_destination_kind varchar(16); v_primary uuid; v_destination uuid; v_cycle_account uuid;
BEGIN
 SELECT kind,source,category_id,credit_cycle_id INTO v_kind,v_source,v_category,v_cycle
 FROM transactions WHERE id=p_transaction_id; IF NOT FOUND THEN RETURN; END IF;
 SELECT count(*),count(*) FILTER(WHERE role='account'),count(*) FILTER(WHERE role='source'),
 count(*) FILTER(WHERE role='destination'),count(*) FILTER(WHERE role='account' AND position=0),
 count(*) FILTER(WHERE role='source' AND position=0),count(*) FILTER(WHERE role='destination' AND position=1),
 coalesce(sum(amount_minor),0),min(amount_minor),max(amount_minor),
 (array_agg(account_id ORDER BY position) FILTER(WHERE role IN ('account','source')))[1],
 (array_agg(account_id ORDER BY position) FILTER(WHERE role='destination'))[1]
 INTO v_count,v_account,v_src,v_dst,v_account_pos,v_src_pos,v_dst_pos,v_sum,v_min,v_max,v_primary,v_destination
 FROM postings WHERE transaction_id=p_transaction_id;
 SELECT kind INTO v_primary_kind FROM accounts WHERE id=v_primary;
 SELECT kind INTO v_destination_kind FROM accounts WHERE id=v_destination;
 SELECT account_id INTO v_cycle_account FROM credit_cycles WHERE id=v_cycle;
 SELECT direction INTO v_direction FROM categories WHERE id=v_category;
 IF v_kind IN ('income','expense') THEN
  IF v_source<>'manual' OR v_cycle IS NOT NULL OR v_category IS NULL OR v_direction<>v_kind OR
     v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR (v_kind='income' AND v_sum<=0) OR (v_kind='expense' AND v_sum>=0) OR
     v_primary_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid income/expense posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='transfer' THEN
  IF v_source<>'manual' OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR
     v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind NOT IN ('cash','debit')
  THEN RAISE EXCEPTION 'invalid transfer posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='credit_purchase' THEN
  IF v_source<>'manual' OR v_cycle IS NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR
     v_sum>=0 OR v_primary_kind<>'credit' OR v_cycle_account<>v_primary
  THEN RAISE EXCEPTION 'invalid credit purchase posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind='repayment' THEN
  IF v_source NOT IN ('manual','system') OR v_cycle IS NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR
     v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind<>'credit' OR v_cycle_account<>v_destination
  THEN RAISE EXCEPTION 'invalid repayment posting shape' USING ERRCODE='check_violation'; END IF;
 ELSIF v_kind IN ('installment_fee','installment_refund') THEN
  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR
     v_primary_kind<>'credit' OR (v_kind='installment_fee' AND v_sum>=0) OR (v_kind='installment_refund' AND v_sum<=0)
  THEN RAISE EXCEPTION 'invalid installment posting shape' USING ERRCODE='check_violation'; END IF;
 ELSE RAISE EXCEPTION 'invalid transaction kind' USING ERRCODE='check_violation'; END IF;
END $$;
"""

INSTALLMENT_VALIDATOR = r"""
CREATE OR REPLACE FUNCTION fiscal_validate_installment_plan(p_plan_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p record; purchase record; fee record; n int; minseq int; maxseq int; psum numeric; fsum numeric; refunded_p numeric; refunded_f numeric;
BEGIN
 SELECT * INTO p FROM installment_plans WHERE id=p_plan_id; IF NOT FOUND THEN RETURN; END IF;
 SELECT t.kind,t.source,t.voided_at,t.category_id,po.account_id,po.amount_minor INTO purchase
 FROM transactions t JOIN postings po ON po.transaction_id=t.id AND po.role='account' WHERE t.id=p.purchase_transaction_id;
 IF purchase.kind<>'credit_purchase' OR purchase.source<>'manual' OR purchase.voided_at IS NOT NULL OR purchase.account_id<>p.credit_account_id OR purchase.amount_minor>=0
 THEN RAISE EXCEPTION 'invalid installment purchase ownership' USING ERRCODE='check_violation'; END IF;
 IF NOT EXISTS(SELECT 1 FROM installment_ledger_links WHERE plan_id=p.id AND transaction_id=p.purchase_transaction_id AND role='purchase' AND operation_id IS NULL)
 THEN RAISE EXCEPTION 'installment purchase link missing' USING ERRCODE='check_violation'; END IF;
 SELECT count(*),min(sequence),max(sequence),coalesce(sum(principal_minor) FILTER(WHERE cancelled_at IS NULL),0),coalesce(sum(fee_minor) FILTER(WHERE cancelled_at IS NULL),0)
 INTO n,minseq,maxseq,psum,fsum FROM installment_periods WHERE plan_id=p.id;
 IF n<>p.installment_count OR minseq<>1 OR maxseq<>p.installment_count
 THEN RAISE EXCEPTION 'installment sequence is not contiguous' USING ERRCODE='check_violation'; END IF;
 IF NOT EXISTS(SELECT 1 FROM installment_periods WHERE plan_id=p.id AND sequence=1 AND scheduled_cycle_id=p.start_cycle_id)
 THEN RAISE EXCEPTION 'installment start cycle mismatch' USING ERRCODE='check_violation'; END IF;
 IF EXISTS(SELECT 1 FROM installment_periods ip JOIN credit_cycles sc ON sc.id=ip.scheduled_cycle_id JOIN credit_cycles ec ON ec.id=ip.effective_cycle_id
   WHERE ip.plan_id=p.id AND (sc.account_id<>p.credit_account_id OR ec.account_id<>p.credit_account_id OR sc.is_opening_cycle OR ec.is_opening_cycle))
 THEN RAISE EXCEPTION 'installment cycle ownership invalid' USING ERRCODE='check_violation'; END IF;
 IF EXISTS(SELECT 1 FROM (SELECT ip.sequence,c.statement_date,lag(c.statement_date) OVER(ORDER BY ip.sequence) previous_date
   FROM installment_periods ip JOIN credit_cycles c ON c.id=ip.scheduled_cycle_id WHERE ip.plan_id=p.id) s
   WHERE s.sequence>1 AND s.statement_date<>(s.previous_date + interval '1 month')::date)
 THEN RAISE EXCEPTION 'installment scheduled cycles are not consecutive' USING ERRCODE='check_violation'; END IF;
 SELECT coalesce(sum(abs(po.amount_minor)),0) INTO refunded_p FROM installment_ledger_links l JOIN transactions t ON t.id=l.transaction_id AND t.voided_at IS NULL JOIN postings po ON po.transaction_id=t.id
 WHERE l.plan_id=p.id AND l.role='principal_refund';
 IF psum <> abs(purchase.amount_minor)-refunded_p THEN RAISE EXCEPTION 'installment principal allocation mismatch' USING ERRCODE='check_violation'; END IF;
 IF p.fee_transaction_id IS NULL THEN IF p.fee_category_id IS NOT NULL OR fsum<>0 THEN RAISE EXCEPTION 'invalid zero fee plan' USING ERRCODE='check_violation'; END IF;
 ELSE
  SELECT t.kind,t.source,t.voided_at,t.category_id,po.account_id,po.amount_minor INTO fee FROM transactions t JOIN postings po ON po.transaction_id=t.id WHERE t.id=p.fee_transaction_id;
  IF fee.kind<>'installment_fee' OR fee.source<>'system' OR fee.voided_at IS NOT NULL OR fee.account_id<>p.credit_account_id OR fee.category_id<>p.fee_category_id OR fee.amount_minor>=0
  THEN RAISE EXCEPTION 'invalid installment fee ownership' USING ERRCODE='check_violation'; END IF;
  IF NOT EXISTS(SELECT 1 FROM installment_ledger_links WHERE plan_id=p.id AND transaction_id=p.fee_transaction_id AND role='fee' AND operation_id IS NULL)
  THEN RAISE EXCEPTION 'installment fee link missing' USING ERRCODE='check_violation'; END IF;
  SELECT coalesce(sum(abs(po.amount_minor)),0) INTO refunded_f FROM installment_ledger_links l JOIN transactions t ON t.id=l.transaction_id AND t.voided_at IS NULL JOIN postings po ON po.transaction_id=t.id
  WHERE l.plan_id=p.id AND l.role='fee_refund';
  IF fsum<>abs(fee.amount_minor)-refunded_f THEN RAISE EXCEPTION 'installment fee allocation mismatch' USING ERRCODE='check_violation'; END IF;
 END IF;
 IF EXISTS(SELECT 1 FROM installment_ledger_links l JOIN transactions t ON t.id=l.transaction_id LEFT JOIN installment_operations o ON o.id=l.operation_id
   WHERE l.plan_id=p.id AND ((l.role IN ('principal_refund','fee_refund') AND (t.kind<>'installment_refund' OR t.source<>'system' OR o.kind<>'cancel_future'))
   OR (l.role='settlement_repayment' AND (t.kind<>'repayment' OR t.source<>'system' OR o.kind<>'settle_early'))
   OR (l.role IN ('principal_refund','fee_refund','settlement_repayment') AND (l.operation_id IS NULL OR o.plan_id<>p.id))))
 THEN RAISE EXCEPTION 'invalid installment operation ledger ownership' USING ERRCODE='check_violation'; END IF;
 IF EXISTS(SELECT 1 FROM installment_ledger_links l JOIN transactions t ON t.id=l.transaction_id
   JOIN postings po ON po.transaction_id=t.id AND po.role='account'
   WHERE l.plan_id=p.id AND l.role IN ('principal_refund','fee_refund') AND t.voided_at IS NULL
   AND (po.account_id<>p.credit_account_id
        OR (l.role='principal_refund' AND t.category_id<>purchase.category_id)
        OR (l.role='fee_refund' AND t.category_id<>p.fee_category_id)))
 THEN RAISE EXCEPTION 'invalid installment refund account or category' USING ERRCODE='check_violation'; END IF;
 IF EXISTS(SELECT 1 FROM installment_ledger_links l JOIN transactions t ON t.id=l.transaction_id
   JOIN postings po ON po.transaction_id=t.id AND po.role='destination'
   WHERE l.plan_id=p.id AND l.role='settlement_repayment' AND t.voided_at IS NULL
   AND (po.account_id<>p.credit_account_id OR po.amount_minor<>(
       SELECT COALESCE(sum(ip.principal_minor+ip.fee_minor),0) FROM installment_periods ip
       WHERE ip.plan_id=p.id AND ip.cancelled_at IS NULL AND ip.settled_early_at IS NOT NULL)))
 THEN RAISE EXCEPTION 'invalid installment settlement destination or amount' USING ERRCODE='check_violation'; END IF;
END $$;
CREATE OR REPLACE FUNCTION fiscal_installment_deferred_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pid uuid;
BEGIN
 IF TG_TABLE_NAME='installment_plans' THEN pid:=CASE WHEN TG_OP='DELETE' THEN OLD.id ELSE NEW.id END;
 ELSE pid:=CASE WHEN TG_OP='DELETE' THEN OLD.plan_id ELSE NEW.plan_id END; END IF;
 PERFORM fiscal_validate_installment_plan(pid); RETURN NULL;
END $$;
CREATE OR REPLACE FUNCTION fiscal_installment_linked_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE tid uuid; pid uuid;
BEGIN
 IF TG_TABLE_NAME='postings' THEN
  IF TG_OP='DELETE' THEN tid:=OLD.transaction_id; ELSE tid:=NEW.transaction_id; END IF;
 ELSE
  IF TG_OP='DELETE' THEN tid:=OLD.id; ELSE tid:=NEW.id; END IF;
 END IF;
 SELECT plan_id INTO pid FROM installment_ledger_links WHERE transaction_id=tid;
 IF pid IS NOT NULL THEN PERFORM fiscal_validate_installment_plan(pid); END IF; RETURN NULL;
END $$;
"""


def upgrade() -> None:
    op.alter_column("transactions", "kind", type_=sa.String(32), existing_type=sa.String(16))
    op.drop_constraint(op.f("ck_transactions_valid_kind"), "transactions", type_="check")
    op.drop_constraint(op.f("ck_transactions_manual_source"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_kind",
        "transactions",
        "kind IN ('income','expense','transfer','credit_purchase','repayment','installment_fee','installment_refund')",
    )
    op.create_check_constraint("valid_source", "transactions", "source IN ('manual','system')")
    op.execute(P5_SHAPE_FUNCTION)
    op.create_table(
        "installment_plans",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("purchase_transaction_id", sa.Uuid(), nullable=False, unique=True),
        sa.Column("credit_account_id", sa.Uuid(), nullable=False),
        sa.Column("fee_transaction_id", sa.Uuid()),
        sa.Column("fee_category_id", sa.Uuid()),
        sa.Column("installment_count", sa.Integer(), nullable=False),
        sa.Column("start_cycle_id", sa.Uuid(), nullable=False),
        sa.Column("lifecycle", sa.String(24), nullable=False),
        sa.Column("create_idempotency_key", sa.Uuid(), nullable=False, unique=True),
        sa.Column("create_request_hash", sa.String(64), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("installment_count BETWEEN 2 AND 60", name="count_range"),
        sa.CheckConstraint(
            "lifecycle IN ('active','settled_early','partially_cancelled','cancelled')",
            name="valid_lifecycle",
        ),
        sa.CheckConstraint("version>=1", name="version_positive"),
        sa.ForeignKeyConstraint(
            ["purchase_transaction_id"], ["transactions.id"], ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(["credit_account_id"], ["accounts.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["fee_transaction_id"], ["transactions.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["fee_category_id"], ["categories.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["start_cycle_id"], ["credit_cycles.id"], ondelete="RESTRICT"),
    )
    op.create_index(
        "ix_installment_plans_account",
        "installment_plans",
        ["credit_account_id", sa.text("created_at DESC")],
    )
    op.create_table(
        "installment_periods",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("plan_id", sa.Uuid(), nullable=False),
        sa.Column("sequence", sa.Integer(), nullable=False),
        sa.Column("scheduled_cycle_id", sa.Uuid(), nullable=False),
        sa.Column("effective_cycle_id", sa.Uuid(), nullable=False),
        sa.Column("principal_minor", sa.BigInteger(), nullable=False),
        sa.Column("fee_minor", sa.BigInteger(), nullable=False),
        sa.Column("cancelled_at", sa.DateTime(timezone=True)),
        sa.Column("settled_early_at", sa.DateTime(timezone=True)),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("sequence>=1", name="sequence_positive"),
        sa.CheckConstraint(
            "principal_minor>=0 AND fee_minor>=0 AND principal_minor+fee_minor>0",
            name="nonzero_allocation",
        ),
        sa.CheckConstraint("version>=1", name="version_positive"),
        sa.ForeignKeyConstraint(["plan_id"], ["installment_plans.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["scheduled_cycle_id"], ["credit_cycles.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["effective_cycle_id"], ["credit_cycles.id"], ondelete="RESTRICT"),
        sa.UniqueConstraint("plan_id", "sequence", name="uq_installment_periods_plan_sequence"),
    )
    op.create_index(
        "ix_installment_periods_effective_cycle", "installment_periods", ["effective_cycle_id"]
    )
    op.create_table(
        "installment_operations",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("plan_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.String(24), nullable=False),
        sa.Column("idempotency_key", sa.Uuid(), nullable=False, unique=True),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("target_statement_date", sa.Date()),
        sa.Column("payment_account_id", sa.Uuid()),
        sa.Column("occurred_at", sa.DateTime(timezone=True)),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
        sa.Column("reversed_at", sa.DateTime(timezone=True)),
        sa.Column("result_snapshot", postgresql.JSONB()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "kind IN ('settle_early','reverse_settlement','cancel_future')", name="valid_kind"
        ),
        sa.ForeignKeyConstraint(["plan_id"], ["installment_plans.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["payment_account_id"], ["accounts.id"], ondelete="RESTRICT"),
    )
    op.create_index(
        "ix_installment_operations_plan",
        "installment_operations",
        ["plan_id", sa.text("created_at DESC")],
    )
    op.create_table(
        "installment_ledger_links",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("transaction_id", sa.Uuid(), nullable=False, unique=True),
        sa.Column("plan_id", sa.Uuid(), nullable=False),
        sa.Column("operation_id", sa.Uuid()),
        sa.Column("role", sa.String(32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "role IN ('purchase','fee','principal_refund','fee_refund','settlement_repayment')",
            name="valid_role",
        ),
        sa.ForeignKeyConstraint(["transaction_id"], ["transactions.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["plan_id"], ["installment_plans.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(
            ["operation_id"], ["installment_operations.id"], ondelete="RESTRICT"
        ),
    )
    op.create_index(
        "uq_installment_ledger_links_plan_purchase",
        "installment_ledger_links",
        ["plan_id"],
        unique=True,
        postgresql_where=sa.text("role='purchase'"),
    )
    op.create_index(
        "uq_installment_ledger_links_plan_fee",
        "installment_ledger_links",
        ["plan_id"],
        unique=True,
        postgresql_where=sa.text("role='fee'"),
    )
    op.create_index(
        "uq_installment_ledger_links_operation_role",
        "installment_ledger_links",
        ["operation_id", "role"],
        unique=True,
        postgresql_where=sa.text("operation_id IS NOT NULL"),
    )
    op.create_table(
        "installment_plan_revisions",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("plan_id", sa.Uuid(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("event", sa.String(32), nullable=False),
        sa.Column("snapshot", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["plan_id"], ["installment_plans.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("plan_id", "version", name="uq_installment_plan_revisions_version"),
    )
    validator_parts = INSTALLMENT_VALIDATOR.split("\nCREATE OR REPLACE FUNCTION ")
    op.execute(validator_parts[0])
    for validator_part in validator_parts[1:]:
        op.execute("CREATE OR REPLACE FUNCTION " + validator_part)
    for table in ("installment_plans", "installment_periods", "installment_ledger_links"):
        op.execute(
            f"CREATE CONSTRAINT TRIGGER ck_{table}_allocation AFTER INSERT OR UPDATE OR DELETE ON {table} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fiscal_installment_deferred_check()"
        )
    for table in ("transactions", "postings"):
        op.execute(
            f"CREATE CONSTRAINT TRIGGER ck_{table}_installment_allocation AFTER INSERT OR UPDATE OR DELETE ON {table} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fiscal_installment_linked_check()"
        )


def downgrade() -> None:
    op.execute(
        "DO $$ BEGIN IF EXISTS(SELECT 1 FROM installment_plans) OR EXISTS(SELECT 1 FROM transactions WHERE source='system' OR kind IN ('installment_fee','installment_refund')) THEN RAISE EXCEPTION 'P5 downgrade blocked: installment data exists' USING ERRCODE='object_not_in_prerequisite_state'; END IF; END $$"
    )
    for table in ("installment_plans", "installment_periods", "installment_ledger_links"):
        op.execute(f"DROP TRIGGER IF EXISTS ck_{table}_allocation ON {table}")
    for table in ("transactions", "postings"):
        op.execute(f"DROP TRIGGER IF EXISTS ck_{table}_installment_allocation ON {table}")
    op.execute("DROP FUNCTION IF EXISTS fiscal_installment_linked_check()")
    op.execute("DROP FUNCTION IF EXISTS fiscal_installment_deferred_check()")
    op.execute("DROP FUNCTION IF EXISTS fiscal_validate_installment_plan(uuid)")
    op.drop_table("installment_plan_revisions")
    op.drop_table("installment_ledger_links")
    op.drop_table("installment_operations")
    op.drop_table("installment_periods")
    op.drop_table("installment_plans")
    op.drop_constraint(op.f("ck_transactions_valid_source"), "transactions", type_="check")
    op.drop_constraint(op.f("ck_transactions_valid_kind"), "transactions", type_="check")
    op.create_check_constraint("manual_source", "transactions", "source='manual'")
    op.create_check_constraint(
        "valid_kind",
        "transactions",
        "kind IN ('income','expense','transfer','credit_purchase','repayment')",
    )
    op.alter_column("transactions", "kind", type_=sa.String(16), existing_type=sa.String(32))
    # Extra P5 branches are unreachable behind the restored P4 checks.
    op.execute(P5_SHAPE_FUNCTION)
