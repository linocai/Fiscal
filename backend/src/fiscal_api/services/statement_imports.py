from __future__ import annotations

import asyncio
import hashlib
import json
import re
from typing import cast
from uuid import UUID

import structlog
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p24_schemas import (
    StatementImportAttemptResponse,
    StatementImportEvidenceResponse,
    StatementImportEvidenceSubmission,
    StatementImportFailure,
    StatementImportRegister,
    StatementImportRegistrationResponse,
    StatementImportResponse,
    StatementImportVersionRequest,
)
from fiscal_api.api.p26_schemas import (
    StatementImportProviderAttemptCreate,
    StatementImportProviderAttemptResponse,
    StatementProviderOutboundPage,
    StatementProviderOutboundRequest,
    StatementProviderOutboundRow,
    StatementProviderResult,
)
from fiscal_api.core.errors import APIError
from fiscal_api.core.time import utc_now
from fiscal_api.db.models.statement_import import (
    StatementImport,
    StatementImportAttempt,
    StatementImportOperation,
    StatementImportPage,
    StatementImportProviderAttempt,
    StatementImportProviderAttemptSnapshot,
    StatementImportProviderSnapshotSourceRef,
    StatementImportRow,
)
from fiscal_api.services.common import (
    acquire_mutation_lock,
    check_version,
    conflict,
    invalid,
    not_found,
)
from fiscal_api.services.statement_import_provider import StatementImportProvider

logger = structlog.get_logger()


_SENSITIVE_LABEL_VALUE = re.compile(
    r"(?ix)(?:\b(?:card(?:\s*(?:number|no\.?))?|account(?:\s*(?:number|no\.?))?|"
    r"customer(?:\s*(?:number|no\.?))?|name|address)\b|卡号|账号|客户号|姓名|地址|持卡人)"
    r"\s*(?:[:\uFF1A#]|\s)\s*(?!\[REDACTED\])[^\n]+"
)
_ACCOUNT_OR_CARD_NUMBER = re.compile(r"(?<!\d)(?:\d[ -]?){9,18}\d(?!\d)")
_PHONE_NUMBER = re.compile(r"(?<!\d)(?:\+?86[- ]?)?1[3-9]\d{9}(?!\d)")
_EMAIL_ADDRESS = re.compile(r"\b[^\s@]+@[^\s@]+\.[^\s@]+\b")
_IDENTITY_NUMBER = re.compile(r"(?<![0-9A-Za-z])\d{17}[0-9Xx](?![0-9A-Za-z])")


class StatementImportService:
    """P24 batch registry only. It never receives PDF bytes or writes the ledger."""

    def __init__(
        self, session: AsyncSession, provider: StatementImportProvider | None = None
    ) -> None:
        self.session = session
        self.provider = provider

    @staticmethod
    def response(item: StatementImport) -> StatementImportResponse:
        return StatementImportResponse.model_validate(item)

    @staticmethod
    def attempt_response(item: StatementImportAttempt) -> StatementImportAttemptResponse:
        return StatementImportAttemptResponse.model_validate(item)

    async def register(
        self, request: StatementImportRegister
    ) -> tuple[StatementImportRegistrationResponse, bool]:
        self._reject_sensitive_texts([request.display_name])
        await acquire_mutation_lock(self.session)
        existing = await self.session.scalar(
            select(StatementImport).where(
                StatementImport.document_sha256 == request.document_sha256
            )
        )
        if existing is not None:
            return StatementImportRegistrationResponse(
                **self.response(existing).model_dump(), duplicate=True
            ), True
        item = StatementImport(
            document_sha256=request.document_sha256,
            byte_size=request.byte_size,
            page_count=request.page_count,
            mime_type=request.mime_type,
            display_name=request.display_name,
        )
        self.session.add(item)
        await self.session.flush()
        self._record_operation(
            item, operation="registered", error_code="statement_import_registered"
        )
        await self.session.commit()
        await logger.ainfo("statement_import_registered", statement_import_id=str(item.id))
        registered = StatementImportRegistrationResponse(
            **self.response(item).model_dump(), duplicate=False
        )
        return registered, False

    async def get(self, statement_import_id: UUID) -> StatementImportResponse:
        return self.response(await self._required(statement_import_id))

    async def start_attempt(
        self, statement_import_id: UUID, request: StatementImportVersionRequest
    ) -> tuple[StatementImportResponse, StatementImportAttemptResponse]:
        await acquire_mutation_lock(self.session)
        item = await self._required(statement_import_id, for_update=True)
        check_version(item.version, request.expected_version)
        if item.status not in {"created", "failed"}:
            conflict(
                "statement_import_attempt_invalid",
                "The import cannot start an attempt in its current state",
            )
        next_number = await self.session.scalar(
            select(func.coalesce(func.max(StatementImportAttempt.attempt_number), 0) + 1).where(
                StatementImportAttempt.statement_import_id == item.id
            )
        )
        assert isinstance(next_number, int)
        attempt = StatementImportAttempt(
            statement_import_id=item.id,
            attempt_number=next_number,
            kind="local_extraction",
            status="started",
        )
        self.session.add(attempt)
        await self.session.flush()
        item.status = "extracting"
        item.latest_attempt_id = attempt.id
        self._touch(item)
        self._record_operation(
            item,
            operation="attempt_started",
            error_code="statement_import_attempt_started",
            attempt_id=attempt.id,
            details={"attempt_number": next_number},
        )
        await self.session.commit()
        await logger.ainfo(
            "statement_import_attempt_started",
            statement_import_id=str(item.id),
            attempt_id=str(attempt.id),
            attempt_number=next_number,
        )
        return self.response(item), self.attempt_response(attempt)

    async def fail_attempt(
        self, statement_import_id: UUID, request: StatementImportFailure
    ) -> StatementImportResponse:
        await acquire_mutation_lock(self.session)
        item = await self._required(statement_import_id, for_update=True)
        check_version(item.version, request.expected_version)
        if item.status not in {"extracting", "parsing"} or item.latest_attempt_id is None:
            conflict("statement_import_failure_invalid", "The import has no active attempt to fail")
        attempt = await self.session.scalar(
            select(StatementImportAttempt)
            .where(StatementImportAttempt.id == item.latest_attempt_id)
            .with_for_update()
        )
        if attempt is None or attempt.status != "started":
            conflict("statement_import_failure_invalid", "The import has no active attempt to fail")
        now = utc_now()
        attempt.status = "failed"
        attempt.error_code = request.error_code
        attempt.error_summary = "The client reported a document processing failure."
        attempt.completed_at = now
        attempt.version += 1
        item.status = "failed"
        self._touch(item)
        self._record_operation(
            item,
            operation="attempt_failed",
            error_code=request.error_code,
            attempt_id=attempt.id,
            details={"attempt_number": attempt.attempt_number},
        )
        await self.session.commit()
        await logger.ainfo(
            "statement_import_attempt_failed",
            statement_import_id=str(item.id),
            attempt_id=str(attempt.id),
            error_code=request.error_code,
        )
        return self.response(item)

    async def submit_evidence(
        self, statement_import_id: UUID, request: StatementImportEvidenceSubmission
    ) -> StatementImportEvidenceResponse:
        """Atomically persist a redacted local package; it has no ledger side effects."""
        self._reject_sensitive_evidence(request)
        evidence_sha256 = self._evidence_sha256(request)
        await acquire_mutation_lock(self.session)
        item = await self._required(statement_import_id, for_update=True)
        attempt = await self.session.scalar(
            select(StatementImportAttempt)
            .where(StatementImportAttempt.id == request.attempt_id)
            .with_for_update()
        )
        if (
            attempt is not None
            and attempt.statement_import_id == item.id
            and attempt.status == "succeeded"
            and item.status == "review_required"
            and attempt.evidence_sha256 == evidence_sha256
        ):
            return self._evidence_response(item, attempt, request, duplicate=True)
        check_version(item.version, request.expected_version)
        if (
            item.status != "extracting"
            or item.latest_attempt_id != request.attempt_id
            or attempt is None
            or attempt.statement_import_id != item.id
            or attempt.status != "started"
        ):
            conflict(
                "statement_import_evidence_invalid", "The import has no matching active attempt"
            )
        page_numbers = [page.page_number for page in request.pages]
        if page_numbers != list(range(1, item.page_count + 1)):
            invalid(
                "statement_import_evidence_pages_invalid",
                "Evidence pages must match the import page count",
            )
        row_numbers = [row.row_number for row in request.rows]
        if len(set(row_numbers)) != len(row_numbers):
            invalid("statement_import_evidence_rows_invalid", "Evidence row numbers must be unique")
        if any(row.page_number not in page_numbers for row in request.rows):
            invalid(
                "statement_import_evidence_rows_invalid",
                "Evidence rows must refer to a submitted page",
            )
        for page in request.pages:
            self.session.add(
                StatementImportPage(
                    statement_import_id=item.id,
                    page_number=page.page_number,
                    source_kind=page.source_kind,
                    evidence_text_masked=page.evidence_text_masked,
                    bounding_boxes=[box.model_dump() for box in page.bounding_boxes],
                )
            )
        for row in request.rows:
            self.session.add(
                StatementImportRow(
                    statement_import_id=item.id,
                    row_number=row.row_number,
                    page_number=row.page_number,
                    evidence_text_masked=row.evidence_text_masked,
                    bounding_box=row.bounding_box.model_dump(),
                )
            )
        now = utc_now()
        attempt.status = "succeeded"
        attempt.evidence_sha256 = evidence_sha256
        attempt.completed_at = now
        attempt.version += 1
        item.status = "review_required"
        self._touch(item)
        self._record_operation(
            item,
            operation="evidence_received",
            error_code="statement_import_evidence_received",
            attempt_id=attempt.id,
            details={
                "attempt_number": attempt.attempt_number,
                "page_count": len(request.pages),
                "row_count": len(request.rows),
            },
        )
        await self.session.commit()
        await logger.ainfo(
            "statement_import_evidence_received",
            statement_import_id=str(item.id),
            attempt_id=str(attempt.id),
            page_count=len(request.pages),
            row_count=len(request.rows),
        )
        return self._evidence_response(item, attempt, request, duplicate=False)

    async def start_provider_attempt(
        self,
        statement_import_id: UUID,
        request: StatementImportProviderAttemptCreate,
        idempotency_key: UUID,
    ) -> tuple[StatementImportProviderAttemptResponse, bool]:
        if self.provider is None:
            raise RuntimeError("statement provider is unavailable")
        provider = self.provider
        request_hash = self._request_hash(request)
        await acquire_mutation_lock(self.session)
        replay = await self.session.scalar(
            select(StatementImportProviderAttempt)
            .where(StatementImportProviderAttempt.idempotency_key == idempotency_key)
            .with_for_update()
        )
        if replay is not None:
            if (
                replay.request_hash != request_hash
                or replay.statement_import_id != statement_import_id
            ):
                conflict(
                    "idempotency_key_reused", "The idempotency key was used for another request"
                )
            item = await self._required(statement_import_id)
            return await self._provider_response(item, replay, replay=True), True
        item = await self._required(statement_import_id, for_update=True)
        check_version(item.version, request.expected_version)
        local = await self.session.scalar(
            select(StatementImportAttempt)
            .where(
                StatementImportAttempt.statement_import_id == item.id,
                StatementImportAttempt.kind == "local_extraction",
                StatementImportAttempt.status == "succeeded",
                StatementImportAttempt.evidence_sha256 == request.evidence_sha256,
            )
            .order_by(StatementImportAttempt.attempt_number.desc())
            .with_for_update()
        )
        if (
            local is None
            or item.status not in {"review_required", "failed"}
        ):
            conflict("statement_provider_evidence_stale", "Current redacted evidence is required")
        outbound = await self._outbound_request(item.id)
        self._validate_authorization(request, outbound, local.evidence_sha256)
        next_number = await self.session.scalar(
            select(func.coalesce(func.max(StatementImportAttempt.attempt_number), 0) + 1).where(
                StatementImportAttempt.statement_import_id == item.id
            )
        )
        assert isinstance(next_number, int)
        attempt = StatementImportAttempt(
            statement_import_id=item.id,
            attempt_number=next_number,
            kind="provider_parse",
            status="started",
            provider=provider.provider_id,
            provider_model=provider.model_id,
            prompt_version=provider.prompt_version,
            schema_version=provider.schema_version,
            evidence_sha256=local.evidence_sha256,
            input_page_count=len(outbound.pages),
        )
        self.session.add(attempt)
        await self.session.flush()
        provider_attempt = StatementImportProviderAttempt(
            statement_import_id=item.id,
            statement_import_attempt_id=attempt.id,
            idempotency_key=idempotency_key,
            request_hash=request_hash,
            evidence_sha256=local.evidence_sha256,
            provider=provider.provider_id,
            provider_model=provider.model_id,
            prompt_version=provider.prompt_version,
            schema_version=provider.schema_version,
        )
        self.session.add(provider_attempt)
        self.session.add_all(
            [
                StatementImportProviderAttemptSnapshot(
                    provider_attempt=provider_attempt,
                    snapshot_kind="authorization",
                    payload=request.authorization.model_dump(mode="json"),
                ),
                StatementImportProviderAttemptSnapshot(
                    provider_attempt=provider_attempt,
                    snapshot_kind="outbound_request",
                    payload=outbound.model_dump(mode="json"),
                ),
            ]
        )
        item.status = "parsing"
        item.latest_attempt_id = attempt.id
        self._touch(item)
        self._record_operation(
            item,
            operation="provider_attempt_started",
            error_code="statement_provider_attempt_started",
            attempt_id=attempt.id,
            details={
                "attempt_number": next_number,
                "page_count": len(outbound.pages),
                "row_count": len(outbound.rows),
            },
        )
        await self.session.commit()
        try:
            result = await provider.parse(outbound)
            self._validate_provider_result(result, outbound)
        except (TimeoutError, ConnectionError):
            return await self._fail_provider_attempt(
                item.id, provider_attempt.id, attempt.id, "statement_provider_unavailable"
            ), False
        except asyncio.CancelledError:
            return await self._fail_provider_attempt(
                item.id, provider_attempt.id, attempt.id, "statement_provider_cancelled"
            ), False
        except APIError as error:
            return await self._fail_provider_attempt(
                item.id,
                provider_attempt.id,
                attempt.id,
                (
                    "statement_provider_unavailable"
                    if error.status_code == 429 or error.status_code >= 500
                    else "statement_provider_invalid_result"
                ),
            ), False
        except Exception:
            return await self._fail_provider_attempt(
                item.id, provider_attempt.id, attempt.id, "statement_provider_invalid_result"
            ), False
        return await self._complete_provider_attempt(
            item.id, provider_attempt.id, attempt.id, result, outbound
        ), False

    async def abandon(
        self, statement_import_id: UUID, request: StatementImportVersionRequest
    ) -> StatementImportResponse:
        await acquire_mutation_lock(self.session)
        item = await self._required(statement_import_id, for_update=True)
        check_version(item.version, request.expected_version)
        if item.status in {"confirmed", "abandoned"}:
            conflict(
                "statement_import_abandon_invalid",
                "The import cannot be abandoned in its current state",
            )
        attempt_id = item.latest_attempt_id
        if attempt_id is not None:
            attempt = await self.session.scalar(
                select(StatementImportAttempt)
                .where(StatementImportAttempt.id == attempt_id)
                .with_for_update()
            )
            if attempt is not None and attempt.status == "started":
                attempt.status = "abandoned"
                attempt.completed_at = utc_now()
                attempt.version += 1
        item.status = "abandoned"
        item.abandoned_at = utc_now()
        self._touch(item)
        self._record_operation(
            item,
            operation="abandoned",
            error_code="statement_import_abandoned",
            attempt_id=attempt_id,
        )
        await self.session.commit()
        await logger.ainfo(
            "statement_import_abandoned",
            statement_import_id=str(item.id),
            attempt_id=str(attempt_id),
        )
        return self.response(item)

    async def _required(
        self, statement_import_id: UUID, *, for_update: bool = False
    ) -> StatementImport:
        statement = select(StatementImport).where(StatementImport.id == statement_import_id)
        if for_update:
            statement = statement.with_for_update()
        item = await self.session.scalar(statement)
        if item is None:
            not_found("statement_import_not_found", "The statement import was not found")
        return item

    def _record_operation(
        self,
        item: StatementImport,
        *,
        operation: str,
        error_code: str,
        attempt_id: UUID | None = None,
        details: dict[str, object] | None = None,
    ) -> None:
        # This whitelist is intentional: display names, evidence, PDF text,
        # identities, and arbitrary client error text are never audit-log data.
        self.session.add(
            StatementImportOperation(
                statement_import_id=item.id,
                attempt_id=attempt_id,
                operation=operation,
                error_code=error_code,
                details=details or {},
            )
        )

    @staticmethod
    def _touch(item: StatementImport) -> None:
        item.version += 1
        item.updated_at = utc_now()

    @staticmethod
    def _evidence_sha256(request: StatementImportEvidenceSubmission) -> str:
        payload = request.model_dump(mode="json", exclude={"expected_version"})
        encoded = json.dumps(
            payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode()
        return hashlib.sha256(encoded).hexdigest()

    @staticmethod
    def _reject_sensitive_evidence(request: StatementImportEvidenceSubmission) -> None:
        texts = [page.evidence_text_masked for page in request.pages]
        texts.extend(row.evidence_text_masked for row in request.rows)
        StatementImportService._reject_sensitive_texts(texts)

    @staticmethod
    def _reject_sensitive_texts(texts: list[str | None]) -> None:
        if any(
            text is not None
            and (_SENSITIVE_LABEL_VALUE.search(text) or _ACCOUNT_OR_CARD_NUMBER.search(text))
            for text in texts
        ):
            invalid(
                "statement_import_evidence_not_redacted",
                "Evidence contains prohibited sensitive fields",
            )

    def _evidence_response(
        self,
        item: StatementImport,
        attempt: StatementImportAttempt,
        request: StatementImportEvidenceSubmission,
        *,
        duplicate: bool,
    ) -> StatementImportEvidenceResponse:
        assert attempt.evidence_sha256 is not None
        return StatementImportEvidenceResponse(
            **self.response(item).model_dump(),
            attempt_id=attempt.id,
            evidence_sha256=attempt.evidence_sha256,
            row_count=len(request.rows),
            duplicate=duplicate,
        )

    async def _outbound_request(
        self, statement_import_id: UUID
    ) -> StatementProviderOutboundRequest:
        pages = list(
            (
                await self.session.scalars(
                    select(StatementImportPage)
                    .where(StatementImportPage.statement_import_id == statement_import_id)
                    .order_by(StatementImportPage.page_number)
                )
            ).all()
        )
        rows = list(
            (
                await self.session.scalars(
                    select(StatementImportRow)
                    .where(StatementImportRow.statement_import_id == statement_import_id)
                    .order_by(StatementImportRow.row_number)
                )
            ).all()
        )
        outbound = StatementProviderOutboundRequest(
            schema_version="statement-provider-v1",
            currency="CNY",
            pages=[
                StatementProviderOutboundPage.model_validate(
                    {
                        "page_number": page.page_number,
                        "source_kind": page.source_kind or "unsupported",
                        "evidence_text_masked": page.evidence_text_masked,
                    }
                )
                for page in pages
            ],
            rows=[
                StatementProviderOutboundRow.model_validate(
                    {
                        "row_number": row.row_number,
                        "page_number": row.page_number,
                        "evidence_text_masked": row.evidence_text_masked,
                        "bounding_box": row.bounding_box,
                    }
                )
                for row in rows
            ],
        )
        self._reject_outbound_sensitive_values(outbound)
        return outbound

    def _validate_authorization(
        self,
        request: StatementImportProviderAttemptCreate,
        outbound: StatementProviderOutboundRequest,
        evidence_sha256: str | None,
    ) -> None:
        if evidence_sha256 is None or request.authorization.evidence_sha256 != evidence_sha256:
            conflict(
                "statement_provider_authorization_stale", "Authorization evidence does not match"
            )
        auth = request.authorization
        assert self.provider is not None
        if (
            request.evidence_sha256 != evidence_sha256
            or auth.page_numbers != [page.page_number for page in outbound.pages]
            or auth.row_count != len(outbound.rows)
            or auth.redaction_count
            != sum((page.evidence_text_masked or "").count("[REDACTED]") for page in outbound.pages)
            or auth.provider != self.provider.provider_id
            or auth.provider_model != self.provider.model_id
            or auth.prompt_version != self.provider.prompt_version
            or auth.schema_version != self.provider.schema_version
        ):
            conflict(
                "statement_provider_authorization_stale",
                "Authorization preview is no longer current",
            )

    def _validate_provider_result(
        self, result: StatementProviderResult, outbound: StatementProviderOutboundRequest
    ) -> None:
        row_text = {row.row_number: row.evidence_text_masked for row in outbound.rows}
        assert self.provider is not None
        if result.schema_version != self.provider.schema_version:
            raise ValueError("schema version")
        for candidate in result.candidates:
            if any(number not in row_text for number in candidate.source_row_numbers):
                raise ValueError("unknown source row")
            evidence = "\n".join(row_text[number] for number in candidate.source_row_numbers)
            if (
                candidate.summary_evidence is not None
                and candidate.summary_evidence not in evidence
            ):
                raise ValueError("unproven summary")
            if candidate.raw_amount is not None and candidate.raw_amount not in evidence:
                raise ValueError("unproven amount")
            if (
                candidate.transaction_date is not None
                and candidate.transaction_date.isoformat() not in evidence
            ):
                raise ValueError("unproven date")
            if (
                candidate.posted_date is not None
                and candidate.posted_date.isoformat() not in evidence
            ):
                raise ValueError("unproven posted date")
            if any(number not in row_text for number in candidate.unparsed_source_row_numbers):
                raise ValueError("unknown unparsed source row")

    def _reject_outbound_sensitive_values(self, outbound: StatementProviderOutboundRequest) -> None:
        values = [page.evidence_text_masked for page in outbound.pages]
        values.extend(row.evidence_text_masked for row in outbound.rows)
        self._reject_sensitive_texts(values)
        if any(
            value is not None
            and (
                _PHONE_NUMBER.search(value)
                or _EMAIL_ADDRESS.search(value)
                or _IDENTITY_NUMBER.search(value)
            )
            for value in values
        ):
            invalid(
                "statement_provider_outbound_not_redacted",
                "Outbound provider evidence contains an unredacted sensitive value",
            )

    @staticmethod
    def _request_hash(request: StatementImportProviderAttemptCreate) -> str:
        encoded = json.dumps(
            request.model_dump(mode="json"),
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        return hashlib.sha256(encoded).hexdigest()

    async def _complete_provider_attempt(
        self,
        statement_import_id: UUID,
        provider_attempt_id: UUID,
        attempt_id: UUID,
        result: StatementProviderResult,
        outbound: StatementProviderOutboundRequest,
    ) -> StatementImportProviderAttemptResponse:
        await acquire_mutation_lock(self.session)
        item = await self._required(statement_import_id, for_update=True)
        attempt = await self.session.scalar(
            select(StatementImportAttempt)
            .where(StatementImportAttempt.id == attempt_id)
            .with_for_update()
        )
        provider_attempt = await self.session.scalar(
            select(StatementImportProviderAttempt)
            .where(StatementImportProviderAttempt.id == provider_attempt_id)
            .with_for_update()
        )
        if attempt is None or provider_attempt is None or attempt.status != "started":
            conflict(
                "statement_provider_attempt_invalid", "The provider attempt is no longer active"
            )
        snapshot = StatementImportProviderAttemptSnapshot(
            provider_attempt_id=provider_attempt.id,
            snapshot_kind="validated_result",
            payload=result.model_dump(mode="json"),
        )
        self.session.add(snapshot)
        await self.session.flush()
        rows = {
            row.row_number: row.id
            for row in (
                await self.session.scalars(
                    select(StatementImportRow).where(
                        StatementImportRow.statement_import_id == item.id
                    )
                )
            ).all()
        }
        self.session.add_all(
            [
                StatementImportProviderSnapshotSourceRef(
                    provider_attempt_snapshot_id=snapshot.id,
                    statement_import_row_id=rows[number],
                    candidate_index=index,
                )
                for index, candidate in enumerate(result.candidates)
                for number in candidate.source_row_numbers
            ]
        )
        attempt.status = "succeeded"
        attempt.completed_at = utc_now()
        attempt.output_token_count = len(result.candidates)
        attempt.version += 1
        item.status = "review_required"
        self._touch(item)
        self._record_operation(
            item,
            operation="provider_attempt_succeeded",
            error_code="statement_provider_attempt_succeeded",
            attempt_id=attempt.id,
            details={
                "attempt_number": attempt.attempt_number,
                "candidate_count": len(result.candidates),
            },
        )
        await self.session.commit()
        return await self._provider_response(item, provider_attempt, replay=False)

    async def _fail_provider_attempt(
        self,
        statement_import_id: UUID,
        provider_attempt_id: UUID,
        attempt_id: UUID,
        error_code: str,
    ) -> StatementImportProviderAttemptResponse:
        await acquire_mutation_lock(self.session)
        item = await self._required(statement_import_id, for_update=True)
        attempt = await self.session.scalar(
            select(StatementImportAttempt)
            .where(StatementImportAttempt.id == attempt_id)
            .with_for_update()
        )
        provider_attempt = await self.session.scalar(
            select(StatementImportProviderAttempt)
            .where(StatementImportProviderAttempt.id == provider_attempt_id)
            .with_for_update()
        )
        if attempt is None or provider_attempt is None:
            raise RuntimeError("provider attempt disappeared")
        attempt.status = "failed"
        attempt.error_code = error_code
        attempt.error_summary = "Statement parsing did not complete."
        attempt.completed_at = utc_now()
        attempt.version += 1
        item.status = "failed"
        self._touch(item)
        self._record_operation(
            item,
            operation="provider_attempt_failed",
            error_code=error_code,
            attempt_id=attempt.id,
            details={"attempt_number": attempt.attempt_number},
        )
        await self.session.commit()
        return await self._provider_response(item, provider_attempt, replay=False)

    async def _provider_response(
        self,
        item: StatementImport,
        provider_attempt: StatementImportProviderAttempt,
        *,
        replay: bool,
    ) -> StatementImportProviderAttemptResponse:
        attempt = await self.session.scalar(
            select(StatementImportAttempt).where(
                StatementImportAttempt.id == provider_attempt.statement_import_attempt_id
            )
        )
        assert attempt is not None
        snapshot = await self.session.scalar(
            select(StatementImportProviderAttemptSnapshot).where(
                StatementImportProviderAttemptSnapshot.provider_attempt_id == provider_attempt.id,
                StatementImportProviderAttemptSnapshot.snapshot_kind == "validated_result",
            )
        )
        raw_candidates: object = snapshot.payload.get("candidates") if snapshot is not None else []
        candidate_count = (
            len(cast(list[object], raw_candidates)) if isinstance(raw_candidates, list) else 0
        )
        return StatementImportProviderAttemptResponse(
            **self.response(item).model_dump(),
            provider_attempt_id=str(provider_attempt.id),
            attempt_id=str(attempt.id),
            provider=provider_attempt.provider,
            provider_model=provider_attempt.provider_model,
            prompt_version=provider_attempt.prompt_version,
            schema_version=provider_attempt.schema_version,
            provider_status=attempt.status,
            candidate_count=candidate_count,
            replay=replay,
        )
