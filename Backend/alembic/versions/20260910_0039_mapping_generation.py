"""Persist mapping generations across release and recreation.

Revision ID: 20260910_0039
Revises: 20260831_0038
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260910_0039"
down_revision: str | None = "20260831_0038"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "transactions",
        sa.Column("merchant_mapping_generation", sa.Integer(), nullable=False, server_default="0"),
    )
    op.create_check_constraint(
        "mapping_generation_nonnegative", "transactions", "merchant_mapping_generation >= 0"
    )
    # Advance past every legacy receipt, including receipts from deleted mappings.
    # Existing mappings also advance: a legacy ABA may already have reused their version.
    op.execute("""
        WITH versions AS (
            SELECT transaction_id::text AS transaction_id, version::bigint AS version
            FROM transaction_merchant_mappings
            UNION ALL
            SELECT receipt->'mapping'->>'transaction_id',
                   (receipt->'mapping'->>'mapping_version')::bigint
            FROM merchant_operations
            WHERE jsonb_typeof(receipt->'mapping') = 'object'
              AND (receipt->'mapping'->>'mapping_version') ~ '^[0-9]+$'
        ), maxima AS (
            SELECT transaction_id, max(version) AS version FROM versions GROUP BY transaction_id
        )
        UPDATE transactions t SET merchant_mapping_generation = maxima.version + 1
        FROM maxima WHERE t.id::text = maxima.transaction_id
    """)
    op.execute("""
        UPDATE transaction_merchant_mappings m SET version = t.merchant_mapping_generation
        FROM transactions t WHERE m.transaction_id = t.id
    """)


def downgrade() -> None:
    raise RuntimeError("0039 preserves mapping history; restore a verified backup instead")
