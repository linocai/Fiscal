"""P22 recoverable archive baseline and global data revision.

The singleton starts at zero: historic rows predate the formal P22 receipt
contract.  It is intentionally reversible because it is additive and no
archive import ever mutates an existing database.

Revision ID: 20260811_0022
Revises: 20260811_0021
Create Date: 2026-08-11
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260811_0022"
down_revision: str | None = "20260811_0021"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "data_revision",
        sa.Column("id", sa.SmallInteger(), nullable=False),
        sa.Column("revision", sa.BigInteger(), nullable=False, server_default="0"),
        sa.CheckConstraint("id = 1", name="singleton"),
        sa.CheckConstraint("revision >= 0", name="nonnegative"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.execute("INSERT INTO data_revision (id, revision) VALUES (1, 0)")


def downgrade() -> None:
    op.drop_table("data_revision")
