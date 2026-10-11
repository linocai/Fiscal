from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
from datetime import datetime
from typing import Any
from uuid import UUID, uuid5

from pydantic import ValidationError
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.import_batch_schemas import (
    ImportBatchCommitRequest,
    ImportBatchCreate,
    ImportBatchIgnoreRequest,
    ImportBatchPage,
    ImportBatchResponse,
    ImportBatchVersionRequest,
)
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.core.config import Settings
from fiscal_api.core.errors import APIError
from fiscal_api.core.time import ensure_utc, utc_now
from fiscal_api.db.models import (
    ImportBatch,
    ImportBatchSource,
    ImportBatchStatus,
    TransactionSource,
)
from fiscal_api.repositories.import_batches import ImportBatchRepository
from fiscal_api.services.common import (
    acquire_mutation_lock,
    check_version,
    conflict,
    invalid,
    not_found,
)
from fiscal_api.services.transactions import TransactionService


class ImportBatchService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = ImportBatchRepository(session)
        self.transactions = TransactionService(session)

    @staticmethod
    def _request_hash(request: ImportBatchCreate) -> str:
        payload = request.model_dump(mode="json")
        return hashlib.sha256(
            json.dumps(payload, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode()
        ).hexdigest()

    @staticmethod
    def _candidate_payload(candidate: Any) -> dict[str, Any]:
        return candidate.model_dump(mode="json")

    @staticmethod
    def _cursor(batch: ImportBatch) -> str:
        raw = json.dumps(
            {"created_at": batch.created_at.isoformat(), "id": str(batch.id)},
            separators=(",", ":"),
        ).encode()
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    @staticmethod
    def _decode_cursor(value: str | None) -> tuple[datetime | None, UUID | None]:
        if value is None:
            return None, None
        try:
            payload = json.loads(base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)).decode())
            return datetime.fromisoformat(payload["created_at"]), UUID(payload["id"])
        except (
            binascii.Error,
            KeyError,
            TypeError,
            ValueError,
            UnicodeDecodeError,
            json.JSONDecodeError,
        ):
            invalid("invalid_cursor", "The batch cursor is invalid")

    @staticmethod
    def _response(batch: ImportBatch) -> ImportBatchResponse:
        return ImportBatchResponse(
            id=batch.id,
            source=ImportBatchSource(batch.source),
            original_content_sha256=batch.original_content_sha256,
            status=ImportBatchStatus(batch.status),
            candidates=batch.candidates,
            validation_errors=batch.validation_errors,
            transaction_receipts=batch.transaction_receipts,
            ignored_reason=batch.ignored_reason,
            version=batch.version,
            created_at=batch.created_at,
            updated_at=batch.updated_at,
            validated_at=batch.validated_at,
            committed_at=batch.committed_at,
            ignored_at=batch.ignored_at,
        )

    async def create(self, request: ImportBatchCreate) -> tuple[ImportBatchResponse, bool]:
        request_hash = self._request_hash(request)
        await acquire_mutation_lock(self.session)
        existing = await self.repository.by_idempotency_key(
            request.idempotency_key, for_update=True
        )
        if existing is not None:
            if existing.request_hash != request_hash:
                conflict(
                    "idempotency_key_reused",
                    "The idempotency key was already used for a different batch",
                )
            await self.session.commit()
            return self._response(existing), True
        batch = ImportBatch(
            source=request.source,
            original_content_sha256=request.original_content_sha256,
            idempotency_key=request.idempotency_key,
            request_hash=request_hash,
            candidates=[self._candidate_payload(candidate) for candidate in request.candidates],
            validation_errors=[],
            transaction_receipts=[],
            status=ImportBatchStatus.PENDING,
        )
        self.repository.add(batch)
        await self.session.commit()
        return self._response(batch), False

    async def get(self, batch_id: UUID) -> ImportBatchResponse:
        batch = await self.repository.by_id(batch_id)
        if batch is None:
            not_found("import_batch_not_found", "The import batch does not exist")
        return self._response(batch)

    async def list(
        self, *, status: ImportBatchStatus | None, cursor: str | None, limit: int
    ) -> ImportBatchPage:
        cursor_time, cursor_id = self._decode_cursor(cursor)
        values = await self.repository.page(
            status=status.value if status is not None else None,
            cursor_time=cursor_time,
            cursor_id=cursor_id,
            limit=limit,
        )
        has_more = len(values) > limit
        page = values[:limit]
        return ImportBatchPage(
            items=[self._response(value) for value in page],
            next_cursor=self._cursor(page[-1]) if has_more and page else None,
        )

    @staticmethod
    def _draft(candidate: dict[str, Any]) -> TransactionDraft:
        return TransactionDraft.model_validate(
            {
                key: value
                for key, value in candidate.items()
                if key
                in {
                    "kind",
                    "amount_minor",
                    "occurred_at",
                    "title",
                    "note",
                    "account_id",
                    "category_id",
                    "destination_account_id",
                    "credit_cycle_id",
                }
            }
        )

    async def _validate_candidate(self, candidate: dict[str, Any]) -> dict[str, Any] | None:
        try:
            draft = self._draft(candidate)
            duplicate = await self.transactions.repository.possible_duplicate(
                kind=draft.kind,
                amount_minor=draft.amount_minor,
                occurred_at=ensure_utc(draft.occurred_at),
                title=draft.title,
                account_id=draft.account_id,
                category_id=draft.category_id,
            )
            if duplicate is not None:
                return {
                    "client_id": candidate.get("client_id"),
                    "code": "duplicate",
                    "message": "A matching ledger transaction already exists",
                    "transaction_id": str(duplicate.id),
                }
            nested = await self.session.begin_nested()
            try:
                await self.transactions.validate_draft(draft)
            finally:
                await nested.rollback()
        except APIError as error:
            return {
                "client_id": candidate.get("client_id"),
                "code": error.code,
                "message": error.message,
            }
        except (ValidationError, ValueError) as error:
            return {
                "client_id": candidate.get("client_id"),
                "code": "invalid_candidate",
                "message": str(error),
            }
        except Exception:
            return {
                "client_id": candidate.get("client_id"),
                "code": "candidate_validation_failed",
                "message": "The candidate could not be validated",
            }
        return None

    async def validate(
        self, batch_id: UUID, request: ImportBatchVersionRequest
    ) -> ImportBatchResponse:
        await acquire_mutation_lock(self.session)
        batch = await self.repository.by_id(batch_id, for_update=True)
        if batch is None:
            not_found("import_batch_not_found", "The import batch does not exist")
        check_version(
            batch.version,
            request.expected_version,
            resource_type="import_batch",
            resource_id=str(batch.id),
        )
        if batch.status not in {ImportBatchStatus.PENDING.value, ImportBatchStatus.VALIDATED.value}:
            conflict("import_batch_not_validatable", "Only pending batches can be validated")
        errors = [
            error
            for candidate in batch.candidates
            if (error := await self._validate_candidate(candidate))
        ]
        batch.validation_errors = errors
        batch.status = (
            ImportBatchStatus.VALIDATED.value if not errors else ImportBatchStatus.PENDING.value
        )
        batch.validated_at = utc_now() if not errors else None
        batch.version += 1
        batch.updated_at = utc_now()
        await self.session.commit()
        return self._response(batch)

    def _verify_confirmation(self, token: str, *, batch_id: UUID, expected_version: int) -> None:
        secret = self.settings.import_confirmation_secret
        if secret is None or len(secret.get_secret_value().encode()) < 32:
            raise APIError(
                status_code=503,
                code="confirmation_unconfigured",
                message="Batch confirmation is not configured",
            )
        parts = token.split(".")
        if len(parts) != 4 or parts[0] != "v1" or parts[1] != str(batch_id):
            conflict("invalid_confirmation", "Confirmation credential is invalid or expired")
        try:
            version = int(parts[2])
            supplied = base64.urlsafe_b64decode(parts[3] + "=" * (-len(parts[3]) % 4))
        except (binascii.Error, TypeError, ValueError):
            conflict("invalid_confirmation", "Confirmation credential is invalid or expired")
        if version != expected_version:
            conflict("invalid_confirmation", "Confirmation credential is invalid or expired")
        body = f"v1.{batch_id}.{version}"
        expected = hmac.new(
            secret.get_secret_value().encode(), body.encode(), hashlib.sha256
        ).digest()
        if not hmac.compare_digest(supplied, expected):
            conflict("invalid_confirmation", "Confirmation credential is invalid or expired")

    async def commit(
        self, batch_id: UUID, request: ImportBatchCommitRequest
    ) -> ImportBatchResponse:
        await acquire_mutation_lock(self.session)
        batch = await self.repository.by_id(batch_id, for_update=True)
        if batch is None:
            not_found("import_batch_not_found", "The import batch does not exist")
        if batch.status == ImportBatchStatus.COMMITTED.value:
            return self._response(batch)
        check_version(
            batch.version,
            request.expected_version,
            resource_type="import_batch",
            resource_id=str(batch.id),
        )
        if batch.status != ImportBatchStatus.VALIDATED.value:
            conflict("import_batch_not_validated", "Validate the batch before committing it")
        self._verify_confirmation(
            request.confirmation_token,
            batch_id=batch.id,
            expected_version=request.expected_version,
        )
        receipts: list[dict[str, Any]] = []
        source = (
            TransactionSource.OCR
            if batch.source == ImportBatchSource.OCR.value
            else TransactionSource.AI_TEXT
        )
        try:
            for candidate in batch.candidates:
                draft = self._draft(candidate)
                transaction = await self.transactions.create_ai(
                    draft,
                    uuid5(batch.id, str(candidate["client_id"])),
                    source,
                    commit=False,
                )
                receipts.append(
                    {
                        "client_id": candidate["client_id"],
                        "transaction": transaction.model_dump(mode="json"),
                    }
                )
            batch.transaction_receipts = receipts
            batch.validation_errors = []
            batch.status = ImportBatchStatus.COMMITTED.value
            batch.committed_at = utc_now()
            batch.version += 1
            batch.updated_at = utc_now()
            await self.session.commit()
        except Exception:
            await self.session.rollback()
            raise
        return self._response(batch)

    async def ignore(
        self, batch_id: UUID, request: ImportBatchIgnoreRequest
    ) -> ImportBatchResponse:
        await acquire_mutation_lock(self.session)
        batch = await self.repository.by_id(batch_id, for_update=True)
        if batch is None:
            not_found("import_batch_not_found", "The import batch does not exist")
        check_version(
            batch.version,
            request.expected_version,
            resource_type="import_batch",
            resource_id=str(batch.id),
        )
        if batch.status not in {ImportBatchStatus.PENDING.value, ImportBatchStatus.VALIDATED.value}:
            conflict(
                "import_batch_not_ignorable", "Only pending or validated batches can be ignored"
            )
        batch.status = ImportBatchStatus.IGNORED.value
        batch.ignored_reason = request.reason
        batch.ignored_at = utc_now()
        batch.version += 1
        batch.updated_at = utc_now()
        await self.session.commit()
        return self._response(batch)
