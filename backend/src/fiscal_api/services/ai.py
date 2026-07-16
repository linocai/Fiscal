from __future__ import annotations

import base64
import hashlib
import json
import unicodedata
from asyncio import CancelledError
from datetime import datetime
from typing import cast
from uuid import NAMESPACE_URL, UUID, uuid5

from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import TransactionDraft, TransactionResponse
from fiscal_api.api.p8_schemas import (
    AICandidate,
    AIField,
    AIFieldConfidences,
    AIParseRequest,
    AIProposalCreate,
    AIProposalMutationResponse,
    AIProposalPage,
    AIProposalResponse,
    AIProviderResult,
    AISettingsReplace,
    AISettingsResponse,
    ProposalSource,
    ProposalStatus,
)
from fiscal_api.core.errors import APIError
from fiscal_api.core.time import BUSINESS_TIMEZONE, utc_now
from fiscal_api.db.models import (
    Account,
    AIProposal,
    AIProposalStatus,
    AISettings,
    Category,
    TransactionKind,
    TransactionSource,
)
from fiscal_api.repositories.ai import AIRepository
from fiscal_api.services.ai_provider import AIProvider
from fiscal_api.services.common import acquire_mutation_lock, check_version, conflict, not_found
from fiscal_api.services.transactions import TransactionService

AUTO_AMOUNT_CEILING_MINOR = 100_000
AUTO_CONFIDENCE_FLOOR_BPS = 9_000
REQUIRED_CONFIDENCE_FIELDS = (
    "kind",
    "amount_minor",
    "occurred_at",
    "title",
    "account_id",
    "category_id",
)


class AIService:
    def __init__(self, session: AsyncSession, provider: AIProvider) -> None:
        self.session = session
        self.provider = provider
        self.repository = AIRepository(session)
        self.transactions = TransactionService(session)

    async def get_settings(self) -> AISettingsResponse:
        return self._settings_response(await self.repository.settings())

    async def update_settings(self, replacement: AISettingsReplace) -> AISettingsResponse:
        await acquire_mutation_lock(self.session)
        settings = await self.repository.settings(for_update=True)
        check_version(settings.version, replacement.expected_version)
        settings.auto_execute_enabled = replacement.auto_execute_enabled
        settings.ocr_source_enabled = replacement.ocr_source_enabled
        settings.shortcut_text_source_enabled = replacement.shortcut_text_source_enabled
        settings.auto_execute_limit_minor = replacement.auto_execute_limit_minor
        settings.minimum_confidence_bps = replacement.minimum_confidence_bps
        settings.version += 1
        settings.updated_at = utc_now()
        await self.session.commit()
        return self._settings_response(settings)

    async def create(self, request: AIProposalCreate, key: UUID) -> tuple[AIProposalResponse, bool]:
        request_hash = self._create_request_hash(request)
        existing = await self.repository.by_idempotency_key(key)
        if existing is not None:
            if existing.create_request_hash != request_hash:
                conflict("idempotency_key_reused", "该幂等键已用于不同的 AI 输入")
            return self._proposal_response(existing), True

        settings = await self.repository.settings()
        if request.source == "ocr" and not settings.ocr_source_enabled:
            raise APIError(
                status_code=403,
                code="ai_source_disabled",
                message="OCR 记账来源尚未启用",
            )
        if request.source == "shortcut_text" and not settings.shortcut_text_source_enabled:
            raise APIError(
                status_code=403,
                code="ai_source_disabled",
                message="快捷指令文本记账来源尚未启用",
            )

        normalized = unicodedata.normalize("NFKC", request.text)
        proposal = AIProposal(
            source=request.source,
            raw_input=request.text,
            content_fingerprint=hashlib.sha256(
                f"fiscal-ai-input-v2\n{request.source}\n{normalized}".encode()
            ).hexdigest(),
            create_idempotency_key=key,
            create_request_hash=request_hash,
            provider=self.provider.provider_id,
            provider_model=self.provider.model_id,
            field_confidences={},
            missing_fields=[],
            reason_codes=[],
            status=AIProposalStatus.PROCESSING.value,
        )
        await acquire_mutation_lock(self.session)
        replay = await self.repository.by_idempotency_key(key)
        if replay is not None:
            if replay.create_request_hash != request_hash:
                conflict("idempotency_key_reused", "该幂等键已用于不同的 AI 输入")
            return self._proposal_response(replay), True
        self.repository.add(proposal)
        await self.session.commit()
        return await self._parse_and_finalize(proposal.id), False

    async def get(self, proposal_id: UUID) -> AIProposalResponse:
        return self._proposal_response(await self._required(proposal_id))

    async def list(
        self, *, status: ProposalStatus | None, cursor: str | None, limit: int
    ) -> AIProposalPage:
        cursor_time, cursor_id = self._decode_cursor(cursor)
        values = await self.repository.page(
            status=status,
            cursor_time=cursor_time,
            cursor_id=cursor_id,
            limit=limit,
        )
        has_more = len(values) > limit
        page = values[:limit]
        next_cursor = self._encode_cursor(page[-1]) if has_more and page else None
        return AIProposalPage(
            items=[self._proposal_response(value) for value in page],
            next_cursor=next_cursor,
            pending_count=await self.repository.pending_count(),
        )

    async def edit(
        self, proposal_id: UUID, draft: TransactionDraft, expected_version: int
    ) -> AIProposalResponse:
        await acquire_mutation_lock(self.session)
        proposal = await self._required(proposal_id, for_update=True)
        check_version(proposal.version, expected_version)
        self._require_status(proposal, AIProposalStatus.PENDING)
        self._apply_draft(proposal, draft)
        proposal.field_confidences = AIFieldConfidences(
            kind=10_000,
            amount_minor=10_000,
            occurred_at=10_000,
            title=10_000,
            note=10_000,
            account_id=10_000,
            category_id=10_000,
            destination_account_id=10_000,
        ).model_dump()
        proposal.overall_confidence_bps = 10_000
        proposal.missing_fields = []
        proposal.reason_codes = ["user_edited"]
        proposal.error_code = None
        proposal.error_message = None
        self._touch(proposal)
        await self.session.commit()
        return self._proposal_response(proposal)

    async def execute(self, proposal_id: UUID, expected_version: int) -> AIProposalMutationResponse:
        await acquire_mutation_lock(self.session)
        proposal = await self._required(proposal_id, for_update=True)
        if (
            proposal.status == AIProposalStatus.EXECUTED.value
            and expected_version == proposal.version - 1
            and proposal.transaction_id is not None
        ):
            transaction = await self.transactions.get(proposal.transaction_id)
            response = AIProposalMutationResponse(
                proposal=self._proposal_response(proposal), transaction=transaction
            )
            await self.session.commit()
            return response
        check_version(proposal.version, expected_version)
        self._require_status(proposal, AIProposalStatus.PENDING)
        draft = self._draft(proposal)
        transaction = await self.transactions.create_ai(
            draft,
            self._transaction_key(proposal.id),
            self._ledger_source(proposal),
            commit=False,
        )
        self._mark_executed(proposal, transaction)
        await self.session.commit()
        return AIProposalMutationResponse(
            proposal=self._proposal_response(proposal), transaction=transaction
        )

    async def ignore(self, proposal_id: UUID, expected_version: int) -> AIProposalResponse:
        await acquire_mutation_lock(self.session)
        proposal = await self._required(proposal_id, for_update=True)
        check_version(proposal.version, expected_version)
        self._require_status(proposal, AIProposalStatus.PENDING)
        proposal.status = AIProposalStatus.IGNORED.value
        proposal.ignored_at = utc_now()
        self._touch(proposal)
        await self.session.commit()
        return self._proposal_response(proposal)

    async def retry(self, proposal_id: UUID, expected_version: int) -> AIProposalResponse:
        await acquire_mutation_lock(self.session)
        proposal = await self._required(proposal_id, for_update=True)
        check_version(proposal.version, expected_version)
        self._require_status(proposal, AIProposalStatus.FAILED)
        proposal.status = AIProposalStatus.PROCESSING.value
        proposal.error_code = None
        proposal.error_message = None
        proposal.provider = self.provider.provider_id
        proposal.provider_model = self.provider.model_id
        self._touch(proposal)
        await self.session.commit()
        return await self._parse_and_finalize(proposal.id)

    async def undo(
        self,
        proposal_id: UUID,
        expected_version: int,
        expected_transaction_version: int,
    ) -> AIProposalMutationResponse:
        await acquire_mutation_lock(self.session)
        proposal = await self._required(proposal_id, for_update=True)
        if (
            proposal.status == AIProposalStatus.UNDONE.value
            and expected_version == proposal.version - 1
            and proposal.transaction_id is not None
        ):
            transaction = await self.transactions.get(proposal.transaction_id)
            if (
                proposal.transaction_version != transaction.version
                or expected_transaction_version != transaction.version - 1
            ):
                conflict(
                    "ai_undo_transaction_changed",
                    "该流水在通知生成后已发生变化, 不能从旧通知撤销",
                )
            response = AIProposalMutationResponse(
                proposal=self._proposal_response(proposal), transaction=transaction
            )
            await self.session.commit()
            return response
        check_version(proposal.version, expected_version)
        self._require_status(proposal, AIProposalStatus.EXECUTED)
        if proposal.transaction_id is None:
            raise RuntimeError("executed AI proposal has no transaction")
        current = await self.transactions.get(proposal.transaction_id)
        if (
            proposal.transaction_version != current.version
            or expected_transaction_version != current.version
        ):
            conflict(
                "ai_undo_transaction_changed",
                "该流水在通知生成后已发生变化, 不能从旧通知撤销",
            )
        transaction = await self.transactions.void(
            proposal.transaction_id, expected_transaction_version, commit=False
        )
        proposal.status = AIProposalStatus.UNDONE.value
        proposal.transaction_version = transaction.version
        proposal.undone_at = utc_now()
        self._touch(proposal)
        await self.session.commit()
        return AIProposalMutationResponse(
            proposal=self._proposal_response(proposal), transaction=transaction
        )

    async def _parse_and_finalize(self, proposal_id: UUID) -> AIProposalResponse:
        proposal = await self._required(proposal_id)
        accounts = await self.repository.active_accounts()
        categories = await self.repository.active_categories()
        parse_request = AIParseRequest(
            text=proposal.raw_input,
            business_date=utc_now().astimezone(BUSINESS_TIMEZONE).date(),
            accounts=[AICandidate(id=item.id, name=item.name, kind=item.kind) for item in accounts],
            categories=[
                AICandidate(id=item.id, name=item.name, direction=item.direction)
                for item in categories
            ],
        )
        # Do not hold a database transaction or advisory lock across provider network I/O.
        await self.session.commit()
        try:
            result = await self.provider.parse(parse_request)
        except CancelledError:
            await self._mark_failed(
                proposal_id,
                APIError(
                    status_code=503,
                    code="ai_processing_cancelled",
                    message="AI 识别已取消, 可使用同一次操作重试",
                ),
            )
            raise
        except APIError as error:
            await self._mark_failed(proposal_id, error)
            raise
        await acquire_mutation_lock(self.session)
        locked = await self._required(proposal_id, for_update=True)
        self._require_status(locked, AIProposalStatus.PROCESSING)
        self._apply_provider_result(locked, result, accounts, categories)
        locked.status = AIProposalStatus.PENDING.value
        locked.parsed_at = utc_now()
        self._touch(locked)
        # Persist the normalized draft before attempting the ledger write. TransactionService
        # deliberately rolls its unit of work back on a formal validation error; keeping the
        # pending draft in an earlier transaction prevents that rollback from erasing review data.
        await self.session.commit()
        await acquire_mutation_lock(self.session)
        locked = await self._required(proposal_id, for_update=True)
        settings = await self.repository.settings()
        if not self._auto_eligible(locked, settings):
            await self.session.commit()
            return self._proposal_response(locked)
        try:
            transaction = await self.transactions.create_ai(
                self._draft(locked),
                self._transaction_key(locked.id),
                self._ledger_source(locked),
                commit=False,
            )
        except APIError:
            await self.session.rollback()
            await acquire_mutation_lock(self.session)
            locked = await self._required(proposal_id, for_update=True)
            locked.status = AIProposalStatus.PENDING.value
            locked.reason_codes = [*locked.reason_codes, "ledger_validation_failed"]
            self._touch(locked)
            await self.session.commit()
            return self._proposal_response(locked)
        self._mark_executed(locked, transaction)
        await self.session.commit()
        return self._proposal_response(locked)

    async def _mark_failed(self, proposal_id: UUID, error: APIError) -> None:
        await acquire_mutation_lock(self.session)
        proposal = await self._required(proposal_id, for_update=True)
        if proposal.status != AIProposalStatus.PROCESSING.value:
            conflict("ai_proposal_state_conflict", "AI 提案状态已改变")
        proposal.status = AIProposalStatus.FAILED.value
        proposal.error_code = error.code
        proposal.error_message = error.message[:200]
        self._touch(proposal)
        await self.session.commit()

    def _apply_provider_result(
        self,
        proposal: AIProposal,
        result: AIProviderResult,
        accounts: list[Account],
        categories: list[Category],
    ) -> None:
        reasons: list[str] = []
        active_accounts = {item.id: item for item in accounts}
        active_categories = {item.id: item for item in categories}
        kind = result.kind
        if kind in {
            TransactionKind.INSTALLMENT_FEE,
            TransactionKind.INSTALLMENT_REFUND,
            TransactionKind.REIMBURSEMENT_RECEIPT,
        }:
            kind = None
            reasons.append("forbidden_kind")
        account_id = result.account_id
        if account_id is not None and account_id not in active_accounts:
            account_id = None
            reasons.append("unknown_account")
        category_id = result.category_id
        if category_id is not None and category_id not in active_categories:
            category_id = None
            reasons.append("unknown_category")
        destination_id = result.destination_account_id
        if destination_id is not None and destination_id not in active_accounts:
            destination_id = None
            reasons.append("unknown_destination_account")
        if kind is TransactionKind.INCOME or kind is TransactionKind.EXPENSE:
            account = active_accounts.get(account_id) if account_id is not None else None
            category = active_categories.get(category_id) if category_id is not None else None
            if account is not None and account.kind not in {"cash", "debit"}:
                account_id = None
                reasons.append("account_kind_mismatch")
            if category is not None and category.direction != kind.value:
                category_id = None
                reasons.append("category_direction_mismatch")
        proposal.kind = kind.value if kind is not None else None
        proposal.amount_minor = result.amount_minor
        proposal.currency = "CNY" if result.amount_minor is not None else None
        proposal.occurred_at = result.occurred_at
        proposal.title = result.title
        proposal.note = result.note
        proposal.account_id = account_id
        proposal.category_id = category_id
        proposal.destination_account_id = destination_id
        proposal.field_confidences = result.confidences.model_dump()
        proposal.overall_confidence_bps = result.overall_confidence_bps
        proposal.missing_fields = list(result.missing_fields)
        proposal.reason_codes = reasons
        proposal.explanation = result.explanation
        proposal.error_code = None
        proposal.error_message = None

    @staticmethod
    def _auto_eligible(proposal: AIProposal, settings: AISettings) -> bool:
        if not settings.auto_execute_enabled:
            return False
        if proposal.source == "ocr" and not settings.ocr_source_enabled:
            return False
        if proposal.source == "shortcut_text" and not settings.shortcut_text_source_enabled:
            return False
        if proposal.reason_codes or proposal.missing_fields:
            return False
        if proposal.kind not in {TransactionKind.INCOME.value, TransactionKind.EXPENSE.value}:
            return False
        if proposal.amount_minor is None or proposal.amount_minor > min(
            settings.auto_execute_limit_minor, AUTO_AMOUNT_CEILING_MINOR
        ):
            return False
        threshold = max(settings.minimum_confidence_bps, AUTO_CONFIDENCE_FLOOR_BPS)
        if proposal.overall_confidence_bps is None or proposal.overall_confidence_bps < threshold:
            return False
        if any(
            proposal.field_confidences.get(field, 0) < threshold
            for field in REQUIRED_CONFIDENCE_FIELDS
        ):
            return False
        return (
            all(
                (
                    proposal.title,
                    proposal.amount_minor,
                    proposal.occurred_at,
                    proposal.account_id,
                    proposal.category_id,
                )
            )
            and proposal.destination_account_id is None
        )

    @staticmethod
    def _apply_draft(proposal: AIProposal, draft: TransactionDraft) -> None:
        proposal.kind = draft.kind.value
        proposal.amount_minor = draft.amount_minor
        proposal.currency = "CNY"
        proposal.occurred_at = draft.occurred_at
        proposal.title = draft.title
        proposal.note = draft.note
        proposal.account_id = draft.account_id
        proposal.category_id = draft.category_id
        proposal.destination_account_id = draft.destination_account_id
        proposal.credit_cycle_id = draft.credit_cycle_id

    @staticmethod
    def _draft(proposal: AIProposal) -> TransactionDraft:
        if (
            proposal.kind is None
            or proposal.amount_minor is None
            or proposal.occurred_at is None
            or proposal.title is None
        ):
            conflict("ai_proposal_incomplete", "AI 提案缺少执行所需字段")
        return TransactionDraft(
            kind=TransactionKind(proposal.kind),
            amount_minor=proposal.amount_minor,
            occurred_at=proposal.occurred_at,
            title=proposal.title,
            note=proposal.note,
            account_id=proposal.account_id,
            category_id=proposal.category_id,
            destination_account_id=proposal.destination_account_id,
            credit_cycle_id=proposal.credit_cycle_id,
        )

    @staticmethod
    def _mark_executed(proposal: AIProposal, transaction: TransactionResponse) -> None:
        proposal.status = AIProposalStatus.EXECUTED.value
        proposal.transaction_id = transaction.id
        proposal.transaction_version = transaction.version
        proposal.executed_at = utc_now()
        AIService._touch(proposal)

    async def _required(self, proposal_id: UUID, *, for_update: bool = False) -> AIProposal:
        proposal = await self.repository.proposal(proposal_id, for_update=for_update)
        if proposal is None:
            not_found("ai_proposal_not_found", "AI 提案不存在")
        return proposal

    @staticmethod
    def _require_status(proposal: AIProposal, expected: AIProposalStatus) -> None:
        if proposal.status != expected.value:
            conflict("ai_proposal_state_conflict", "AI 提案当前状态不允许此操作")

    @staticmethod
    def _touch(proposal: AIProposal) -> None:
        proposal.version += 1
        proposal.updated_at = utc_now()

    def _settings_response(self, settings: AISettings) -> AISettingsResponse:
        return AISettingsResponse(
            auto_execute_enabled=settings.auto_execute_enabled,
            ocr_source_enabled=settings.ocr_source_enabled,
            shortcut_text_source_enabled=settings.shortcut_text_source_enabled,
            auto_execute_limit_minor=settings.auto_execute_limit_minor,
            minimum_confidence_bps=settings.minimum_confidence_bps,
            version=settings.version,
            provider_configured=self.provider.configured,
            effective_auto_execute=settings.auto_execute_enabled and self.provider.configured,
            created_at=settings.created_at,
            updated_at=settings.updated_at,
        )

    @staticmethod
    def _proposal_response(proposal: AIProposal) -> AIProposalResponse:
        return AIProposalResponse(
            id=proposal.id,
            source=cast(ProposalSource, proposal.source),
            text=proposal.raw_input,
            content_fingerprint=proposal.content_fingerprint,
            provider=proposal.provider,
            model=proposal.provider_model,
            kind=TransactionKind(proposal.kind) if proposal.kind is not None else None,
            amount_minor=proposal.amount_minor,
            occurred_at=proposal.occurred_at,
            title=proposal.title,
            note=proposal.note,
            account_id=proposal.account_id,
            category_id=proposal.category_id,
            destination_account_id=proposal.destination_account_id,
            credit_cycle_id=proposal.credit_cycle_id,
            field_confidences=AIFieldConfidences.model_validate(proposal.field_confidences),
            overall_confidence_bps=proposal.overall_confidence_bps,
            missing_fields=cast(list[AIField], proposal.missing_fields),
            reason_codes=proposal.reason_codes,
            explanation=proposal.explanation,
            status=cast(ProposalStatus, proposal.status),
            error_code=proposal.error_code,
            error_message=proposal.error_message,
            transaction_id=proposal.transaction_id,
            transaction_version=proposal.transaction_version,
            version=proposal.version,
            created_at=proposal.created_at,
            updated_at=proposal.updated_at,
            executed_at=proposal.executed_at,
            ignored_at=proposal.ignored_at,
            undone_at=proposal.undone_at,
        )

    @staticmethod
    def _create_request_hash(request: AIProposalCreate) -> str:
        encoded = json.dumps(
            request.model_dump(mode="json"), sort_keys=True, separators=(",", ":")
        ).encode()
        return hashlib.sha256(encoded).hexdigest()

    @staticmethod
    def _transaction_key(proposal_id: UUID) -> UUID:
        return uuid5(NAMESPACE_URL, f"fiscal-ai-text:{proposal_id}")

    @staticmethod
    def _ledger_source(proposal: AIProposal) -> TransactionSource:
        if proposal.source == "ocr":
            return TransactionSource.OCR
        return TransactionSource.AI_TEXT

    @staticmethod
    def _encode_cursor(proposal: AIProposal) -> str:
        payload = json.dumps(
            {"created_at": proposal.created_at.isoformat(), "id": str(proposal.id)},
            separators=(",", ":"),
        ).encode()
        return base64.urlsafe_b64encode(payload).decode().rstrip("=")

    @staticmethod
    def _decode_cursor(cursor: str | None) -> tuple[datetime | None, UUID | None]:
        if cursor is None:
            return None, None
        try:
            padded = cursor + "=" * (-len(cursor) % 4)
            payload = json.loads(base64.urlsafe_b64decode(padded))
            return datetime.fromisoformat(payload["created_at"]), UUID(payload["id"])
        except (ValueError, TypeError, KeyError, json.JSONDecodeError):
            raise APIError(
                status_code=422,
                code="invalid_ai_proposal_cursor",
                message="AI 提案游标无效",
            ) from None
