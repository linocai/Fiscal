from __future__ import annotations

from datetime import date, datetime
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    String,
    Text,
    UniqueConstraint,
    Uuid,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class StatementImportStatus(StrEnum):
    CREATED = "created"
    EXTRACTING = "extracting"
    PARSING = "parsing"
    REVIEW_REQUIRED = "review_required"
    READY_TO_CONFIRM = "ready_to_confirm"
    PARTIALLY_CONFIRMED = "partially_confirmed"
    CONFIRMED = "confirmed"
    FAILED = "failed"
    ABANDONED = "abandoned"


class StatementImportAttemptKind(StrEnum):
    LOCAL_EXTRACTION = "local_extraction"
    PROVIDER_PARSE = "provider_parse"


class StatementImportAttemptStatus(StrEnum):
    STARTED = "started"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    ABANDONED = "abandoned"


class StatementImportResolutionKind(StrEnum):
    UNRESOLVED = "unresolved"
    CREATE_NEW = "create_new"
    MATCH_EXISTING = "match_existing"
    IGNORE_NON_TRANSACTION = "ignore_non_transaction"
    IGNORE_INTENTIONAL = "ignore_intentional"


class StatementImport(Base):
    """A PDF identity and its review-only lifecycle; never a ledger write path."""

    __tablename__ = "statement_imports"
    __table_args__ = (
        CheckConstraint("char_length(document_sha256) = 64", name="document_sha256_length"),
        CheckConstraint("byte_size > 0", name="byte_size_positive"),
        CheckConstraint("page_count > 0", name="page_count_positive"),
        CheckConstraint("currency = 'CNY'", name="currency_cny"),
        CheckConstraint("version >= 1", name="version_positive"),
        CheckConstraint(
            "status IN ('created','extracting','parsing','review_required','ready_to_confirm',"
            "'partially_confirmed','confirmed','failed','abandoned')",
            name="valid_status",
        ),
        CheckConstraint(
            "(status = 'confirmed') = (confirmed_at IS NOT NULL)", name="confirmed_timestamp"
        ),
        CheckConstraint(
            "(status = 'abandoned') = (abandoned_at IS NOT NULL)", name="abandoned_timestamp"
        ),
        UniqueConstraint("document_sha256", name="uq_statement_imports_document_sha256"),
        Index("ix_statement_imports_status_updated", "status", text("updated_at DESC")),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    document_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    byte_size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    page_count: Mapped[int] = mapped_column(Integer, nullable=False)
    mime_type: Mapped[str] = mapped_column(String(100), nullable=False)
    display_name: Mapped[str] = mapped_column(String(255), nullable=False)
    institution_name_raw: Mapped[str | None] = mapped_column(String(200), nullable=True)
    account_hint_masked: Mapped[str | None] = mapped_column(String(80), nullable=True)
    statement_period_start: Mapped[date | None] = mapped_column(Date, nullable=True)
    statement_period_end: Mapped[date | None] = mapped_column(Date, nullable=True)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="CNY")
    status: Mapped[str] = mapped_column(String(24), nullable=False, default="created")
    latest_attempt_id: Mapped[UUID | None] = mapped_column(
        Uuid,
        ForeignKey(
            "statement_import_attempts.id",
            name="fk_statement_imports_latest_attempt",
            ondelete="SET NULL",
            use_alter=True,
            deferrable=True,
            initially="DEFERRED",
        ),
        nullable=True,
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    confirmed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    abandoned_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )

    pages: Mapped[list[StatementImportPage]] = relationship(
        "StatementImportPage", back_populates="statement_import", cascade="all, delete-orphan"
    )
    rows: Mapped[list[StatementImportRow]] = relationship(
        "StatementImportRow", back_populates="statement_import", cascade="all, delete-orphan"
    )
    attempts: Mapped[list[StatementImportAttempt]] = relationship(
        "StatementImportAttempt",
        back_populates="statement_import",
        foreign_keys="StatementImportAttempt.statement_import_id",
        cascade="all, delete-orphan",
    )
    operations: Mapped[list[StatementImportOperation]] = relationship(
        "StatementImportOperation", back_populates="statement_import", cascade="all, delete-orphan"
    )


class StatementImportPage(Base):
    __tablename__ = "statement_import_pages"
    __table_args__ = (
        CheckConstraint("page_number > 0", name="page_number_positive"),
        CheckConstraint(
            "source_kind IS NULL OR source_kind IN ('text','scanned_image','mixed','unsupported')",
            name="valid_source_kind",
        ),
        CheckConstraint(
            "evidence_text_masked IS NULL OR char_length(evidence_text_masked) <= 20000",
            name="evidence_text_length",
        ),
        UniqueConstraint(
            "statement_import_id", "page_number", name="uq_statement_import_pages_number"
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    statement_import_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_imports.id", ondelete="RESTRICT"), nullable=False
    )
    page_number: Mapped[int] = mapped_column(Integer, nullable=False)
    source_kind: Mapped[str | None] = mapped_column(String(20), nullable=True)
    evidence_text_masked: Mapped[str | None] = mapped_column(Text, nullable=True)
    bounding_boxes: Mapped[list[dict[str, object]] | None] = mapped_column(JSONB, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )

    statement_import: Mapped[StatementImport] = relationship(
        "StatementImport", back_populates="pages"
    )


class StatementImportRow(Base):
    __tablename__ = "statement_import_rows"
    __table_args__ = (
        CheckConstraint("row_number > 0", name="row_number_positive"),
        CheckConstraint("amount_minor IS NULL OR amount_minor > 0", name="amount_positive"),
        CheckConstraint("currency IS NULL OR currency = 'CNY'", name="currency_cny"),
        CheckConstraint("version >= 1", name="version_positive"),
        UniqueConstraint(
            "statement_import_id", "row_number", name="uq_statement_import_rows_number"
        ),
        Index("ix_statement_import_rows_import_page", "statement_import_id", "page_number"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    statement_import_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_imports.id", ondelete="RESTRICT"), nullable=False
    )
    row_number: Mapped[int] = mapped_column(Integer, nullable=False)
    page_number: Mapped[int | None] = mapped_column(Integer, nullable=True)
    evidence_text_masked: Mapped[str | None] = mapped_column(Text, nullable=True)
    bounding_box: Mapped[dict[str, object] | None] = mapped_column(JSONB, nullable=True)
    raw_transaction_date: Mapped[str | None] = mapped_column(String(64), nullable=True)
    raw_posted_date: Mapped[str | None] = mapped_column(String(64), nullable=True)
    raw_summary_masked: Mapped[str | None] = mapped_column(Text, nullable=True)
    raw_amount: Mapped[str | None] = mapped_column(String(80), nullable=True)
    raw_direction: Mapped[str | None] = mapped_column(String(32), nullable=True)
    amount_minor: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    currency: Mapped[str | None] = mapped_column(String(3), nullable=True)
    transaction_kind_candidate: Mapped[str | None] = mapped_column(String(32), nullable=True)
    account_id_candidate: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=True
    )
    category_id_candidate: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("categories.id", ondelete="RESTRICT"), nullable=True
    )
    credit_cycle_id_candidate: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("credit_cycles.id", ondelete="RESTRICT"), nullable=True
    )
    initial_parse_snapshot: Mapped[dict[str, object] | None] = mapped_column(JSONB, nullable=True)
    final_value_snapshot: Mapped[dict[str, object] | None] = mapped_column(JSONB, nullable=True)
    field_diff: Mapped[dict[str, object] | None] = mapped_column(JSONB, nullable=True)
    validation_warnings: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    duplicate_candidates: Mapped[list[dict[str, object]]] = mapped_column(
        JSONB, nullable=False, default=list
    )
    transaction_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=True
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    confirmed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    confirmation_operation_id: Mapped[UUID | None] = mapped_column(Uuid, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )

    statement_import: Mapped[StatementImport] = relationship(
        "StatementImport", back_populates="rows"
    )
    resolution: Mapped[StatementImportResolution | None] = relationship(
        "StatementImportResolution",
        back_populates="row",
        uselist=False,
        cascade="all, delete-orphan",
    )


class StatementImportAttempt(Base):
    __tablename__ = "statement_import_attempts"
    __table_args__ = (
        CheckConstraint("attempt_number > 0", name="attempt_number_positive"),
        CheckConstraint("version >= 1", name="version_positive"),
        CheckConstraint("kind IN ('local_extraction','provider_parse')", name="valid_kind"),
        CheckConstraint(
            "status IN ('started','succeeded','failed','abandoned')", name="valid_status"
        ),
        CheckConstraint(
            "(status IN ('succeeded','failed','abandoned')) = (completed_at IS NOT NULL)",
            name="terminal_timestamp",
        ),
        CheckConstraint(
            "error_code IS NULL OR char_length(error_code) BETWEEN 1 AND 64",
            name="error_code_length",
        ),
        UniqueConstraint(
            "statement_import_id", "attempt_number", name="uq_statement_import_attempts_number"
        ),
        Index("ix_statement_import_attempts_import_created", "statement_import_id", "created_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    statement_import_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_imports.id", ondelete="RESTRICT"), nullable=False
    )
    attempt_number: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    kind: Mapped[str] = mapped_column(String(24), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="started")
    provider: Mapped[str | None] = mapped_column(String(40), nullable=True)
    provider_model: Mapped[str | None] = mapped_column(String(200), nullable=True)
    prompt_version: Mapped[str | None] = mapped_column(String(80), nullable=True)
    schema_version: Mapped[str | None] = mapped_column(String(80), nullable=True)
    authorized_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    error_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    error_summary: Mapped[str | None] = mapped_column(String(200), nullable=True)
    duration_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    input_page_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    input_token_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    output_token_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    evidence_sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )

    statement_import: Mapped[StatementImport] = relationship(
        "StatementImport", back_populates="attempts", foreign_keys=[statement_import_id]
    )


class StatementImportResolution(Base):
    __tablename__ = "statement_import_resolutions"
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
        UniqueConstraint("statement_import_row_id", name="uq_statement_import_resolutions_row"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    statement_import_row_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_import_rows.id", ondelete="RESTRICT"), nullable=False
    )
    resolution: Mapped[str] = mapped_column(String(32), nullable=False, default="unresolved")
    matched_transaction_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=True
    )
    ignored_reason: Mapped[str | None] = mapped_column(String(160), nullable=True)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    confirmation_operation_id: Mapped[UUID | None] = mapped_column(Uuid, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )

    row: Mapped[StatementImportRow] = relationship(
        "StatementImportRow", back_populates="resolution"
    )


class StatementImportOperation(Base):
    """Append-only, deliberately metadata-only audit trail for import actions."""

    __tablename__ = "statement_import_operations"
    __table_args__ = (
        CheckConstraint(
            "operation IN ('registered','attempt_started','evidence_received',"
            "'provider_attempt_started','provider_attempt_succeeded','provider_attempt_failed',"
            "'attempt_failed','abandoned')",
            name="valid_operation",
        ),
        CheckConstraint("char_length(error_code) BETWEEN 1 AND 64", name="error_code_length"),
        Index(
            "ix_statement_import_operations_import_occurred", "statement_import_id", "occurred_at"
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    statement_import_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_imports.id", ondelete="RESTRICT"), nullable=False
    )
    attempt_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("statement_import_attempts.id", ondelete="RESTRICT"), nullable=True
    )
    operation: Mapped[str] = mapped_column(String(32), nullable=False)
    error_code: Mapped[str] = mapped_column(String(64), nullable=False)
    details: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False, default=dict)
    occurred_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )

    statement_import: Mapped[StatementImport] = relationship(
        "StatementImport", back_populates="operations"
    )


class StatementImportProviderAttempt(Base):
    """P26's provider-only metadata; never a credential or upstream raw body."""

    __tablename__ = "statement_import_provider_attempts"
    __table_args__ = (
        CheckConstraint("char_length(evidence_sha256) = 64", name="evidence_sha256_length"),
        CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        UniqueConstraint(
            "statement_import_attempt_id", name="uq_statement_provider_attempt_source"
        ),
        UniqueConstraint("idempotency_key", name="uq_statement_provider_attempt_idempotency"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    statement_import_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_imports.id", ondelete="RESTRICT"), nullable=False
    )
    statement_import_attempt_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_import_attempts.id", ondelete="RESTRICT"), nullable=False
    )
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    evidence_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    provider: Mapped[str] = mapped_column(String(40), nullable=False)
    provider_model: Mapped[str] = mapped_column(String(200), nullable=False)
    prompt_version: Mapped[str] = mapped_column(String(80), nullable=False)
    schema_version: Mapped[str] = mapped_column(String(80), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )

    snapshots: Mapped[list[StatementImportProviderAttemptSnapshot]] = relationship(
        "StatementImportProviderAttemptSnapshot",
        back_populates="provider_attempt",
        cascade="all, delete-orphan",
    )


class StatementImportProviderAttemptSnapshot(Base):
    """Append-only authorization, outbound, and validated-result snapshots."""

    __tablename__ = "statement_import_provider_attempt_snapshots"
    __table_args__ = (
        CheckConstraint(
            "snapshot_kind IN ('authorization','outbound_request','validated_result')",
            name="valid_snapshot_kind",
        ),
        UniqueConstraint(
            "provider_attempt_id", "snapshot_kind", name="uq_provider_attempt_snapshot_kind"
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    provider_attempt_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("statement_import_provider_attempts.id", ondelete="RESTRICT"),
        nullable=False,
    )
    snapshot_kind: Mapped[str] = mapped_column(String(24), nullable=False)
    payload: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )

    provider_attempt: Mapped[StatementImportProviderAttempt] = relationship(
        "StatementImportProviderAttempt", back_populates="snapshots"
    )
    source_refs: Mapped[list[StatementImportProviderSnapshotSourceRef]] = relationship(
        "StatementImportProviderSnapshotSourceRef",
        back_populates="snapshot",
        cascade="all, delete-orphan",
    )


class StatementImportProviderSnapshotSourceRef(Base):
    __tablename__ = "statement_import_provider_snapshot_source_refs"
    __table_args__ = (
        CheckConstraint("candidate_index >= 0", name="candidate_index_nonnegative"),
        UniqueConstraint(
            "provider_attempt_snapshot_id",
            "candidate_index",
            "statement_import_row_id",
            name="uq_provider_snapshot_source_ref",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    provider_attempt_snapshot_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("statement_import_provider_attempt_snapshots.id", ondelete="RESTRICT"),
        nullable=False,
    )
    statement_import_row_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_import_rows.id", ondelete="RESTRICT"), nullable=False
    )
    candidate_index: Mapped[int] = mapped_column(Integer, nullable=False)
    snapshot: Mapped[StatementImportProviderAttemptSnapshot] = relationship(
        "StatementImportProviderAttemptSnapshot", back_populates="source_refs"
    )
