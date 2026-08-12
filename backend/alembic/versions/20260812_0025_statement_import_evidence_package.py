"""P24-B redacted local statement evidence package.

Revision ID: 20260812_0025
Revises: 20260812_0024
Create Date: 2026-08-12
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260812_0025"
down_revision: str | None = "20260812_0024"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "statement_import_attempts",
        sa.Column("evidence_sha256", sa.String(length=64), nullable=True),
    )
    op.drop_constraint("valid_operation", "statement_import_operations", type_="check")
    op.create_check_constraint(
        "valid_operation",
        "statement_import_operations",
        "operation IN ('registered','attempt_started','evidence_received','attempt_failed','abandoned')",
    )


def downgrade() -> None:
    op.drop_constraint("valid_operation", "statement_import_operations", type_="check")
    op.create_check_constraint(
        "valid_operation",
        "statement_import_operations",
        "operation IN ('registered','attempt_started','attempt_failed','abandoned')",
    )
    op.drop_column("statement_import_attempts", "evidence_sha256")
