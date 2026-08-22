from __future__ import annotations

from datetime import date, datetime
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class StatementImportValidationRun(Base):
    __tablename__ = "statement_import_validation_runs"
    __table_args__ = (
        CheckConstraint("char_length(evidence_sha256) = 64", name="evidence_sha256_length"),
        CheckConstraint(
            "char_length(algorithm_version) BETWEEN 1 AND 64", name="algorithm_version_length"
        ),
        UniqueConstraint(
            "provider_snapshot_id",
            "evidence_sha256",
            "algorithm_version",
            name="uq_statement_import_validation_run_input",
        ),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    statement_import_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_imports.id", ondelete="RESTRICT"), nullable=False
    )
    provider_snapshot_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("statement_import_provider_attempt_snapshots.id", ondelete="RESTRICT"),
        nullable=False,
    )
    evidence_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    algorithm_version: Mapped[str] = mapped_column(String(64), nullable=False)
    batch_version: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class StatementImportValidationCheck(Base):
    __tablename__ = "statement_import_validation_checks"
    __table_args__ = (
        CheckConstraint("status IN ('passed','failed','unavailable')", name="valid_status"),
        UniqueConstraint(
            "validation_run_id", "check_kind", name="uq_statement_import_validation_check"
        ),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    validation_run_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_import_validation_runs.id", ondelete="RESTRICT"), nullable=False
    )
    check_kind: Mapped[str] = mapped_column(String(40), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    evidence_row_ids: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class StatementImportReviewCandidate(Base):
    __tablename__ = "statement_import_review_candidates"
    __table_args__ = (
        CheckConstraint(
            "candidate_kind IN ('provider_candidate','existing_transaction')",
            name="valid_candidate_kind",
        ),
        UniqueConstraint(
            "validation_run_id",
            "statement_import_row_id",
            "candidate_kind",
            "provider_candidate_index",
            "transaction_id",
            name="uq_statement_import_review_candidate",
        ),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    validation_run_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_import_validation_runs.id", ondelete="RESTRICT"), nullable=False
    )
    statement_import_row_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_import_rows.id", ondelete="RESTRICT"), nullable=False
    )
    candidate_kind: Mapped[str] = mapped_column(String(32), nullable=False)
    provider_candidate_index: Mapped[int | None] = mapped_column(Integer, nullable=True)
    transaction_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=True
    )
    transaction_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    amount_minor: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class StatementImportDraftResolution(Base):
    __tablename__ = "statement_import_draft_resolutions"
    __table_args__ = (
        CheckConstraint(
            "resolution IN ('unresolved','create_new','match_existing',"
            "'ignore_non_transaction','ignore_intentional')",
            name="valid_resolution",
        ),
        CheckConstraint("version >= 1", name="version_positive"),
        CheckConstraint(
            "(resolution = 'match_existing') = (matched_transaction_id IS NOT NULL)",
            name="match_target",
        ),
        CheckConstraint(
            "(resolution = 'ignore_intentional') = (ignored_reason IS NOT NULL)",
            name="ignore_reason",
        ),
        UniqueConstraint(
            "validation_run_id",
            "statement_import_row_id",
            name="uq_statement_import_draft_resolution",
        ),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    validation_run_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_import_validation_runs.id", ondelete="RESTRICT"), nullable=False
    )
    statement_import_row_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_import_rows.id", ondelete="RESTRICT"), nullable=False
    )
    resolution: Mapped[str] = mapped_column(String(32), nullable=False)
    matched_transaction_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=True
    )
    ignored_reason: Mapped[str | None] = mapped_column(String(160), nullable=True)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
