"""P29 reviewer privacy hardening for statement import filenames.

Revision ID: 20260813_0029
Revises: 20260812_0028
"""

from collections.abc import Sequence

from alembic import op

revision: str = "20260813_0029"
down_revision: str | None = "20260812_0028"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # P24 originally accepted a filename-shaped value.  Rewrite it before the constraint so
    # upgraded databases and subsequent Archives cannot retain historical personal filenames.
    op.execute("UPDATE statement_imports SET display_name = 'statement.pdf'")
    op.create_check_constraint(
        "display_name_fixed", "statement_imports", "display_name = 'statement.pdf'"
    )


def downgrade() -> None:
    op.drop_constraint("display_name_fixed", "statement_imports", type_="check")
