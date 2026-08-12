from __future__ import annotations

from uuid import UUID

import structlog
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p24_schemas import (
    StatementImportAttemptResponse,
    StatementImportFailure,
    StatementImportRegister,
    StatementImportRegistrationResponse,
    StatementImportResponse,
    StatementImportVersionRequest,
)
from fiscal_api.core.time import utc_now
from fiscal_api.db.models.statement_import import (
    StatementImport,
    StatementImportAttempt,
    StatementImportOperation,
)
from fiscal_api.services.common import (
    acquire_mutation_lock,
    check_version,
    conflict,
    not_found,
)

logger = structlog.get_logger()


class StatementImportService:
    """P24 batch registry only. It never receives PDF bytes or writes the ledger."""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    @staticmethod
    def response(item: StatementImport) -> StatementImportResponse:
        return StatementImportResponse.model_validate(item)

    @staticmethod
    def attempt_response(item: StatementImportAttempt) -> StatementImportAttemptResponse:
        return StatementImportAttemptResponse.model_validate(item)

    async def register(
        self, request: StatementImportRegister
    ) -> tuple[StatementImportRegistrationResponse, bool]:
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
