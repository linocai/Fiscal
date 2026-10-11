from datetime import datetime
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    Index,
    Integer,
    String,
    UniqueConstraint,
    Uuid,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class ImportBatchSource(StrEnum):
    TEXT = "text"
    STRUCTURED = "structured"
    OCR = "ocr"
    SHORTCUT_TEXT = "shortcut_text"


class ImportBatchStatus(StrEnum):
    PENDING = "pending"
    VALIDATED = "validated"
    IGNORED = "ignored"
    COMMITTED = "committed"
    FAILED = "failed"


class ImportBatch(Base):
    """Durable envelope for an Agent supplied, explicitly confirmed ledger batch.

    Candidate rows stay in JSONB because the MCP contract is intentionally versioned
    independently from the backend.  Posted transaction ids and validation errors are
    retained as an audit receipt; the ledger remains the source of truth for postings.
    """

    __tablename__ = "import_batches"
    __table_args__ = (
        CheckConstraint(
            "source IN ('text','structured','ocr','shortcut_text')",
            name="valid_source",
        ),
        CheckConstraint(
            "status IN ('pending','validated','ignored','committed','failed')",
            name="valid_status",
        ),
        CheckConstraint("char_length(original_content_sha256) = 64", name="fingerprint_length"),
        CheckConstraint("char_length(request_hash) = 64", name="request_hash_length"),
        CheckConstraint("version >= 1", name="version_positive"),
        UniqueConstraint("idempotency_key", name="uq_import_batches_idempotency_key"),
        Index("ix_import_batches_timeline", text("created_at DESC"), text("id DESC")),
        Index("ix_import_batches_status_timeline", "status", text("created_at DESC")),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    source: Mapped[str] = mapped_column(String(16), nullable=False)
    original_content_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    candidates: Mapped[list[dict[str, object]]] = mapped_column(JSONB, nullable=False)
    validation_errors: Mapped[list[dict[str, object]]] = mapped_column(
        JSONB, nullable=False, default=list
    )
    transaction_receipts: Mapped[list[dict[str, object]]] = mapped_column(
        JSONB, nullable=False, default=list
    )
    ignored_reason: Mapped[str | None] = mapped_column(String(240), nullable=True)
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default=ImportBatchStatus.PENDING
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
    validated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    committed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    ignored_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
