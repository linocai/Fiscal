"""P33 makes completed installment plans an explicit persisted lifecycle.

Revision ID: 20260814_0031
Revises: 20260814_0030
"""

from collections.abc import Sequence

from alembic import op

revision: str = "20260814_0031"
down_revision: str | None = "20260814_0030"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_constraint("valid_lifecycle", "installment_plans", type_="check")
    op.create_check_constraint(
        "valid_lifecycle",
        "installment_plans",
        "lifecycle IN ('active','completed','settled_early','partially_cancelled','cancelled')",
    )
    # Backfill from the same ledger conservation formula used by the plan list
    # query.  This changes only a lifecycle label: periods, repayment postings
    # and all monetary values are untouched.
    op.execute(
        """
        UPDATE installment_plans plan
           SET lifecycle = 'completed'
         WHERE plan.lifecycle IN ('active', 'partially_cancelled')
           AND EXISTS (
                SELECT 1 FROM installment_periods present
                 WHERE present.plan_id = plan.id
                   AND present.cancelled_at IS NULL
           )
           AND NOT EXISTS (
                SELECT 1
                  FROM installment_periods ip
                  JOIN credit_cycles cycle ON cycle.id = ip.effective_cycle_id
                 WHERE ip.plan_id = plan.id
                   AND ip.cancelled_at IS NULL
                   AND (
                    COALESCE((SELECT SUM(ap.principal_minor + ap.fee_minor)
                                FROM installment_periods ap
                               WHERE ap.effective_cycle_id = ip.effective_cycle_id
                                 AND ap.cancelled_at IS NULL), 0)
                    + COALESCE((SELECT SUM(-posting.amount_minor)
                                  FROM transactions tx
                                  JOIN postings posting ON posting.transaction_id = tx.id
                                 WHERE tx.credit_cycle_id = ip.effective_cycle_id
                                   AND tx.kind = 'credit_purchase'
                                   AND tx.voided_at IS NULL
                                   AND NOT EXISTS (
                                     SELECT 1 FROM installment_ledger_links link
                                      WHERE link.transaction_id = tx.id
                                   )), 0)
                    + CASE WHEN cycle.is_opening_cycle THEN
                        (SELECT opening_balance_minor FROM accounts WHERE id = cycle.account_id)
                      ELSE 0 END
                    - COALESCE((SELECT SUM(posting.amount_minor)
                                  FROM transactions tx
                                  JOIN postings posting ON posting.transaction_id = tx.id
                                 WHERE tx.credit_cycle_id = ip.effective_cycle_id
                                   AND tx.kind = 'repayment'
                                   AND tx.voided_at IS NULL
                                   AND posting.role = 'destination'), 0)
                   ) <> 0
           )
        """
    )


def downgrade() -> None:
    # A historical database cannot represent the explicit terminal state;
    # retain its financial facts under the legacy active-derived-completed path.
    op.execute("UPDATE installment_plans SET lifecycle = 'active' WHERE lifecycle = 'completed'")
    op.drop_constraint("valid_lifecycle", "installment_plans", type_="check")
    op.create_check_constraint(
        "valid_lifecycle",
        "installment_plans",
        "lifecycle IN ('active','settled_early','partially_cancelled','cancelled')",
    )
