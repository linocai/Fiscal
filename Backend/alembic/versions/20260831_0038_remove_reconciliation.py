"""Remove retired balance reconciliation evidence.

Revision ID: 20260831_0038
Revises: 20260830_0037

This is intentionally a one-way product-data removal.  Restoring the old
feature requires the verified pre-migration backup procedure, not an Alembic
downgrade that could recreate stale financial evidence.
"""

from collections.abc import Sequence

from alembic import op

revision: str = "20260831_0038"
down_revision: str | None = "20260830_0037"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_table("attention_dismissals")
    op.drop_index(
        "ix_reconciliation_checkpoints_target_time", table_name="reconciliation_checkpoints"
    )
    op.drop_table("reconciliation_checkpoints")


def downgrade() -> None:
    raise RuntimeError(
        "0038 is intentionally irreversible; restore a verified pre-0038 backup instead"
    )
