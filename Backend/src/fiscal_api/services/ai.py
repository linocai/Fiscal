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
    AIExecutionPolicyReplace,
    AIExecutionPolicyResponse,
    AIField,
    AIFieldConfidences,
    AILearningRuleResponse,
    AIParseRequest,
    AIProposalCreate,
    AIProposalMutationResponse,
    AIProposalPage,
    AIProposalResponse,
    AIProviderResult,
    AIProviderSettingsReplace,
    AIProviderSettingsResponse,
    AIQualityEventResponse,
    AIQualityMetricsResponse,
    AIQualityMetricsRow,
    AISettingsReplace,
    AISettingsResponse,
    AIShadowEvaluationCreate,
    AIShadowEvaluationResponse,
    LearningRuleKind,
    ProposalSource,
    ProposalStatus,
    ProposalTarget,
    QualityEventType,
)
from fiscal_api.api.p13_schemas import CashFlowDraft, CashFlowMutationScope
from fiscal_api.core.config import Settings
from fiscal_api.core.errors import APIError
from fiscal_api.core.principal import AuthenticatedPrincipal
from fiscal_api.core.provider_credentials import ProviderCredentialCipher
from fiscal_api.core.time import BUSINESS_TIMEZONE, utc_now
from fiscal_api.db.models import (
    Account,
    AIExecutionPolicy,
    AILearningRule,
    AIProposal,
    AIProposalStatus,
    AIProposalTarget,
    AIQualityEvent,
    AIQualityEventType,
    AISettings,
    AIShadowEvaluation,
    CashFlowDirection,
    CashFlowSource,
    Category,
    TransactionKind,
    TransactionSource,
)
from fiscal_api.repositories.ai import AIRepository
from fiscal_api.services.ai_provider import AIProvider, build_stored_ai_provider
from fiscal_api.services.cash_flow import CashFlowService
from fiscal_api.services.common import acquire_mutation_lock, check_version, conflict, not_found
from fiscal_api.services.transactions import TransactionService

RETIRED_POLICY_MINIMUM_SAMPLE_SIZE = 30


class AIService:
    def __init__(
        self,
        session: AsyncSession,
        provider: AIProvider,
        runtime_settings: Settings | None = None,
        credential_cipher: ProviderCredentialCipher | None = None,
    ) -> None:
        self.session = session
        self.provider = provider
        self.runtime_settings = runtime_settings
        self.credential_cipher = credential_cipher
        self.repository = AIRepository(session)
        self.transactions = TransactionService(session)

    async def get_settings(self) -> AISettingsResponse:
        return self._settings_response(await self.repository.settings())

    async def update_settings(self, replacement: AISettingsReplace) -> AISettingsResponse:
        await acquire_mutation_lock(self.session)
        settings = await self.repository.settings(for_update=True)
        self._reject_retired_auto_execute(
            enabled=replacement.auto_execute_enabled,
            limit=replacement.auto_execute_limit_minor,
            confidence=replacement.minimum_confidence_bps,
            minimum_sample_size=RETIRED_POLICY_MINIMUM_SAMPLE_SIZE,
            current_limit=settings.auto_execute_limit_minor,
            current_confidence=settings.minimum_confidence_bps,
            current_minimum_sample_size=RETIRED_POLICY_MINIMUM_SAMPLE_SIZE,
        )
        check_version(settings.version, replacement.expected_version)
        settings.auto_execute_enabled = False
        settings.ocr_source_enabled = replacement.ocr_source_enabled
        settings.shortcut_text_source_enabled = replacement.shortcut_text_source_enabled
        settings.auto_execute_limit_minor = replacement.auto_execute_limit_minor
        settings.minimum_confidence_bps = replacement.minimum_confidence_bps
        settings.version += 1
        settings.updated_at = utc_now()
        await self.session.commit()
        return self._settings_response(settings)

    async def quality_events(self, proposal_id: UUID) -> list[AIQualityEventResponse]:
        await self._required(proposal_id)
        return [
            self._event_response(event)
            for event in await self.repository.quality_events(proposal_id)
        ]

    async def quality_metrics(self) -> AIQualityMetricsResponse:
        proposals = await self.repository.all_proposals()
        events = await self.repository.quality_events()
        by_proposal: dict[UUID, set[str]] = {}
        for event in events:
            by_proposal.setdefault(event.proposal_id, set()).add(event.event_type)
        rows: dict[
            tuple[str, str | None, str | None, str | None, str | None, str], dict[str, int]
        ] = {}
        for proposal in proposals:
            key = (
                proposal.source,
                proposal.provider,
                proposal.provider_model,
                proposal.prompt_version,
                proposal.kind,
                self._amount_band(proposal.amount_minor),
            )
            values = rows.setdefault(
                key,
                {
                    name: 0
                    for name in (
                        "total",
                        "parse_succeeded",
                        "historical_unavailable",
                        "confirm_unchanged",
                        "confirm_edited",
                        "ignored",
                        "execute_failed",
                        "automatic_execute",
                        "manual_execute",
                        "undone",
                        "provider_retry",
                        "final_failure",
                        "pending",
                        "terminal_outcomes",
                    )
                },
            )
            values["total"] += 1
            event_types = by_proposal.get(proposal.id, set())
            if proposal.initial_parse_snapshot is None:
                values["historical_unavailable"] += 1
            else:
                values["parse_succeeded"] += 1
            for event_type in event_types:
                if event_type in values:
                    values[event_type] += 1
            if (
                proposal.status == AIProposalStatus.PROCESSING.value
                or proposal.status == AIProposalStatus.PENDING.value
            ):
                values["pending"] += 1
            else:
                values["terminal_outcomes"] += 1
        return AIQualityMetricsResponse(
            rows=[
                AIQualityMetricsRow(
                    source=cast(ProposalSource, key[0]),
                    provider=key[1],
                    model=key[2],
                    prompt_version=key[3],
                    transaction_kind=key[4],
                    amount_band=key[5],
                    **values,
                )
                for key, values in sorted(rows.items(), key=lambda item: str(item[0]))
            ]
        )

    async def policies(self) -> list[AIExecutionPolicyResponse]:
        return [self._policy_response(value) for value in await self.repository.policies()]

    async def replace_policy(
        self, replacement: AIExecutionPolicyReplace
    ) -> AIExecutionPolicyResponse:
        await acquire_mutation_lock(self.session)
        settings = await self.repository.settings(for_update=True)
        previous = await self.repository.latest_policy_for_scope(
            source=replacement.source,
            transaction_kind=replacement.transaction_kind,
            for_update=True,
        )
        latest = await self.repository.latest_policy(for_update=True)
        # Global settings are the fail-closed ceiling/floor inherited by every
        # policy scope. A scope may only tighten that baseline; after its first
        # row, only that exact NULL-safe source/kind scope supplies its history.
        # minimum_sample_size has no settings field, so 30 is its explicit
        # retirement baseline and another scope can never raise or lower it.
        current_limit = min(
            settings.auto_execute_limit_minor,
            previous.auto_execute_limit_minor
            if previous is not None
            else settings.auto_execute_limit_minor,
        )
        current_confidence = max(
            settings.minimum_confidence_bps,
            previous.minimum_confidence_bps
            if previous is not None
            else settings.minimum_confidence_bps,
        )
        current_minimum_sample_size = max(
            RETIRED_POLICY_MINIMUM_SAMPLE_SIZE,
            previous.minimum_sample_size
            if previous is not None
            else RETIRED_POLICY_MINIMUM_SAMPLE_SIZE,
        )
        self._reject_retired_auto_execute(
            enabled=replacement.auto_execute_enabled,
            limit=replacement.auto_execute_limit_minor,
            confidence=replacement.minimum_confidence_bps,
            minimum_sample_size=replacement.minimum_sample_size,
            current_limit=current_limit,
            current_confidence=current_confidence,
            current_minimum_sample_size=current_minimum_sample_size,
        )
        policy = AIExecutionPolicy(
            version=(latest.version + 1) if latest else 1,
            source=replacement.source,
            transaction_kind=replacement.transaction_kind,
            auto_execute_enabled=False,
            auto_execute_limit_minor=replacement.auto_execute_limit_minor,
            minimum_confidence_bps=replacement.minimum_confidence_bps,
            minimum_sample_size=replacement.minimum_sample_size,
            change_reason=replacement.change_reason,
            changed_automatically=False,
        )
        self.repository.add_policy(policy)
        if replacement.source is None and replacement.transaction_kind is None:
            settings.auto_execute_enabled = False
            settings.auto_execute_limit_minor = replacement.auto_execute_limit_minor
            settings.minimum_confidence_bps = replacement.minimum_confidence_bps
            settings.version += 1
            settings.updated_at = utc_now()
        await self.session.commit()
        return self._policy_response(policy)

    async def rules(self) -> list[AILearningRuleResponse]:
        return [self._rule_response(value) for value in await self.repository.rules()]

    async def revoke_rule(self, rule_id: UUID) -> AILearningRuleResponse:
        await acquire_mutation_lock(self.session)
        rule = await self.repository.rule(rule_id, for_update=True)
        if rule is None:
            not_found("ai_learning_rule_not_found", "学习规则不存在")
        rule.enabled = False
        rule.revoked_at = utc_now()
        rule.updated_at = utc_now()
        await self.session.commit()
        return self._rule_response(rule)

    async def get_provider_settings(self) -> AIProviderSettingsResponse:
        return self._provider_settings_response(await self.repository.settings())

    async def update_provider_settings(
        self, replacement: AIProviderSettingsReplace, _actor: AuthenticatedPrincipal
    ) -> AIProviderSettingsResponse:
        if self.runtime_settings is None or self.credential_cipher is None:
            raise APIError(
                status_code=503,
                code="ai_provider_configuration_unavailable",
                message="AI Provider 配置服务暂时不可用",
            )
        if self.runtime_settings.environment in {
            "staging",
            "production",
        } and not replacement.base_url.startswith("https://"):
            raise APIError(
                status_code=422,
                code="ai_provider_https_required",
                message="生产环境的 AI Provider 必须使用 HTTPS",
            )
        await acquire_mutation_lock(self.session)
        settings = await self.repository.settings(for_update=True)
        check_version(settings.version, replacement.expected_version)
        candidate_changed = settings.provider_model is not None and (
            settings.provider_model != replacement.model
            or settings.prompt_version != replacement.prompt_version
        )
        if (
            candidate_changed
            and await self.repository.passing_shadow_evaluation(
                provider=replacement.provider,
                model=replacement.model,
                prompt_version=replacement.prompt_version,
            )
            is None
        ):
            conflict("ai_shadow_evaluation_required", "新模型或提示词必须先通过脱敏 shadow corpus")
        if replacement.api_key is not None:
            settings.provider_api_key_ciphertext = self.credential_cipher.encrypt(
                replacement.api_key
            )
            settings.provider_key_version = self.credential_cipher.version
        elif settings.provider_api_key_ciphertext is None:
            raise APIError(
                status_code=422,
                code="ai_provider_api_key_required",
                message="首次配置 AI Provider 时必须填写 API Key",
            )
        settings.provider_kind = replacement.provider
        settings.provider_base_url = replacement.base_url
        settings.provider_model = replacement.model
        settings.prompt_version = replacement.prompt_version
        settings.version += 1
        settings.updated_at = utc_now()
        await self.session.commit()
        return self._provider_settings_response(settings)

    async def record_shadow_evaluation(
        self, record: AIShadowEvaluationCreate
    ) -> AIShadowEvaluationResponse:
        if record.passed_cases != record.sample_size:
            conflict("ai_shadow_evaluation_incomplete", "shadow corpus 必须全部通过后才能登记")
        await acquire_mutation_lock(self.session)
        existing = await self.repository.passing_shadow_evaluation(
            provider=record.provider, model=record.model, prompt_version=record.prompt_version
        )
        if existing is not None:
            return self._shadow_response(existing)
        value = AIShadowEvaluation(
            provider=record.provider,
            model=record.model,
            prompt_version=record.prompt_version,
            corpus_fingerprint=record.corpus_fingerprint,
            sample_size=record.sample_size,
            passed_cases=record.passed_cases,
            evaluator_version=record.evaluator_version,
        )
        self.repository.add_shadow_evaluation(value)
        await self.session.commit()
        return self._shadow_response(value)

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
        provider = self._provider_for(settings)
        proposal = AIProposal(
            source=request.source,
            raw_input=request.text,
            content_fingerprint=hashlib.sha256(
                f"fiscal-ai-input-v2\n{request.source}\n{normalized}".encode()
            ).hexdigest(),
            create_idempotency_key=key,
            create_request_hash=request_hash,
            provider=provider.provider_id,
            provider_model=provider.model_id,
            prompt_version=settings.prompt_version,
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
        return await self._parse_and_finalize(proposal.id, provider), False

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
        proposal.target = self._proposal_target(proposal, draft.kind).value
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
        ):
            transaction = (
                await self.transactions.get(proposal.transaction_id)
                if proposal.transaction_id is not None
                else None
            )
            cash_flow_item = (
                await CashFlowService(self.session).get(proposal.cash_flow_item_id)
                if proposal.cash_flow_item_id is not None
                else None
            )
            response = AIProposalMutationResponse(
                proposal=self._proposal_response(proposal),
                transaction=transaction,
                cash_flow_item=cash_flow_item,
            )
            await self.session.commit()
            return response
        check_version(proposal.version, expected_version)
        self._require_status(proposal, AIProposalStatus.PENDING)
        if proposal.target == AIProposalTarget.CASH_FLOW.value:
            try:
                created = await CashFlowService(self.session).create(
                    self._cash_flow_draft(proposal),
                    self._cash_flow_key(proposal.id),
                    source=CashFlowSource.AI_TEXT,
                )
            except APIError as error:
                await self.session.rollback()
                await self._record_execute_failure(proposal_id, error.code)
                raise
            item = created.items[0]
            if item.manual_item_id is None:
                raise RuntimeError("AI cash flow proposal created no manual item")
            proposal = await self._required(proposal_id, for_update=True)
            proposal.status = AIProposalStatus.EXECUTED.value
            proposal.cash_flow_item_id = item.manual_item_id
            proposal.cash_flow_item_version = item.version
            proposal.executed_at = utc_now()
            await self._finalize_confirmation(proposal)
            self._event(proposal, AIQualityEventType.MANUAL_EXECUTE)
            self._touch(proposal)
            await self.session.commit()
            return AIProposalMutationResponse(
                proposal=self._proposal_response(proposal), cash_flow_item=item
            )
        draft = self._draft(proposal)
        try:
            transaction = await self.transactions.create_ai(
                draft,
                self._transaction_key(proposal.id),
                self._ledger_source(proposal),
                commit=False,
            )
        except APIError as error:
            await self.session.rollback()
            await self._record_execute_failure(proposal_id, error.code)
            raise
        self._mark_executed(proposal, transaction)
        await self._finalize_confirmation(proposal)
        self._event(proposal, AIQualityEventType.MANUAL_EXECUTE)
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
        self._event(proposal, AIQualityEventType.IGNORED)
        self._touch(proposal)
        await self.session.commit()
        return self._proposal_response(proposal)

    async def retry(self, proposal_id: UUID, expected_version: int) -> AIProposalResponse:
        await acquire_mutation_lock(self.session)
        proposal = await self._required(proposal_id, for_update=True)
        check_version(proposal.version, expected_version)
        self._require_status(proposal, AIProposalStatus.FAILED)
        self._event(proposal, AIQualityEventType.PROVIDER_RETRY)
        proposal.status = AIProposalStatus.PROCESSING.value
        proposal.error_code = None
        proposal.error_message = None
        provider = self._provider_for(await self.repository.settings())
        proposal.provider = provider.provider_id
        proposal.provider_model = provider.model_id
        self._touch(proposal)
        await self.session.commit()
        return await self._parse_and_finalize(proposal.id, provider)

    async def undo(
        self,
        proposal_id: UUID,
        expected_version: int,
        expected_transaction_version: int | None,
    ) -> AIProposalMutationResponse:
        await acquire_mutation_lock(self.session)
        proposal = await self._required(proposal_id, for_update=True)
        if proposal.cash_flow_item_id is not None:
            if proposal.status == AIProposalStatus.UNDONE.value:
                item = await CashFlowService(self.session).get(proposal.cash_flow_item_id)
                await self.session.commit()
                return AIProposalMutationResponse(
                    proposal=self._proposal_response(proposal), cash_flow_item=item
                )
            check_version(proposal.version, expected_version)
            self._require_status(proposal, AIProposalStatus.EXECUTED)
            if proposal.cash_flow_item_version is None:
                raise RuntimeError("AI cash flow proposal is missing its item version")
            cancelled = await CashFlowService(self.session).cancel(
                proposal.cash_flow_item_id,
                proposal.cash_flow_item_version,
                CashFlowMutationScope.OCCURRENCE,
            )
            item = cancelled.items[0]
            proposal = await self._required(proposal_id, for_update=True)
            proposal.status = AIProposalStatus.UNDONE.value
            proposal.cash_flow_item_version = item.version
            proposal.undone_at = utc_now()
            self._event(proposal, AIQualityEventType.UNDONE)
            self._touch(proposal)
            await self.session.commit()
            return AIProposalMutationResponse(
                proposal=self._proposal_response(proposal), cash_flow_item=item
            )
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
        if expected_transaction_version is None:
            conflict("ai_undo_transaction_version_required", "缺少流水版本, 无法安全撤销")
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
        self._event(proposal, AIQualityEventType.UNDONE)
        self._touch(proposal)
        await self.session.commit()
        return AIProposalMutationResponse(
            proposal=self._proposal_response(proposal), transaction=transaction
        )

    async def _parse_and_finalize(
        self, proposal_id: UUID, provider: AIProvider
    ) -> AIProposalResponse:
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
            result = await provider.parse(parse_request)
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
        await self._apply_deterministic_rules(locked)
        locked.initial_parse_snapshot = self._snapshot(locked)
        locked.status = AIProposalStatus.PENDING.value
        locked.parsed_at = utc_now()
        self._event(locked, AIQualityEventType.PARSED)
        self._touch(locked)
        # D3: parsing always ends at an explicit human-review boundary.  No
        # settings row, legacy execution policy or provider confidence can
        # turn this parse/finalize path into a ledger mutation.
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
        self._event(proposal, AIQualityEventType.FINAL_FAILURE, error.code)
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
        if kind is TransactionKind.EXPENSE and account_id is not None:
            account = active_accounts.get(account_id)
            if account is not None and account.kind == "credit":
                # A credit-account payment described as a plain expense (花呗/白条 扣款) IS a
                # credit purchase in this ledger; reclassify instead of blanking the account
                # and stranding the proposal. The reason code keeps it out of auto-execution.
                kind = TransactionKind.CREDIT_PURCHASE
                reasons.append("credit_purchase_reclassified")
        if kind is TransactionKind.INCOME or kind is TransactionKind.EXPENSE:
            account = active_accounts.get(account_id) if account_id is not None else None
            category = active_categories.get(category_id) if category_id is not None else None
            if account is not None and account.kind not in {"cash", "debit"}:
                account_id = None
                reasons.append("account_kind_mismatch")
            if category is not None and category.direction != kind.value:
                category_id = None
                reasons.append("category_direction_mismatch")
        elif kind is TransactionKind.CREDIT_PURCHASE:
            account = active_accounts.get(account_id) if account_id is not None else None
            category = active_categories.get(category_id) if category_id is not None else None
            if account is not None and account.kind != "credit":
                account_id = None
                reasons.append("account_kind_mismatch")
            if category is not None and category.direction != "expense":
                category_id = None
                reasons.append("category_direction_mismatch")
        elif kind is TransactionKind.TRANSFER or kind is TransactionKind.REPAYMENT:
            account = active_accounts.get(account_id) if account_id is not None else None
            if account is not None and account.kind not in {"cash", "debit"}:
                account_id = None
                reasons.append("account_kind_mismatch")
            destination = (
                active_accounts.get(destination_id) if destination_id is not None else None
            )
            required = {"credit"} if kind is TransactionKind.REPAYMENT else {"cash", "debit"}
            if destination is not None and destination.kind not in required:
                destination_id = None
                reasons.append("destination_kind_mismatch")
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
        proposal.target = self._proposal_target(proposal, kind).value
        if proposal.target == AIProposalTarget.CASH_FLOW.value:
            proposal.reason_codes = [
                *proposal.reason_codes,
                "future_cash_flow_requires_confirmation",
            ]
        proposal.explanation = result.explanation
        proposal.error_code = None
        proposal.error_message = None

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
    def _cash_flow_draft(proposal: AIProposal) -> CashFlowDraft:
        draft = AIService._draft(proposal)
        direction = {
            TransactionKind.INCOME: CashFlowDirection.INFLOW,
            TransactionKind.EXPENSE: CashFlowDirection.OUTFLOW,
            TransactionKind.TRANSFER: CashFlowDirection.TRANSFER,
        }.get(draft.kind)
        if direction is None:
            conflict("ai_cash_flow_kind_invalid", "该 AI 提案不能创建未来现金流")
        return CashFlowDraft(
            title=draft.title,
            note=draft.note,
            direction=direction,
            planned_amount_minor=draft.amount_minor,
            expected_date=draft.occurred_at.astimezone(BUSINESS_TIMEZONE).date(),
            account_id=draft.account_id,
            destination_account_id=draft.destination_account_id,
            category_id=draft.category_id,
        )

    @staticmethod
    def _proposal_target(proposal: AIProposal, kind: TransactionKind | None) -> AIProposalTarget:
        if kind not in {TransactionKind.INCOME, TransactionKind.EXPENSE, TransactionKind.TRANSFER}:
            return AIProposalTarget.TRANSACTION
        business_today = utc_now().astimezone(BUSINESS_TIMEZONE).date()
        future_date = (
            proposal.occurred_at is not None
            and proposal.occurred_at.astimezone(BUSINESS_TIMEZONE).date() > business_today
        )
        planned_language = any(
            marker in proposal.raw_input
            for marker in ("计划", "预计", "将于", "下个月", "下周", "未来", "每月")
        )
        return (
            AIProposalTarget.CASH_FLOW
            if future_date or planned_language
            else AIProposalTarget.TRANSACTION
        )

    @staticmethod
    def _mark_executed(proposal: AIProposal, transaction: TransactionResponse) -> None:
        proposal.status = AIProposalStatus.EXECUTED.value
        proposal.transaction_id = transaction.id
        proposal.transaction_version = transaction.version
        proposal.executed_at = utc_now()
        AIService._touch(proposal)

    async def _record_execute_failure(self, proposal_id: UUID, reason: str) -> None:
        await acquire_mutation_lock(self.session)
        proposal = await self._required(proposal_id, for_update=True)
        self._event(proposal, AIQualityEventType.EXECUTE_FAILED, reason)
        await self.session.commit()

    async def _finalize_confirmation(self, proposal: AIProposal) -> None:
        snapshot = self._snapshot(proposal)
        proposal.final_confirmed_snapshot = snapshot
        diff = self._field_diff(proposal.initial_parse_snapshot, snapshot)
        proposal.final_field_diff = diff
        self._event(
            proposal,
            AIQualityEventType.CONFIRM_EDITED if diff else AIQualityEventType.CONFIRM_UNCHANGED,
            details={"changed_fields": sorted(diff)},
        )
        await self._learn_from_confirmation(proposal)

    async def _learn_from_confirmation(self, proposal: AIProposal) -> None:
        if not proposal.title:
            return
        key = self._normalized_key(proposal.title)
        candidates = (
            ("merchant_category", proposal.category_id, None),
            ("title_account", None, proposal.account_id),
            ("category_alias", proposal.category_id, None),
        )
        for kind, category_id, account_id in candidates:
            if category_id is None and account_id is None:
                continue
            count = await self.repository.evidence_count(
                title=proposal.title, category_id=category_id, account_id=account_id
            )
            if count < 2:
                continue
            existing = await self.repository.matching_rule(
                rule_kind=kind,
                normalized_key=key,
                source=proposal.source if kind == "category_alias" else None,
            )
            if existing is None:
                self.repository.add_rule(
                    AILearningRule(
                        rule_kind=kind,
                        normalized_key=key,
                        source=proposal.source if kind == "category_alias" else None,
                        category_id=category_id,
                        account_id=account_id,
                        evidence_count=count,
                    )
                )
            else:
                existing.evidence_count = count
                existing.updated_at = utc_now()

    async def _apply_deterministic_rules(self, proposal: AIProposal) -> None:
        if not proposal.title:
            return
        key = self._normalized_key(proposal.title)
        category_rule = await self.repository.matching_rule(
            rule_kind="merchant_category", normalized_key=key, source=None
        )
        account_rule = await self.repository.matching_rule(
            rule_kind="title_account", normalized_key=key, source=None
        )
        alias_rule = await self.repository.matching_rule(
            rule_kind="category_alias", normalized_key=key, source=proposal.source
        )
        rule = category_rule or alias_rule
        if proposal.category_id is None and rule is not None and rule.category_id is not None:
            proposal.category_id = rule.category_id
            proposal.reason_codes = [*proposal.reason_codes, f"deterministic_rule:{rule.id}"]
        if (
            proposal.account_id is None
            and account_rule is not None
            and account_rule.account_id is not None
        ):
            proposal.account_id = account_rule.account_id
            proposal.reason_codes = [
                *proposal.reason_codes,
                f"deterministic_rule:{account_rule.id}",
            ]

    def _event(
        self,
        proposal: AIProposal,
        event_type: AIQualityEventType,
        reason: str | None = None,
        details: dict[str, object] | None = None,
    ) -> None:
        self.repository.add_quality_event(
            AIQualityEvent(
                proposal_id=proposal.id,
                event_type=event_type.value,
                reason=reason,
                details=details or {},
            )
        )

    @staticmethod
    def _snapshot(proposal: AIProposal) -> dict[str, object]:
        return {
            "kind": proposal.kind,
            "amount_minor": proposal.amount_minor,
            "currency": proposal.currency,
            "occurred_at": proposal.occurred_at.isoformat() if proposal.occurred_at else None,
            "title": proposal.title,
            "note": proposal.note,
            "account_id": str(proposal.account_id) if proposal.account_id else None,
            "category_id": str(proposal.category_id) if proposal.category_id else None,
            "destination_account_id": str(proposal.destination_account_id)
            if proposal.destination_account_id
            else None,
            "credit_cycle_id": str(proposal.credit_cycle_id) if proposal.credit_cycle_id else None,
            "target": proposal.target,
        }

    @staticmethod
    def _field_diff(
        initial: dict[str, object] | None, final: dict[str, object]
    ) -> dict[str, object]:
        if initial is None:
            return {}
        return {
            key: {"from": initial.get(key), "to": value}
            for key, value in final.items()
            if initial.get(key) != value
        }

    @staticmethod
    def _normalized_key(value: str) -> str:
        return " ".join(unicodedata.normalize("NFKC", value).casefold().split())[:240]

    @staticmethod
    def _amount_band(value: int | None) -> str:
        if value is None:
            return "unknown"
        if value < 10_000:
            return "<100"
        if value < 100_000:
            return "100-999.99"
        return ">=1000"

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
        configured = self._provider_configured(settings)
        return AISettingsResponse(
            auto_execute_enabled=False,
            ocr_source_enabled=settings.ocr_source_enabled,
            shortcut_text_source_enabled=settings.shortcut_text_source_enabled,
            auto_execute_limit_minor=settings.auto_execute_limit_minor,
            minimum_confidence_bps=settings.minimum_confidence_bps,
            version=settings.version,
            provider_configured=configured,
            effective_auto_execute=False,
            created_at=settings.created_at,
            updated_at=settings.updated_at,
        )

    @staticmethod
    def _event_response(event: AIQualityEvent) -> AIQualityEventResponse:
        return AIQualityEventResponse(
            id=event.id,
            proposal_id=event.proposal_id,
            event_type=cast(QualityEventType, event.event_type),
            reason=event.reason,
            details=event.details,
            occurred_at=event.occurred_at,
        )

    @staticmethod
    def _policy_response(policy: AIExecutionPolicy) -> AIExecutionPolicyResponse:
        return AIExecutionPolicyResponse(
            id=policy.id,
            version=policy.version,
            effective_at=policy.effective_at,
            source=cast(ProposalSource | None, policy.source),
            transaction_kind=policy.transaction_kind,
            auto_execute_enabled=False,
            auto_execute_limit_minor=policy.auto_execute_limit_minor,
            minimum_confidence_bps=policy.minimum_confidence_bps,
            minimum_sample_size=policy.minimum_sample_size,
            change_reason=policy.change_reason,
            changed_automatically=policy.changed_automatically,
        )

    @staticmethod
    def _reject_retired_auto_execute(
        *,
        enabled: bool,
        limit: int,
        confidence: int,
        minimum_sample_size: int,
        current_limit: int,
        current_confidence: int,
        current_minimum_sample_size: int,
    ) -> None:
        if (
            enabled
            or limit > current_limit
            or confidence < current_confidence
            or minimum_sample_size < current_minimum_sample_size
        ):
            conflict(
                "ai_auto_execute_retired",
                "AI automatic execution is retired; proposals require human confirmation",
            )

    @staticmethod
    def _rule_response(rule: AILearningRule) -> AILearningRuleResponse:
        return AILearningRuleResponse(
            id=rule.id,
            rule_kind=cast(LearningRuleKind, rule.rule_kind),
            normalized_key=rule.normalized_key,
            source=cast(ProposalSource | None, rule.source),
            category_id=rule.category_id,
            account_id=rule.account_id,
            evidence_count=rule.evidence_count,
            enabled=rule.enabled,
            revoked_at=rule.revoked_at,
            created_at=rule.created_at,
            updated_at=rule.updated_at,
        )

    @staticmethod
    def _shadow_response(value: AIShadowEvaluation) -> AIShadowEvaluationResponse:
        return AIShadowEvaluationResponse(
            id=value.id,
            provider=value.provider,
            model=value.model,
            prompt_version=value.prompt_version,
            corpus_fingerprint=value.corpus_fingerprint,
            sample_size=value.sample_size,
            passed_cases=value.passed_cases,
            evaluator_version=value.evaluator_version,
            completed_at=value.completed_at,
        )

    def _provider_configured(self, settings: AISettings) -> bool:
        stored = all(
            (
                settings.provider_kind == "openai_compatible",
                settings.provider_base_url,
                settings.provider_model,
                settings.provider_api_key_ciphertext,
                settings.provider_key_version,
                self.runtime_settings,
                self.credential_cipher,
            )
        )
        return bool(stored or self.provider.configured)

    def _provider_for(self, settings: AISettings) -> AIProvider:
        if (
            settings.provider_kind == "openai_compatible"
            and settings.provider_base_url is not None
            and settings.provider_model is not None
            and settings.provider_api_key_ciphertext is not None
            and settings.provider_key_version is not None
            and self.runtime_settings is not None
            and self.credential_cipher is not None
        ):
            try:
                api_key = self.credential_cipher.decrypt(
                    settings.provider_api_key_ciphertext,
                    settings.provider_key_version,
                )
            except (ValueError, UnicodeDecodeError):
                raise APIError(
                    status_code=503,
                    code="ai_provider_credential_unavailable",
                    message="AI Provider 密钥无法解密, 请由管理员重新配置",
                ) from None
            return build_stored_ai_provider(
                base_url=settings.provider_base_url,
                model=settings.provider_model,
                api_key=api_key,
                settings=self.runtime_settings,
            )
        return self.provider

    @staticmethod
    def _provider_settings_response(settings: AISettings) -> AIProviderSettingsResponse:
        return AIProviderSettingsResponse(
            provider=(
                "openai_compatible" if settings.provider_kind == "openai_compatible" else None
            ),
            base_url=settings.provider_base_url,
            model=settings.provider_model,
            api_key_configured=settings.provider_api_key_ciphertext is not None,
            version=settings.version,
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
            target=cast(ProposalTarget, proposal.target),
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
            cash_flow_item_id=proposal.cash_flow_item_id,
            cash_flow_item_version=proposal.cash_flow_item_version,
            version=proposal.version,
            created_at=proposal.created_at,
            updated_at=proposal.updated_at,
            executed_at=proposal.executed_at,
            ignored_at=proposal.ignored_at,
            undone_at=proposal.undone_at,
            initial_parse_snapshot=proposal.initial_parse_snapshot,
            final_confirmed_snapshot=proposal.final_confirmed_snapshot,
            final_field_diff=proposal.final_field_diff,
            quality_status=(
                "available"
                if proposal.initial_parse_snapshot is not None
                else "historical_unavailable"
            ),
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
    def _cash_flow_key(proposal_id: UUID) -> UUID:
        return uuid5(NAMESPACE_URL, f"fiscal-ai-cash-flow:{proposal_id}")

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
