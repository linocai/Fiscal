from datetime import datetime
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    UniqueConstraint,
    Uuid,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class MigrationRunMode(StrEnum):
    DRY_RUN = "dry_run"
    SHADOW = "shadow"
    PRODUCTION = "production"


class MigrationRunStatus(StrEnum):
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"


class MigrationRun(Base):
    __tablename__ = "migration_runs"
    __table_args__ = (
        CheckConstraint(
            "mode IN ('dry_run','shadow','production')",
            name="valid_mode",
        ),
        CheckConstraint(
            "status IN ('running','succeeded','failed')",
            name="valid_status",
        ),
        CheckConstraint(
            "char_length(source_system) BETWEEN 1 AND 64",
            name="source_system_length",
        ),
        CheckConstraint(
            "char_length(source_database_fingerprint) = 64",
            name="source_database_fingerprint_length",
        ),
        CheckConstraint(
            "char_length(source_manifest_hash) = 64",
            name="source_manifest_hash_length",
        ),
        CheckConstraint(
            "char_length(code_revision) BETWEEN 1 AND 64",
            name="code_revision_length",
        ),
        CheckConstraint(
            "(status='running' AND completed_at IS NULL) OR "
            "(status IN ('succeeded','failed') AND completed_at IS NOT NULL)",
            name="lifecycle_consistent",
        ),
        CheckConstraint(
            "completed_at IS NULL OR completed_at >= started_at",
            name="completion_not_before_start",
        ),
        Index("ix_migration_runs_status_started", "status", text("started_at DESC")),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    mode: Mapped[str] = mapped_column(String(16), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    source_system: Mapped[str] = mapped_column(String(64), nullable=False)
    source_database_fingerprint: Mapped[str] = mapped_column(String(64), nullable=False)
    source_manifest_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    source_manifest: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    selection_scope: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    code_revision: Mapped[str] = mapped_column(String(64), nullable=False)
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )

    object_links: Mapped[list["MigrationObjectLink"]] = relationship(
        "MigrationObjectLink",
        back_populates="migration_run",
        order_by="MigrationObjectLink.id",
    )


class MigrationObjectLink(Base):
    __tablename__ = "migration_object_links"
    __table_args__ = (
        CheckConstraint(
            "char_length(source_database_fingerprint) = 64",
            name="source_database_fingerprint_length",
        ),
        CheckConstraint(
            "char_length(source_object_type) BETWEEN 1 AND 64",
            name="source_object_type_length",
        ),
        CheckConstraint(
            "char_length(source_object_id) BETWEEN 1 AND 160",
            name="source_object_id_length",
        ),
        CheckConstraint(
            "char_length(source_content_hash) = 64",
            name="source_content_hash_length",
        ),
        CheckConstraint(
            "char_length(target_object_type) BETWEEN 1 AND 64",
            name="target_object_type_length",
        ),
        UniqueConstraint(
            "source_database_fingerprint",
            "source_object_type",
            "source_object_id",
            name="uq_migration_object_links_source_identity",
        ),
        UniqueConstraint(
            "target_object_type",
            "target_object_id",
            name="uq_migration_object_links_target_identity",
        ),
        Index("ix_migration_object_links_run_id", "migration_run_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    migration_run_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("migration_runs.id", ondelete="RESTRICT"),
        nullable=False,
    )
    source_database_fingerprint: Mapped[str] = mapped_column(String(64), nullable=False)
    source_object_type: Mapped[str] = mapped_column(String(64), nullable=False)
    source_object_id: Mapped[str] = mapped_column(String(160), nullable=False)
    source_content_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    target_object_type: Mapped[str] = mapped_column(String(64), nullable=False)
    target_object_id: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )

    migration_run: Mapped[MigrationRun] = relationship(
        "MigrationRun", back_populates="object_links"
    )
