"""On-demand credit, atomic payoff history and cash-flow settlement links."""

import sqlalchemy as sa
from alembic import op

revision = "20260912_0040"
down_revision = "20260910_0039"
branch_labels = None
depends_on = None


P39_SHAPE = "\nCREATE OR REPLACE FUNCTION fiscal_validate_transaction_shape(p_transaction_id uuid)\nRETURNS void LANGUAGE plpgsql AS $$\nDECLARE v_kind varchar(32); v_source varchar(16); v_category uuid; v_cycle uuid; v_direction varchar(16);\n v_count int; v_account int; v_src int; v_dst int; v_sum numeric; v_min bigint; v_max bigint;\n v_primary_kind varchar(16); v_destination_kind varchar(16); v_primary uuid; v_destination uuid; v_cycle_account uuid;\n v_account_pos int; v_src_pos int; v_dst_pos int;\nBEGIN\n SELECT kind,source,category_id,credit_cycle_id INTO v_kind,v_source,v_category,v_cycle FROM transactions WHERE id=p_transaction_id; IF NOT FOUND THEN RETURN; END IF;\n SELECT count(*),count(*) FILTER(WHERE role='account'),count(*) FILTER(WHERE role='source'),count(*) FILTER(WHERE role='destination'), count(*) FILTER(WHERE role='account' AND position=0),count(*) FILTER(WHERE role='source' AND position=0),count(*) FILTER(WHERE role='destination' AND position=1), coalesce(sum(amount_minor::numeric),0),min(amount_minor),max(amount_minor), (array_agg(account_id ORDER BY position) FILTER(WHERE role IN ('account','source')))[1],(array_agg(account_id ORDER BY position) FILTER(WHERE role='destination'))[1] INTO v_count,v_account,v_src,v_dst,v_account_pos,v_src_pos,v_dst_pos,v_sum,v_min,v_max,v_primary,v_destination FROM postings WHERE transaction_id=p_transaction_id;\n SELECT kind INTO v_primary_kind FROM accounts WHERE id=v_primary; SELECT kind INTO v_destination_kind FROM accounts WHERE id=v_destination; SELECT account_id INTO v_cycle_account FROM credit_cycles WHERE id=v_cycle; SELECT direction INTO v_direction FROM categories WHERE id=v_category;\n IF v_kind IN ('income','expense') THEN\n  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','cash_flow','statement_import') OR v_cycle IS NOT NULL OR (v_category IS NOT NULL AND v_direction<>v_kind) OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR (v_kind='income' AND v_sum<=0) OR (v_kind='expense' AND v_sum>=0) OR v_primary_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid income/expense posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind='transfer' THEN\n  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','cash_flow','statement_import') OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid transfer posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind='credit_purchase' THEN\n  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','statement_import') OR v_cycle IS NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_sum>=0 OR v_primary_kind<>'credit' OR v_cycle_account<>v_primary THEN RAISE EXCEPTION 'invalid credit purchase posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind='repayment' THEN\n  IF v_source NOT IN ('manual','system','ai_text','ocr','legacy_import','statement_import') OR v_cycle IS NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind<>'credit' OR v_cycle_account<>v_destination THEN RAISE EXCEPTION 'invalid repayment posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind IN ('installment_fee','installment_refund') THEN\n  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_primary_kind<>'credit' OR (v_kind='installment_fee' AND v_sum>=0) OR (v_kind='installment_refund' AND v_sum<=0) THEN RAISE EXCEPTION 'invalid installment posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind='reimbursement_receipt' THEN\n  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_sum<=0 OR v_primary_kind NOT IN ('cash','debit') OR (SELECT count(*) FROM reimbursement_receipts WHERE transaction_id=p_transaction_id)<>1 THEN RAISE EXCEPTION 'invalid reimbursement receipt shape' USING ERRCODE='check_violation'; END IF;\n ELSE RAISE EXCEPTION 'invalid transaction kind' USING ERRCODE='check_violation'; END IF;\nEND $$;\n"

P40_SHAPE = "\nCREATE OR REPLACE FUNCTION fiscal_validate_transaction_shape(p_transaction_id uuid)\nRETURNS void LANGUAGE plpgsql AS $$\nDECLARE v_kind varchar(32); v_source varchar(16); v_category uuid; v_cycle uuid; v_direction varchar(16);\n v_count int; v_account int; v_src int; v_dst int; v_sum numeric; v_min bigint; v_max bigint;\n v_primary_kind varchar(16); v_destination_kind varchar(16); v_primary uuid; v_destination uuid; v_cycle_account uuid;\n v_account_pos int; v_src_pos int; v_dst_pos int;\nBEGIN\n SELECT kind,source,category_id,credit_cycle_id INTO v_kind,v_source,v_category,v_cycle FROM transactions WHERE id=p_transaction_id; IF NOT FOUND THEN RETURN; END IF;\n SELECT count(*),count(*) FILTER(WHERE role='account'),count(*) FILTER(WHERE role='source'),count(*) FILTER(WHERE role='destination'), count(*) FILTER(WHERE role='account' AND position=0),count(*) FILTER(WHERE role='source' AND position=0),count(*) FILTER(WHERE role='destination' AND position=1), coalesce(sum(amount_minor::numeric),0),min(amount_minor),max(amount_minor), (array_agg(account_id ORDER BY position) FILTER(WHERE role IN ('account','source')))[1],(array_agg(account_id ORDER BY position) FILTER(WHERE role='destination'))[1] INTO v_count,v_account,v_src,v_dst,v_account_pos,v_src_pos,v_dst_pos,v_sum,v_min,v_max,v_primary,v_destination FROM postings WHERE transaction_id=p_transaction_id;\n SELECT kind INTO v_primary_kind FROM accounts WHERE id=v_primary; SELECT kind INTO v_destination_kind FROM accounts WHERE id=v_destination; SELECT account_id INTO v_cycle_account FROM credit_cycles WHERE id=v_cycle; SELECT direction INTO v_direction FROM categories WHERE id=v_category;\n IF v_kind IN ('income','expense') THEN\n  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','cash_flow','statement_import') OR v_cycle IS NOT NULL OR (v_category IS NOT NULL AND v_direction<>v_kind) OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR (v_kind='income' AND v_sum<=0) OR (v_kind='expense' AND v_sum>=0) OR v_primary_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid income/expense posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind='transfer' THEN\n  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','cash_flow','statement_import') OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind NOT IN ('cash','debit') THEN RAISE EXCEPTION 'invalid transfer posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind='credit_purchase' THEN\n  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','statement_import') OR v_cycle IS NULL OR (v_category IS NOT NULL AND v_direction<>'expense') OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_sum>=0 OR v_primary_kind<>'credit' OR v_cycle_account<>v_primary THEN RAISE EXCEPTION 'invalid credit purchase posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind='repayment' THEN\n  IF v_source NOT IN ('manual','system','ai_text','ocr','legacy_import','statement_import') OR ((SELECT cycle_mode FROM accounts WHERE id=v_destination)='on_demand' AND v_cycle IS NOT NULL) OR ((SELECT cycle_mode FROM accounts WHERE id=v_destination)<>'on_demand' AND v_cycle IS NULL) OR v_category IS NOT NULL OR v_count<>2 OR v_account<>0 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind NOT IN ('cash','debit') OR v_destination_kind<>'credit' OR v_cycle_account<>v_destination THEN RAISE EXCEPTION 'invalid repayment posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind IN ('installment_fee','installment_refund') THEN\n  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NULL OR v_direction<>'expense' OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_primary_kind<>'credit' OR (v_kind='installment_fee' AND v_sum>=0) OR (v_kind='installment_refund' AND v_sum<=0) THEN RAISE EXCEPTION 'invalid installment posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind='reimbursement_receipt' THEN\n  IF v_source<>'system' OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR v_sum<=0 OR v_primary_kind NOT IN ('cash','debit') OR (SELECT count(*) FROM reimbursement_receipts WHERE transaction_id=p_transaction_id)<>1 THEN RAISE EXCEPTION 'invalid reimbursement receipt shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind='borrowing' THEN\n  IF v_source NOT IN ('manual','ai_text','ocr','legacy_import','statement_import') OR v_cycle IS NOT NULL OR v_category IS NOT NULL OR v_count<>2 OR v_src<>1 OR v_dst<>1 OR v_src_pos<>1 OR v_dst_pos<>1 OR v_sum<>0 OR v_min>=0 OR v_max<=0 OR v_primary_kind<>'credit' OR (SELECT cycle_mode FROM accounts WHERE id=v_primary)<>'on_demand' OR v_destination_kind NOT IN ('cash','debit') OR (SELECT amount_minor FROM postings WHERE transaction_id=p_transaction_id AND role='source')>=0 THEN RAISE EXCEPTION 'invalid borrowing posting shape' USING ERRCODE='check_violation'; END IF;\n ELSIF v_kind IN ('credit_principal_waiver','credit_fee_refund','credit_settlement_fee') THEN\n  IF v_source<>'system' OR v_category IS NOT NULL OR v_count<>1 OR v_account<>1 OR v_account_pos<>1 OR v_src<>0 OR v_dst<>0 OR (v_kind='credit_settlement_fee' AND (v_sum>=0 OR v_primary_kind NOT IN ('cash','debit') OR v_cycle IS NOT NULL)) OR (v_kind<>'credit_settlement_fee' AND (v_sum<=0 OR v_primary_kind<>'credit' OR (v_cycle IS NOT NULL AND v_cycle_account<>v_primary))) OR NOT EXISTS(SELECT 1 FROM credit_payoff_links l JOIN credit_payoff_operations o ON o.id=l.operation_id WHERE l.transaction_id=p_transaction_id AND l.role=v_kind AND ((v_kind='credit_settlement_fee' AND o.payment_account_id=v_primary) OR (v_kind<>'credit_settlement_fee' AND o.account_id=v_primary))) THEN RAISE EXCEPTION 'invalid credit payoff posting shape' USING ERRCODE='check_violation'; END IF;\n ELSE RAISE EXCEPTION 'invalid transaction kind' USING ERRCODE='check_violation'; END IF;\nEND $$;\n"


def upgrade() -> None:
    # 0039 backfills existing transactions in this same migration transaction.
    # Validate its deferred events before ALTER TABLE; never bypass the guards.
    op.execute("SET CONSTRAINTS ALL IMMEDIATE")
    op.execute("SET CONSTRAINTS ALL DEFERRED")
    op.drop_constraint(op.f("ck_ai_proposals_valid_kind"), "ai_proposals", type_="check")
    op.create_check_constraint(
        "valid_kind",
        "ai_proposals",
        "kind IS NULL OR kind IN ('income','expense','transfer','credit_purchase','repayment','borrowing')",
    )
    op.drop_constraint(op.f("ck_accounts_kind_configuration"), "accounts", type_="check")
    op.create_check_constraint(
        "kind_configuration",
        "accounts",
        "(kind = 'credit' AND credit_limit_minor > 0 AND statement_day BETWEEN 1 AND 28 AND due_day BETWEEN 1 AND 28 AND cycle_mode IN ('statement_day_cutoff', 'previous_calendar_month') AND opening_balance_minor >= 0 AND ((opening_balance_minor = 0 AND opening_balance_as_of_date IS NULL AND opening_due_date IS NULL) OR (opening_balance_minor > 0 AND ((opening_balance_as_of_date IS NULL AND opening_due_date IS NULL) OR (opening_balance_as_of_date IS NOT NULL AND opening_due_date IS NOT NULL AND opening_due_date >= opening_balance_as_of_date))))) OR (kind = 'credit' AND cycle_mode = 'on_demand' AND credit_limit_minor IS NULL AND statement_day IS NULL AND due_day IS NULL AND opening_due_date IS NULL AND opening_balance_minor >= 0 AND ((opening_balance_minor = 0 AND opening_balance_as_of_date IS NULL) OR (opening_balance_minor > 0 AND opening_balance_as_of_date IS NOT NULL))) OR (kind IN ('cash', 'debit') AND credit_limit_minor IS NULL AND statement_day IS NULL AND due_day IS NULL AND cycle_mode IS NULL AND opening_balance_as_of_date IS NULL AND opening_due_date IS NULL)",
    )
    op.drop_constraint(op.f("ck_transactions_valid_kind"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_kind",
        "transactions",
        "kind IN ('income', 'expense', 'transfer', 'credit_purchase', 'repayment', 'installment_fee', 'installment_refund', 'reimbursement_receipt', 'borrowing', 'credit_principal_waiver', 'credit_fee_refund', 'credit_settlement_fee')",
    )
    op.execute(
        "\nCREATE TABLE credit_payoff_operations (\n\tid UUID NOT NULL, \n\taccount_id UUID NOT NULL, \n\tpayment_account_id UUID NOT NULL, \n\tidempotency_key UUID NOT NULL, \n\trequest_hash VARCHAR(64) NOT NULL, \n\toccurred_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tstatus VARCHAR(16) NOT NULL, \n\tpayload JSONB NOT NULL, \n\treceipt JSONB NOT NULL, \n\treverse_idempotency_key UUID, \n\treverse_request_hash VARCHAR(64), \n\treversed_at TIMESTAMP WITH TIME ZONE, \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tCONSTRAINT pk_credit_payoff_operations PRIMARY KEY (id), \n\tCONSTRAINT ck_credit_payoff_operations_valid_status CHECK (status IN ('completed', 'reversed')), \n\tCONSTRAINT fk_credit_payoff_operations_account_id_accounts FOREIGN KEY(account_id) REFERENCES accounts (id) ON DELETE RESTRICT, \n\tCONSTRAINT fk_credit_payoff_operations_payment_account_id_accounts FOREIGN KEY(payment_account_id) REFERENCES accounts (id) ON DELETE RESTRICT, \n\tCONSTRAINT uq_credit_payoff_operations_idempotency_key UNIQUE (idempotency_key), \n\tCONSTRAINT uq_credit_payoff_operations_reverse_idempotency_key UNIQUE (reverse_idempotency_key)\n)\n\n"
    )
    op.execute(
        "CREATE INDEX ix_credit_payoff_operations_account_id ON credit_payoff_operations (account_id)"
    )
    op.execute(
        "\nCREATE TABLE credit_payoff_links (\n\tid UUID NOT NULL, \n\toperation_id UUID NOT NULL, \n\ttransaction_id UUID NOT NULL, \n\trole VARCHAR(32) NOT NULL, \n\tcredit_cycle_id UUID, \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tCONSTRAINT pk_credit_payoff_links PRIMARY KEY (id), \n\tCONSTRAINT fk_credit_payoff_links_operation_id_credit_payoff_operations FOREIGN KEY(operation_id) REFERENCES credit_payoff_operations (id) ON DELETE RESTRICT, \n\tCONSTRAINT uq_credit_payoff_links_transaction_id UNIQUE (transaction_id), \n\tCONSTRAINT fk_credit_payoff_links_transaction_id_transactions FOREIGN KEY(transaction_id) REFERENCES transactions (id) ON DELETE RESTRICT, \n\tCONSTRAINT fk_credit_payoff_links_credit_cycle_id_credit_cycles FOREIGN KEY(credit_cycle_id) REFERENCES credit_cycles (id) ON DELETE RESTRICT\n)\n\n"
    )
    op.execute(
        "CREATE INDEX ix_credit_payoff_links_operation_id ON credit_payoff_links (operation_id)"
    )
    op.execute(
        "\nCREATE TABLE cash_flow_settlement_links (\n\tid UUID NOT NULL, \n\titem_id UUID NOT NULL, \n\ttransaction_id UUID NOT NULL, \n\tcloses_remainder BOOLEAN NOT NULL, \n\tidempotency_key UUID, \n\trequest_hash VARCHAR(64), \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tCONSTRAINT pk_cash_flow_settlement_links PRIMARY KEY (id), \n\tCONSTRAINT uq_cash_flow_settlement_links_transaction_id UNIQUE (transaction_id), \n\tCONSTRAINT uq_cash_flow_settlement_links_idempotency_key UNIQUE (idempotency_key), \n\tCONSTRAINT fk_cash_flow_settlement_links_item_id_cash_flow_items FOREIGN KEY(item_id) REFERENCES cash_flow_items (id) ON DELETE RESTRICT, \n\tCONSTRAINT fk_cash_flow_settlement_links_transaction_id_transactions FOREIGN KEY(transaction_id) REFERENCES transactions (id) ON DELETE RESTRICT\n)\n\n"
    )
    op.execute(
        "CREATE INDEX ix_cash_flow_settlement_links_item_id ON cash_flow_settlement_links (item_id)"
    )
    candidates = """
        SELECT i.id AS item_id, t.id AS transaction_id, i.created_at
        FROM cash_flow_items i JOIN transactions t ON t.id = i.linked_transaction_id
        UNION
        SELECT i.id, t.id, i.created_at
        FROM cash_flow_item_revisions r JOIN cash_flow_items i ON i.id = r.item_id
        JOIN transactions t ON t.id::text = r.snapshot->>'linked_transaction_id'
    """
    if op.get_bind().scalar(
        sa.text(
            "SELECT EXISTS(SELECT transaction_id FROM ("  # noqa: S608 -- only literal SQL fragments
            + candidates
            + ") c GROUP BY transaction_id HAVING count(DISTINCT item_id)>1)"
        )
    ):
        raise RuntimeError("legacy cash-flow settlement has ambiguous ownership")
    op.execute(
        "INSERT INTO cash_flow_settlement_links (id,item_id,transaction_id,closes_remainder,created_at) SELECT transaction_id,item_id,transaction_id,true,created_at FROM ("  # noqa: S608 -- only literal SQL fragments
        + candidates
        + ") c"
    )

    op.execute(P40_SHAPE)


def downgrade() -> None:
    connection = op.get_bind()
    if connection.scalar(
        sa.text(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE cycle_mode='on_demand') OR EXISTS(SELECT 1 FROM transactions WHERE kind IN ('borrowing','credit_principal_waiver','credit_fee_refund','credit_settlement_fee')) OR EXISTS(SELECT 1 FROM ai_proposals WHERE kind='borrowing') OR EXISTS(SELECT 1 FROM credit_payoff_operations) OR EXISTS(SELECT 1 FROM cash_flow_settlement_links WHERE idempotency_key IS NOT NULL)"
        )
    ):
        raise RuntimeError("0040 financial data exists; restore a verified backup instead")
    op.drop_constraint(op.f("ck_ai_proposals_valid_kind"), "ai_proposals", type_="check")
    op.create_check_constraint(
        "valid_kind",
        "ai_proposals",
        "kind IS NULL OR kind IN ('income','expense','transfer','credit_purchase','repayment')",
    )
    op.execute(P39_SHAPE)
    op.drop_table("cash_flow_settlement_links")
    op.drop_table("credit_payoff_links")
    op.drop_table("credit_payoff_operations")
    op.drop_constraint(op.f("ck_transactions_valid_kind"), "transactions", type_="check")
    op.create_check_constraint(
        "valid_kind",
        "transactions",
        "kind IN ('income', 'expense', 'transfer', 'credit_purchase', 'repayment', 'installment_fee', 'installment_refund', 'reimbursement_receipt')",
    )
    op.drop_constraint(op.f("ck_accounts_kind_configuration"), "accounts", type_="check")
    op.create_check_constraint(
        "kind_configuration",
        "accounts",
        "(kind = 'credit' AND credit_limit_minor > 0 AND statement_day BETWEEN 1 AND 28 AND due_day BETWEEN 1 AND 28 AND cycle_mode IN ('statement_day_cutoff', 'previous_calendar_month') AND opening_balance_minor >= 0 AND ((opening_balance_minor = 0 AND opening_balance_as_of_date IS NULL AND opening_due_date IS NULL) OR (opening_balance_minor > 0 AND ((opening_balance_as_of_date IS NULL AND opening_due_date IS NULL) OR (opening_balance_as_of_date IS NOT NULL AND opening_due_date IS NOT NULL AND opening_due_date >= opening_balance_as_of_date))))) OR (kind IN ('cash', 'debit') AND credit_limit_minor IS NULL AND statement_day IS NULL AND due_day IS NULL AND cycle_mode IS NULL AND opening_balance_as_of_date IS NULL AND opening_due_date IS NULL)",
    )
