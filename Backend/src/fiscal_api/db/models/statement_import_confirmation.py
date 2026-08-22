from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import (
    CheckConstraint,
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


class StatementImportConfirmationOperation(Base):
    __tablename__ = "statement_import_confirmation_operations"
    __table_args__ = (
        CheckConstraint("char_length(payload_hash) = 64", name="payload_hash_length"),
        UniqueConstraint("idempotency_key", name="uq_statement_import_confirmation_idempotency"),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    statement_import_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_imports.id", ondelete="RESTRICT"), nullable=False
    )
    idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    payload_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    receipt: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class StatementImportTransactionProvenance(Base):
    __tablename__ = "statement_import_transaction_provenance"
    __table_args__ = (
        UniqueConstraint("statement_import_row_id", name="uq_statement_import_provenance_row"),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    statement_import_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_imports.id", ondelete="RESTRICT"), nullable=False
    )
    statement_import_row_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_import_rows.id", ondelete="RESTRICT"), nullable=False
    )
    confirmation_operation_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("statement_import_confirmation_operations.id", ondelete="RESTRICT"),
        nullable=False,
    )
    transaction_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=False
    )
    resolution: Mapped[str] = mapped_column(String(32), nullable=False)
    draft_version: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class StatementImportFinalCreateDraft(Base):
    __tablename__ = "statement_import_final_create_drafts"
    __table_args__ = (
        CheckConstraint("version >= 1", name="version_positive"),
        UniqueConstraint(
            "statement_import_row_id", name="uq_statement_import_final_create_draft_row"
        ),
    )
    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    statement_import_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_imports.id", ondelete="RESTRICT"), nullable=False
    )
    statement_import_row_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("statement_import_rows.id", ondelete="RESTRICT"), nullable=False
    )
    draft_resolution_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("statement_import_draft_resolutions.id", ondelete="RESTRICT"),
        nullable=False,
    )
    payload: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
