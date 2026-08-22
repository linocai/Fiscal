"""Retire AI automatic execution permanently.

Revision ID: 20260816_0035
Revises: 20260816_0034
"""

from collections.abc import Sequence

from alembic import op

revision: str = "20260816_0035"
down_revision: str | None = "20260816_0034"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute("UPDATE ai_settings SET auto_execute_enabled = false")
    op.execute("UPDATE ai_execution_policies SET auto_execute_enabled = false")
    op.create_check_constraint(
        op.f("ck_ai_settings_auto_execute_retired"),
        "ai_settings",
        "auto_execute_enabled IS FALSE",
    )
    op.create_check_constraint(
        op.f("ck_ai_execution_policies_auto_execute_retired"),
        "ai_execution_policies",
        "auto_execute_enabled IS FALSE",
    )


def downgrade() -> None:
    # Downgrade only removes the newer schema guards. It deliberately does not
    # restore any row to true: retirement is a one-way business decision.
    op.drop_constraint(
        op.f("ck_ai_execution_policies_auto_execute_retired"),
        "ai_execution_policies",
        type_="check",
    )
    op.drop_constraint(
        op.f("ck_ai_settings_auto_execute_retired"),
        "ai_settings",
        type_="check",
    )
