"""P20 finalizes personal access-key authentication.

The historic device-token bridge is deliberately irrecoverable: a populated
production table proves that an older binary could still authenticate. P20 has
already established a passphrase credential and current access keys on both
physical clients, so dropping it is the only safe final state. Downgrade is
therefore guarded rather than recreating an authentication channel.

Revision ID: 20260811_0020
Revises: 20260811_0019
Create Date: 2026-08-11
"""

from collections.abc import Sequence

from alembic import op

revision: str = "20260811_0020"
down_revision: str | None = "20260811_0019"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute(
        "DO $$ BEGIN "
        "IF EXISTS(SELECT 1 FROM device_tokens) "
        "AND (SELECT count(*) FROM access_credential) <> 1 THEN "
        "RAISE EXCEPTION 'P20 authentication cleanup requires exactly one access credential' "
        "USING ERRCODE='object_not_in_prerequisite_state'; "
        "END IF; END $$"
    )
    op.drop_table("device_tokens")


def downgrade() -> None:
    op.execute(
        "DO $$ BEGIN RAISE EXCEPTION "
        "'P20 downgrade blocked: device-token authentication is permanently removed' "
        "USING ERRCODE='object_not_in_prerequisite_state'; END $$"
    )
