from datetime import datetime
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
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
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.core.time import utc_now
from fiscal_api.db.base import Base


class AIProposalSource(StrEnum):
    TEXT = "text"
    OCR = "ocr"
    SHORTCUT_TEXT = "shortcut_text"


class AIProposalStatus(StrEnum):
    PROCESSING = "processing"
    PENDING = "pending"
    EXECUTED = "executed"
    FAILED = "failed"
    IGNORED = "ignored"
    UNDONE = "undone"


class AIProposalTarget(StrEnum):
    TRANSACTION = "transaction"
    CASH_FLOW = "cash_flow"


class AIQualityEventType(StrEnum):
    PARSED = "parsed"
    CONFIRM_UNCHANGED = "confirm_unchanged"
    CONFIRM_EDITED = "confirm_edited"
    IGNORED = "ignored"
    EXECUTE_FAILED = "execute_failed"
    AUTOMATIC_EXECUTE = "automatic_execute"
    MANUAL_EXECUTE = "manual_execute"
    UNDONE = "undone"
    PROVIDER_RETRY = "provider_retry"
    FINAL_FAILURE = "final_failure"


class AILearningRuleKind(StrEnum):
    MERCHANT_CATEGORY = "merchant_category"
    TITLE_ACCOUNT = "title_account"
    CATEGORY_ALIAS = "category_alias"


class AISettings(Base):
    __tablename__ = "ai_settings"
    __table_args__ = (
        CheckConstraint("id = 1", name="singleton"),
        CheckConstraint("auto_execute_limit_minor BETWEEN 1 AND 100000", name="auto_limit_range"),
        CheckConstraint("minimum_confidence_bps BETWEEN 9000 AND 10000", name="confidence_range"),
        CheckConstraint("version >= 1", name="version_positive"),
    )

    id: Mapped[int] = mapped_column(SmallInteger, primary_key=True, default=1)
    auto_execute_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    ocr_source_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    shortcut_text_source_enabled: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False
    )
    auto_execute_limit_minor: Mapped[int] = mapped_column(
        BigInteger, nullable=False, default=100_000
    )
    minimum_confidence_bps: Mapped[int] = mapped_column(Integer, nullable=False, default=9_000)
    provider_kind: Mapped[str | None] = mapped_column(String(32), nullable=True)
    provider_base_url: Mapped[str | None] = mapped_column(String(500), nullable=True)
    provider_model: Mapped[str | None] = mapped_column(String(200), nullable=True)
    prompt_version: Mapped[str] = mapped_column(String(80), nullable=False, default="p23-v1")
    provider_api_key_ciphertext: Mapped[str | None] = mapped_column(Text, nullable=True)
    provider_key_version: Mapped[int | None] = mapped_column(Integer, nullable=True)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )


class AIProposal(Base):
    __tablename__ = "ai_proposals"
    __table_args__ = (
        CheckConstraint("source IN ('text','ocr','shortcut_text')", name="valid_source"),
        CheckConstraint(
            "status IN ('processing','pending','executed','failed','ignored','undone')",
            name="valid_status",
        ),
        CheckConstraint(
            "kind IS NULL OR kind IN ('income','expense','transfer','credit_purchase','repayment')",
            name="valid_kind",
        ),
        CheckConstraint("char_length(raw_input) BETWEEN 1 AND 2000", name="raw_input_length"),
        CheckConstraint("char_length(content_fingerprint) = 64", name="fingerprint_length"),
        CheckConstraint("char_length(create_request_hash) = 64", name="request_hash_length"),
        CheckConstraint("amount_minor IS NULL OR amount_minor > 0", name="amount_positive"),
        CheckConstraint("currency IS NULL OR currency = 'CNY'", name="valid_currency"),
        CheckConstraint(
            "overall_confidence_bps IS NULL OR overall_confidence_bps BETWEEN 0 AND 10000",
            name="confidence_range",
        ),
        CheckConstraint("version >= 1", name="version_positive"),
        CheckConstraint(
            "transaction_version IS NULL OR transaction_version >= 1",
            name="transaction_version_positive",
        ),
        CheckConstraint("target IN ('transaction','cash_flow')", name="valid_target"),
        CheckConstraint(
            "(status IN ('executed','undone') AND "
            "((transaction_id IS NOT NULL)::int + (cash_flow_item_id IS NOT NULL)::int) = 1) "
            "OR (status NOT IN ('executed','undone') AND transaction_id IS NULL "
            "AND cash_flow_item_id IS NULL)",
            name="execution_state",
        ),
        CheckConstraint(
            "((transaction_id IS NULL AND transaction_version IS NULL) OR "
            "(transaction_id IS NOT NULL AND transaction_version IS NOT NULL))",
            name="transaction_version_state",
        ),
        CheckConstraint(
            "((cash_flow_item_id IS NULL AND cash_flow_item_version IS NULL) OR "
            "(cash_flow_item_id IS NOT NULL AND cash_flow_item_version IS NOT NULL))",
            name="cash_flow_version_state",
        ),
        UniqueConstraint("create_idempotency_key", name="uq_ai_proposals_create_idempotency_key"),
        UniqueConstraint("transaction_id", name="uq_ai_proposals_transaction_id"),
        UniqueConstraint("cash_flow_item_id", name="uq_ai_proposals_cash_flow_item_id"),
        Index("ix_ai_proposals_fingerprint", "content_fingerprint"),
        Index(
            "ix_ai_proposals_pending_timeline",
            text("created_at DESC"),
            text("id DESC"),
            postgresql_where=text("status = 'pending'"),
        ),
        Index("ix_ai_proposals_timeline", text("created_at DESC"), text("id DESC")),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    source: Mapped[str] = mapped_column(String(16), nullable=False)
    raw_input: Mapped[str] = mapped_column(Text, nullable=False)
    content_fingerprint: Mapped[str] = mapped_column(String(64), nullable=False)
    create_idempotency_key: Mapped[UUID] = mapped_column(Uuid, nullable=False)
    create_request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    provider: Mapped[str | None] = mapped_column(String(40), nullable=True)
    provider_model: Mapped[str | None] = mapped_column(String(120), nullable=True)
    prompt_version: Mapped[str | None] = mapped_column(String(80), nullable=True)
    target: Mapped[str] = mapped_column(String(16), nullable=False, default="transaction")

    kind: Mapped[str | None] = mapped_column(String(32), nullable=True)
    amount_minor: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    currency: Mapped[str | None] = mapped_column(String(3), nullable=True)
    occurred_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    title: Mapped[str | None] = mapped_column(String(120), nullable=True)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    account_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=True
    )
    category_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("categories.id", ondelete="RESTRICT"), nullable=True
    )
    destination_account_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=True
    )
    credit_cycle_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("credit_cycles.id", ondelete="RESTRICT"), nullable=True
    )

    field_confidences: Mapped[dict[str, int]] = mapped_column(JSONB, nullable=False, default=dict)
    overall_confidence_bps: Mapped[int | None] = mapped_column(Integer, nullable=True)
    missing_fields: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    reason_codes: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    explanation: Mapped[str | None] = mapped_column(String(500), nullable=True)
    error_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    error_message: Mapped[str | None] = mapped_column(String(200), nullable=True)

    # P23 snapshots are additive.  Rows created before this contract intentionally keep
    # these values NULL and are surfaced as historical_unavailable rather than invented.
    initial_parse_snapshot: Mapped[dict[str, object] | None] = mapped_column(JSONB, nullable=True)
    final_confirmed_snapshot: Mapped[dict[str, object] | None] = mapped_column(JSONB, nullable=True)
    final_field_diff: Mapped[dict[str, object] | None] = mapped_column(JSONB, nullable=True)

    status: Mapped[str] = mapped_column(String(16), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    transaction_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("transactions.id", ondelete="RESTRICT"), nullable=True
    )
    transaction_version: Mapped[int | None] = mapped_column(Integer, nullable=True)
    cash_flow_item_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("cash_flow_items.id", ondelete="RESTRICT"), nullable=True
    )
    cash_flow_item_version: Mapped[int | None] = mapped_column(Integer, nullable=True)
    parsed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    executed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    ignored_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    undone_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )


class AIQualityEvent(Base):
    __tablename__ = "ai_quality_events"
    __table_args__ = (
        CheckConstraint(
            "event_type IN ('parsed','confirm_unchanged','confirm_edited','ignored',"
            "'execute_failed','automatic_execute','manual_execute','undone',"
            "'provider_retry','final_failure')",
            name="valid_event_type",
        ),
        Index("ix_ai_quality_events_proposal_occurred", "proposal_id", "occurred_at"),
        Index("ix_ai_quality_events_type_occurred", "event_type", "occurred_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    proposal_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("ai_proposals.id", ondelete="RESTRICT"), nullable=False
    )
    event_type: Mapped[str] = mapped_column(String(32), nullable=False)
    reason: Mapped[str | None] = mapped_column(String(120), nullable=True)
    details: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False, default=dict)
    occurred_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class AIExecutionPolicy(Base):
    __tablename__ = "ai_execution_policies"
    __table_args__ = (
        CheckConstraint("version >= 1", name="version_positive"),
        CheckConstraint("minimum_confidence_bps BETWEEN 9000 AND 10000", name="confidence_range"),
        CheckConstraint("auto_execute_limit_minor BETWEEN 1 AND 100000", name="limit_range"),
        CheckConstraint("minimum_sample_size >= 1", name="sample_size_positive"),
        Index("ix_ai_execution_policies_effective", "effective_at", "version"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    effective_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    source: Mapped[str | None] = mapped_column(String(16), nullable=True)
    transaction_kind: Mapped[str | None] = mapped_column(String(32), nullable=True)
    auto_execute_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    auto_execute_limit_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    minimum_confidence_bps: Mapped[int] = mapped_column(Integer, nullable=False)
    minimum_sample_size: Mapped[int] = mapped_column(Integer, nullable=False, default=30)
    change_reason: Mapped[str] = mapped_column(String(120), nullable=False)
    changed_automatically: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )


class AILearningRule(Base):
    __tablename__ = "ai_learning_rules"
    __table_args__ = (
        CheckConstraint(
            "rule_kind IN ('merchant_category','title_account','category_alias')",
            name="valid_rule_kind",
        ),
        CheckConstraint("evidence_count >= 2", name="minimum_evidence"),
        UniqueConstraint("rule_kind", "normalized_key", "source", name="uq_ai_learning_rule_key"),
        Index("ix_ai_learning_rules_active", "enabled", "rule_kind"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    rule_kind: Mapped[str] = mapped_column(String(32), nullable=False)
    normalized_key: Mapped[str] = mapped_column(String(240), nullable=False)
    source: Mapped[str | None] = mapped_column(String(16), nullable=True)
    category_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("categories.id", ondelete="RESTRICT"), nullable=True
    )
    account_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=True
    )
    evidence_count: Mapped[int] = mapped_column(Integer, nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )
