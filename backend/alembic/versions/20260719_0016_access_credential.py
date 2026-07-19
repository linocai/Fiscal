"""Personal access passphrase credential and access keys.

Introduces the single-row ``access_credential`` (PBKDF2 slow-hash of the
personal passphrase) and ``access_keys`` (opaque bearer digests tagged with the
credential generation). The legacy ``device_tokens`` table is intentionally left
in place for the transition and a later cleanup release.

Revision ID: 20260719_0016
Revises: 20260718_0015
Create Date: 2026-07-19
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260719_0016"
down_revision: str | None = "20260718_0015"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "access_credential",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("passphrase_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column("passphrase_salt", sa.LargeBinary(length=16), nullable=False),
        sa.Column("kdf_iterations", sa.Integer(), nullable=False),
        sa.Column("credential_generation", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_rotated_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("credential_generation >= 1", name="credential_generation_positive"),
        sa.CheckConstraint("kdf_iterations >= 100000", name="kdf_iterations_minimum"),
        sa.CheckConstraint("octet_length(passphrase_salt) = 16", name="passphrase_salt_length"),
        sa.CheckConstraint("octet_length(passphrase_hash) = 32", name="passphrase_hash_length"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "access_keys",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("key_digest", sa.LargeBinary(length=32), nullable=False),
        sa.Column("key_fingerprint", sa.String(length=12), nullable=False),
        sa.Column("credential_generation", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("label", sa.String(length=80), nullable=True),
        sa.CheckConstraint("octet_length(key_digest) = 32", name="key_digest_length"),
        sa.CheckConstraint("char_length(key_fingerprint) = 12", name="key_fingerprint_length"),
        sa.CheckConstraint("credential_generation >= 1", name="access_key_generation_positive"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("uq_access_keys_digest", "access_keys", ["key_digest"], unique=True)
    op.create_index("ix_access_keys_generation", "access_keys", ["credential_generation"])


def downgrade() -> None:
    op.drop_index("ix_access_keys_generation", table_name="access_keys")
    op.drop_index("uq_access_keys_digest", table_name="access_keys")
    op.drop_table("access_keys")
    op.drop_table("access_credential")
