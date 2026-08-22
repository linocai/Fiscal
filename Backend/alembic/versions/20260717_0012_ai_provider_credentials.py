"""Add encrypted in-app AI provider configuration.

Revision ID: 20260717_0012
Revises: 20260716_0011
Create Date: 2026-07-17
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260717_0012"
down_revision: str | None = "20260716_0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("ai_settings", sa.Column("provider_kind", sa.String(32), nullable=True))
    op.add_column("ai_settings", sa.Column("provider_base_url", sa.String(500), nullable=True))
    op.add_column("ai_settings", sa.Column("provider_model", sa.String(200), nullable=True))
    op.add_column("ai_settings", sa.Column("provider_api_key_ciphertext", sa.Text(), nullable=True))
    op.add_column("ai_settings", sa.Column("provider_key_version", sa.Integer(), nullable=True))
    op.create_check_constraint(
        "provider_configuration_complete",
        "ai_settings",
        "(provider_kind IS NULL AND provider_base_url IS NULL AND provider_model IS NULL "
        "AND provider_api_key_ciphertext IS NULL AND provider_key_version IS NULL) OR "
        "(provider_kind='openai_compatible' AND provider_base_url IS NOT NULL "
        "AND provider_model IS NOT NULL AND provider_api_key_ciphertext IS NOT NULL "
        "AND provider_key_version >= 1)",
    )


def downgrade() -> None:
    op.drop_constraint(
        op.f("ck_ai_settings_provider_configuration_complete"),
        "ai_settings",
        type_="check",
    )
    op.drop_column("ai_settings", "provider_key_version")
    op.drop_column("ai_settings", "provider_api_key_ciphertext")
    op.drop_column("ai_settings", "provider_model")
    op.drop_column("ai_settings", "provider_base_url")
    op.drop_column("ai_settings", "provider_kind")
