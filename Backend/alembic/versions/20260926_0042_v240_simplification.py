"""Retire unused statement imports and flatten single-counterparty reimbursements.

Revision ID: 20260926_0042
Revises: 20260922_0041
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260926_0042"
down_revision: str | None = "20260922_0041"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

STATEMENT_TABLES = (
    "statement_import_transaction_provenance",
    "statement_import_final_create_drafts",
    "statement_import_confirmation_operations",
    "statement_import_draft_resolutions",
    "statement_import_review_candidates",
    "statement_import_validation_checks",
    "statement_import_validation_runs",
    "statement_import_provider_snapshot_source_refs",
    "statement_import_provider_attempt_snapshots",
    "statement_import_provider_attempts",
    "statement_import_resolutions",
    "statement_import_operations",
    "statement_import_rows",
    "statement_import_pages",
    "statement_import_attempts",
    "statement_imports",
)

REIMBURSEMENT_VALIDATOR = """
CREATE OR REPLACE FUNCTION fiscal_validate_reimbursement_claim(p_claim_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE c record; rid uuid; aid uuid; total numeric; tx_amount numeric;
 tx_voided timestamptz; allocated numeric;
BEGIN
 SELECT * INTO c FROM reimbursement_claims WHERE id=p_claim_id FOR UPDATE;
 IF NOT FOUND THEN RETURN; END IF;
 IF c.voided_at IS NULL AND NOT EXISTS(
  SELECT 1 FROM reimbursement_allocations WHERE claim_id=c.id
 ) THEN RAISE EXCEPTION 'reimbursement claim requires expenses' USING ERRCODE='check_violation'; END IF;
 IF EXISTS(
  SELECT 1 FROM reimbursement_allocations a JOIN transactions t ON t.id=a.transaction_id
  WHERE a.claim_id=c.id AND (t.kind NOT IN ('expense','credit_purchase') OR t.voided_at IS NOT NULL)
 ) THEN RAISE EXCEPTION 'reimbursement expense not eligible' USING ERRCODE='check_violation'; END IF;
 FOR aid IN SELECT DISTINCT transaction_id FROM reimbursement_allocations LOOP
  SELECT COALESCE(sum(
   CASE WHEN cl.voided_at IS NOT NULL THEN 0
   WHEN cl.cancelled_at IS NULL THEN a.amount_minor
   ELSE COALESCE((
    SELECT sum(ra.amount_minor) FROM reimbursement_receipt_allocations ra
    JOIN reimbursement_receipts r ON r.id=ra.receipt_id
    JOIN transactions rt ON rt.id=r.transaction_id AND rt.voided_at IS NULL
    WHERE ra.allocation_id=a.id
   ),0) END
  ),0) INTO allocated
  FROM reimbursement_allocations a JOIN reimbursement_claims cl ON cl.id=a.claim_id
  WHERE a.transaction_id=aid;
  IF allocated > fiscal_reimbursement_expense_capacity(aid)
  THEN RAISE EXCEPTION 'reimbursement expense overallocated' USING ERRCODE='check_violation'; END IF;
 END LOOP;
 FOR rid IN SELECT id FROM reimbursement_receipts WHERE claim_id=c.id LOOP
  SELECT p.amount_minor::numeric,t.voided_at INTO tx_amount,tx_voided
  FROM reimbursement_receipts r JOIN transactions t ON t.id=r.transaction_id
  JOIN postings p ON p.transaction_id=t.id AND p.role='account'
  WHERE r.id=rid AND t.kind='reimbursement_receipt' AND t.source='system';
  SELECT COALESCE(sum(ra.amount_minor::numeric),0) INTO total
  FROM reimbursement_receipt_allocations ra WHERE ra.receipt_id=rid;
  IF tx_amount IS NULL OR (tx_voided IS NULL AND total<>tx_amount)
   OR (tx_voided IS NOT NULL AND total<>0)
  THEN RAISE EXCEPTION 'reimbursement receipt allocation mismatch' USING ERRCODE='check_violation'; END IF;
  IF EXISTS(
   SELECT 1 FROM reimbursement_receipt_allocations ra
   JOIN reimbursement_allocations a ON a.id=ra.allocation_id
   WHERE ra.receipt_id=rid AND a.claim_id<>c.id
  ) THEN RAISE EXCEPTION 'reimbursement receipt allocation ownership mismatch'
   USING ERRCODE='check_violation'; END IF;
 END LOOP;
 IF EXISTS(
  SELECT 1 FROM reimbursement_allocations a WHERE a.claim_id=c.id
  AND COALESCE((
   SELECT sum(ra.amount_minor::numeric) FROM reimbursement_receipt_allocations ra
   JOIN reimbursement_receipts r ON r.id=ra.receipt_id
   JOIN transactions t ON t.id=r.transaction_id AND t.voided_at IS NULL
   WHERE ra.allocation_id=a.id
  ),0)>a.amount_minor
 ) THEN RAISE EXCEPTION 'reimbursement expense overpaid' USING ERRCODE='check_violation'; END IF;
END $$;
"""


def _guard() -> None:
    connection = op.get_bind()
    for table in STATEMENT_TABLES:
        count = connection.scalar(sa.select(sa.func.count()).select_from(sa.table(table)))
        if count:
            raise RuntimeError(f"0042 cannot retire nonempty {table}; restore with 0041 tools")
    if connection.scalar(
        sa.text("""
        SELECT count(*) FROM (
          SELECT c.id FROM reimbursement_claims c
          LEFT JOIN reimbursement_parties p ON p.claim_id=c.id
          GROUP BY c.id, c.submitted_at
          HAVING count(p.id)>1 OR (
            count(p.id)=0 AND (
              c.submitted_at IS NOT NULL OR EXISTS (
                SELECT 1 FROM reimbursement_allocations a WHERE a.claim_id=c.id
              ) OR EXISTS (
                SELECT 1 FROM reimbursement_receipts r WHERE r.claim_id=c.id
              )
            )
          )
        ) bad
    """)
    ):
        raise RuntimeError("0042 cannot flatten multi-party or malformed submitted claims")
    if connection.scalar(
        sa.text("""
        SELECT count(*) FROM reimbursement_allocations a
        JOIN reimbursement_parties p ON p.id=a.party_id
        WHERE p.claim_id<>a.claim_id
    """)
    ) or connection.scalar(
        sa.text("""
        SELECT count(*) FROM reimbursement_receipts r
        JOIN reimbursement_parties p ON p.id=r.party_id
        WHERE p.claim_id<>r.claim_id
    """)
    ):
        raise RuntimeError("0042 reimbursement ownership mismatch")
    if connection.scalar(
        sa.text("""
        SELECT count(*) FROM reimbursement_claims c
        JOIN reimbursement_parties p ON p.claim_id=c.id
        WHERE c.note IS NOT NULL AND p.note IS NOT NULL AND c.note<>p.note
          AND char_length(c.note)+char_length(p.note)+1>500
    """)
    ):
        raise RuntimeError("0042 cannot merge oversized claim and counterparty notes")
    if connection.scalar(
        sa.text("""
        WITH used AS (
          SELECT a.transaction_id,
            sum(CASE WHEN c.voided_at IS NOT NULL THEN 0
              WHEN c.cancelled_at IS NULL THEN a.amount_minor
              ELSE COALESCE((
                SELECT sum(ra.amount_minor) FROM reimbursement_receipt_allocations ra
                JOIN reimbursement_receipts r ON r.id=ra.receipt_id
                JOIN transactions t ON t.id=r.transaction_id AND t.voided_at IS NULL
                WHERE ra.allocation_id=a.id
              ),0) END) AS amount_minor
          FROM reimbursement_allocations a
          JOIN reimbursement_claims c ON c.id=a.claim_id
          GROUP BY a.transaction_id
        )
        SELECT count(*) FROM used
        WHERE amount_minor>fiscal_reimbursement_expense_capacity(transaction_id)
    """)
    ):
        raise RuntimeError("0042 reimbursement expense capacity mismatch")
    if connection.scalar(
        sa.text("""
        SELECT count(*) FROM reimbursement_receipts r
        JOIN transactions t ON t.id=r.transaction_id
        LEFT JOIN postings p ON p.transaction_id=t.id AND p.role='account'
        LEFT JOIN LATERAL (
          SELECT COALESCE(sum(amount_minor),0) AS amount_minor
          FROM reimbursement_receipt_allocations WHERE receipt_id=r.id
        ) ra ON true
        WHERE t.kind<>'reimbursement_receipt' OR t.source<>'system'
          OR p.id IS NULL
          OR (t.voided_at IS NULL AND ra.amount_minor<>p.amount_minor)
          OR (t.voided_at IS NOT NULL AND ra.amount_minor<>0)
    """)
    ) or connection.scalar(
        sa.text("""
        SELECT count(*) FROM reimbursement_allocations a
        WHERE COALESCE((
          SELECT sum(ra.amount_minor) FROM reimbursement_receipt_allocations ra
          JOIN reimbursement_receipts r ON r.id=ra.receipt_id
          JOIN transactions t ON t.id=r.transaction_id AND t.voided_at IS NULL
          WHERE ra.allocation_id=a.id
        ),0)>a.amount_minor
    """)
    ):
        raise RuntimeError("0042 reimbursement receipt allocation mismatch")
    if connection.scalar(
        sa.text("""
        SELECT count(*) FROM cash_flow_system_overrides o
        JOIN reimbursement_parties p ON p.id=o.system_reference_id
        JOIN cash_flow_system_overrides newer
          ON newer.system_kind='reimbursement' AND newer.system_reference_id=p.claim_id
          AND newer.id<>o.id
        WHERE o.system_kind='reimbursement'
    """)
    ):
        raise RuntimeError("0042 reimbursement override claim-id collision")
    if connection.scalar(
        sa.text("""
        SELECT count(*) FROM cash_flow_system_overrides o
        WHERE o.system_kind='reimbursement' AND NOT EXISTS (
          SELECT 1 FROM reimbursement_parties p WHERE p.id=o.system_reference_id
        )
    """)
    ):
        raise RuntimeError("0042 has orphan reimbursement override")


def upgrade() -> None:
    _guard()
    op.add_column("reimbursement_claims", sa.Column("counterparty_name", sa.String(120)))
    op.add_column("reimbursement_claims", sa.Column("expected_date", sa.Date()))
    op.execute("""
        UPDATE reimbursement_claims c SET
          counterparty_name=p.name,
          expected_date=p.expected_date,
          note=CASE
            WHEN c.note IS NULL THEN p.note
            WHEN p.note IS NULL OR c.note=p.note THEN c.note
            ELSE c.note || E'\n' || p.note
          END
        FROM reimbursement_parties p WHERE p.claim_id=c.id
    """)
    op.execute("""
        UPDATE reimbursement_claims SET counterparty_name=title
        WHERE counterparty_name IS NULL AND submitted_at IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM reimbursement_allocations a WHERE a.claim_id=reimbursement_claims.id
          )
    """)
    # The claim UPDATE queues the 0041 deferred reimbursement validator. Flush
    # it while the party table still exists, before PostgreSQL alters the row type.
    op.execute("SET CONSTRAINTS ALL IMMEDIATE")
    op.alter_column("reimbursement_claims", "counterparty_name", nullable=False)
    op.create_check_constraint(
        "counterparty_name_length",
        "reimbursement_claims",
        "char_length(counterparty_name) BETWEEN 1 AND 120",
    )
    op.execute("""
        UPDATE cash_flow_system_overrides o SET system_reference_id=p.claim_id
        FROM reimbursement_parties p
        WHERE o.system_kind='reimbursement' AND o.system_reference_id=p.id
    """)
    op.drop_constraint(
        "fk_reimbursement_allocations_party_id_reimbursement_parties",
        "reimbursement_allocations",
        type_="foreignkey",
    )
    op.drop_constraint(
        "fk_reimbursement_receipts_party_id_reimbursement_parties",
        "reimbursement_receipts",
        type_="foreignkey",
    )
    op.drop_constraint(
        "uq_reimbursement_allocations_matrix",
        "reimbursement_allocations",
        type_="unique",
    )
    op.drop_column("reimbursement_allocations", "party_id")
    op.drop_column("reimbursement_receipts", "party_id")
    op.create_unique_constraint(
        "uq_reimbursement_allocations_expense",
        "reimbursement_allocations",
        ["claim_id", "transaction_id"],
    )
    op.execute(REIMBURSEMENT_VALIDATOR)
    op.drop_table("reimbursement_parties")
    # The import and attempt tables reference each other; break only this known cycle.
    op.drop_constraint(
        "fk_statement_imports_latest_attempt", "statement_imports", type_="foreignkey"
    )
    for table in STATEMENT_TABLES:
        op.drop_table(table)
    op.execute("DROP TRIGGER ai_proposals_evidence_immutable ON ai_proposals")
    op.execute("DROP FUNCTION fiscal_preserve_ai_proposal_evidence()")
    op.drop_table("ai_quality_events")
    op.execute("DROP FUNCTION fiscal_prevent_ai_quality_event_mutation()")
    op.drop_table("ai_execution_policies")
    op.drop_table("ai_shadow_evaluations")
    for name in (
        "ck_ai_settings_auto_execute_retired",
        "ck_ai_settings_auto_limit_range",
        "ck_ai_settings_confidence_range",
    ):
        op.drop_constraint(op.f(name), "ai_settings", type_="check")
    for name in (
        "auto_execute_enabled",
        "auto_execute_limit_minor",
        "minimum_confidence_bps",
    ):
        op.drop_column("ai_settings", name)
    for name in (
        "initial_parse_snapshot",
        "final_confirmed_snapshot",
        "final_field_diff",
    ):
        op.drop_column("ai_proposals", name)


def downgrade() -> None:
    raise RuntimeError("0042 is intentionally irreversible; restore a verified 0041 backup")
