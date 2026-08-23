"""Allow guarded deletion of unposted AI proposals.

Revision ID: 20260823_0036
Revises: 20260816_0035
"""

from collections.abc import Sequence

from alembic import op

revision: str = "20260823_0036"
down_revision: str | None = "20260816_0035"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

QUALITY_EVENT_FK = "fk_ai_quality_events_proposal_id_ai_proposals"


def upgrade() -> None:
    op.execute("""
        CREATE FUNCTION fiscal_guard_ai_proposal_delete() RETURNS trigger AS $$
        BEGIN
          IF OLD.status NOT IN ('pending','failed','ignored')
             OR OLD.transaction_id IS NOT NULL
             OR OLD.cash_flow_item_id IS NOT NULL THEN
            RAISE EXCEPTION 'only unposted AI proposals can be deleted';
          END IF;
          RETURN OLD;
        END; $$ LANGUAGE plpgsql;
    """)
    op.execute("""
        CREATE TRIGGER ai_proposals_delete_guard
        BEFORE DELETE ON ai_proposals
        FOR EACH ROW EXECUTE FUNCTION fiscal_guard_ai_proposal_delete();
    """)
    op.drop_constraint(QUALITY_EVENT_FK, "ai_quality_events", type_="foreignkey")
    op.create_foreign_key(
        QUALITY_EVENT_FK,
        "ai_quality_events",
        "ai_proposals",
        ["proposal_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.execute("""
        CREATE OR REPLACE FUNCTION fiscal_prevent_ai_quality_event_mutation()
        RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
            RETURN OLD;
          END IF;
          RAISE EXCEPTION 'ai_quality_events are immutable';
        END; $$ LANGUAGE plpgsql;
    """)


def downgrade() -> None:
    op.execute("""
        CREATE OR REPLACE FUNCTION fiscal_prevent_ai_quality_event_mutation()
        RETURNS trigger AS $$
        BEGIN RAISE EXCEPTION 'ai_quality_events are immutable'; END;
        $$ LANGUAGE plpgsql;
    """)
    op.drop_constraint(QUALITY_EVENT_FK, "ai_quality_events", type_="foreignkey")
    op.create_foreign_key(
        QUALITY_EVENT_FK,
        "ai_quality_events",
        "ai_proposals",
        ["proposal_id"],
        ["id"],
        ondelete="RESTRICT",
    )
    op.execute("DROP TRIGGER IF EXISTS ai_proposals_delete_guard ON ai_proposals")
    op.execute("DROP FUNCTION IF EXISTS fiscal_guard_ai_proposal_delete()")
