from __future__ import annotations

from decimal import Decimal
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p26_schemas import StatementProviderResult
from fiscal_api.api.p27_schemas import (
    StatementImportDraftResolutionPut,
    StatementImportDraftResolutionResponse,
    StatementImportReviewCandidateResponse,
    StatementImportReviewResponse,
    StatementImportValidationCheckResponse,
    StatementImportValidationRunCreate,
)
from fiscal_api.db.models.ledger import LedgerTransaction, Posting
from fiscal_api.db.models.statement_import import (
    StatementImport,
    StatementImportProviderAttempt,
    StatementImportProviderAttemptSnapshot,
    StatementImportProviderSnapshotSourceRef,
    StatementImportRow,
)
from fiscal_api.db.models.statement_import_review import (
    StatementImportDraftResolution,
    StatementImportReviewCandidate,
    StatementImportValidationCheck,
    StatementImportValidationRun,
)
from fiscal_api.services.common import acquire_mutation_lock, check_version, conflict, not_found

ALGORITHM_VERSION = "statement-validation-v1"


class StatementImportReviewService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def start_run(
        self, batch_id: UUID, request: StatementImportValidationRunCreate
    ) -> StatementImportReviewResponse:
        await acquire_mutation_lock(self.session)
        batch = await self._batch(batch_id, lock=True)
        check_version(batch.version, request.expected_batch_version)
        if batch.status != "review_required":
            conflict("statement_import_review_invalid", "The import is not ready for review")
        snapshot, provider = await self._snapshot(batch_id, request.provider_snapshot_id)
        existing = await self.session.scalar(
            select(StatementImportValidationRun).where(
                StatementImportValidationRun.provider_snapshot_id == snapshot.id,
                StatementImportValidationRun.evidence_sha256 == provider.evidence_sha256,
                StatementImportValidationRun.algorithm_version == ALGORITHM_VERSION,
            )
        )
        if existing is not None:
            return await self._review(batch, existing, replay=True)
        result = StatementProviderResult.model_validate(snapshot.payload)
        refs = list(
            (
                await self.session.scalars(
                    select(StatementImportProviderSnapshotSourceRef)
                    .where(
                        StatementImportProviderSnapshotSourceRef.provider_attempt_snapshot_id
                        == snapshot.id
                    )
                    .order_by(StatementImportProviderSnapshotSourceRef.candidate_index)
                )
            ).all()
        )
        run = StatementImportValidationRun(
            statement_import_id=batch.id,
            provider_snapshot_id=snapshot.id,
            evidence_sha256=provider.evidence_sha256,
            algorithm_version=ALGORITHM_VERSION,
            batch_version=batch.version,
        )
        self.session.add(run)
        await self.session.flush()
        row_ids = [str(ref.statement_import_row_id) for ref in refs]
        self.session.add_all(self._checks(run.id, batch, refs, result, row_ids))
        await self._candidates(run.id, refs, result)
        batch.version += 1
        await self.session.commit()
        return await self._review(batch, run, replay=False)

    async def get_review(self, batch_id: UUID) -> StatementImportReviewResponse:
        batch = await self._batch(batch_id)
        run = await self.session.scalar(
            select(StatementImportValidationRun)
            .where(StatementImportValidationRun.statement_import_id == batch.id)
            .order_by(StatementImportValidationRun.created_at.desc())
            .limit(1)
        )
        if run is None:
            not_found("statement_import_review_not_found", "No validation run exists")
        return await self._review(batch, run, replay=False)

    async def put_draft(
        self, batch_id: UUID, row_id: UUID, request: StatementImportDraftResolutionPut
    ) -> StatementImportReviewResponse:
        await acquire_mutation_lock(self.session)
        batch = await self._batch(batch_id, lock=True)
        check_version(batch.version, request.expected_batch_version)
        if batch.status != "review_required":
            conflict("statement_import_review_invalid", "The import is not ready for review")
        row = await self.session.scalar(
            select(StatementImportRow)
            .where(
                StatementImportRow.id == row_id, StatementImportRow.statement_import_id == batch.id
            )
            .with_for_update()
        )
        if row is None:
            not_found("statement_import_row_not_found", "Statement import row was not found")
        check_version(row.version, request.expected_row_version)
        run = await self.session.scalar(
            select(StatementImportValidationRun)
            .where(StatementImportValidationRun.statement_import_id == batch.id)
            .order_by(StatementImportValidationRun.created_at.desc())
            .limit(1)
        )
        if run is None:
            not_found("statement_import_review_not_found", "No validation run exists")
        draft = await self.session.scalar(
            select(StatementImportDraftResolution)
            .where(
                StatementImportDraftResolution.validation_run_id == run.id,
                StatementImportDraftResolution.statement_import_row_id == row.id,
            )
            .with_for_update()
        )
        current = 0 if draft is None else draft.version
        if request.expected_resolution_version != current:
            conflict(
                "statement_import_resolution_version_conflict", "Draft resolution version is stale"
            )
        await self._validate_draft(request, run.id, row.id)
        if draft is not None and self._same(draft, request):
            return await self._review(batch, run, replay=True)
        if draft is None:
            draft = StatementImportDraftResolution(
                validation_run_id=run.id,
                statement_import_row_id=row.id,
                resolution=request.resolution,
                matched_transaction_id=request.matched_transaction_id,
                ignored_reason=request.ignored_reason,
            )
            self.session.add(draft)
        else:
            draft.resolution, draft.matched_transaction_id, draft.ignored_reason = (
                request.resolution,
                request.matched_transaction_id,
                request.ignored_reason,
            )
            draft.version += 1
        batch.version += 1
        await self.session.commit()
        return await self._review(batch, run, replay=False)

    async def _batch(self, batch_id: UUID, lock: bool = False) -> StatementImport:
        query = select(StatementImport).where(StatementImport.id == batch_id)
        if lock:
            query = query.with_for_update()
        batch = await self.session.scalar(query)
        if batch is None:
            not_found("statement_import_not_found", "Statement import was not found")
        return batch

    async def _snapshot(
        self, batch_id: UUID, snapshot_id: UUID
    ) -> tuple[StatementImportProviderAttemptSnapshot, StatementImportProviderAttempt]:
        snapshot = await self.session.scalar(
            select(StatementImportProviderAttemptSnapshot).where(
                StatementImportProviderAttemptSnapshot.id == snapshot_id,
                StatementImportProviderAttemptSnapshot.snapshot_kind == "validated_result",
            )
        )
        if snapshot is None:
            conflict(
                "statement_import_snapshot_invalid",
                "The provider snapshot is not a validated result",
            )
        provider = await self.session.scalar(
            select(StatementImportProviderAttempt).where(
                StatementImportProviderAttempt.id == snapshot.provider_attempt_id,
                StatementImportProviderAttempt.statement_import_id == batch_id,
            )
        )
        if provider is None:
            conflict(
                "statement_import_snapshot_invalid",
                "The provider snapshot belongs to another import",
            )
        return snapshot, provider

    def _checks(
        self,
        run_id: UUID,
        batch: StatementImport,
        refs: list[StatementImportProviderSnapshotSourceRef],
        result: StatementProviderResult,
        row_ids: list[str],
    ) -> list[StatementImportValidationCheck]:
        candidate_dates = [candidate.transaction_date for candidate in result.candidates]
        date_status = (
            "unavailable"
            if batch.statement_period_start is None
            or batch.statement_period_end is None
            or any(value is None for value in candidate_dates)
            else (
                "passed"
                if all(
                    batch.statement_period_start <= value <= batch.statement_period_end
                    for value in candidate_dates
                    if value is not None
                )
                else "failed"
            )
        )
        sequence = [ref.candidate_index for ref in refs]
        row_status = "passed" if sequence == sorted(sequence) else "failed"
        return [
            StatementImportValidationCheck(
                validation_run_id=run_id,
                check_kind="page_sequence",
                status="passed" if batch.page_count > 0 else "unavailable",
                evidence_row_ids=row_ids,
            ),
            StatementImportValidationCheck(
                validation_run_id=run_id,
                check_kind="row_sequence",
                status=row_status,
                evidence_row_ids=row_ids,
            ),
            StatementImportValidationCheck(
                validation_run_id=run_id,
                check_kind="date_window",
                status=date_status,
                evidence_row_ids=row_ids,
            ),
            StatementImportValidationCheck(
                validation_run_id=run_id,
                check_kind="document_formula",
                status="unavailable",
                evidence_row_ids=row_ids,
            ),
            StatementImportValidationCheck(
                validation_run_id=run_id,
                check_kind="row_balance",
                status="unavailable",
                evidence_row_ids=row_ids,
            ),
        ]

    async def _candidates(
        self,
        run_id: UUID,
        refs: list[StatementImportProviderSnapshotSourceRef],
        result: StatementProviderResult,
    ) -> None:
        by_index = {index: candidate for index, candidate in enumerate(result.candidates)}
        records: list[StatementImportReviewCandidate] = []
        transactions = list((await self.session.scalars(select(LedgerTransaction))).all())
        posting_amounts = {
            transaction.id: [
                abs(posting.amount_minor)
                for posting in (
                    await self.session.scalars(
                        select(Posting).where(Posting.transaction_id == transaction.id)
                    )
                ).all()
            ]
            for transaction in transactions
        }
        for ref in refs:
            candidate = by_index.get(ref.candidate_index)
            if candidate is None:
                continue
            amount = self._minor(candidate.raw_amount)
            records.append(
                StatementImportReviewCandidate(
                    validation_run_id=run_id,
                    statement_import_row_id=ref.statement_import_row_id,
                    candidate_kind="provider_candidate",
                    provider_candidate_index=ref.candidate_index,
                    transaction_date=candidate.transaction_date,
                    amount_minor=amount,
                )
            )
            if candidate.transaction_date is not None and amount is not None:
                for transaction in transactions:
                    if (
                        transaction.occurred_at.date() == candidate.transaction_date
                        and amount in posting_amounts[transaction.id]
                    ):
                        records.append(
                            StatementImportReviewCandidate(
                                validation_run_id=run_id,
                                statement_import_row_id=ref.statement_import_row_id,
                                candidate_kind="existing_transaction",
                                provider_candidate_index=ref.candidate_index,
                                transaction_id=transaction.id,
                                transaction_date=candidate.transaction_date,
                                amount_minor=amount,
                            )
                        )
        self.session.add_all(records)

    async def _validate_draft(
        self, request: StatementImportDraftResolutionPut, run_id: UUID, row_id: UUID
    ) -> None:
        if request.resolution == "match_existing":
            if request.matched_transaction_id is None:
                conflict(
                    "statement_import_resolution_invalid", "A matching transaction is required"
                )
            matched = await self.session.scalar(
                select(StatementImportReviewCandidate.id).where(
                    StatementImportReviewCandidate.validation_run_id == run_id,
                    StatementImportReviewCandidate.statement_import_row_id == row_id,
                    StatementImportReviewCandidate.candidate_kind == "existing_transaction",
                    StatementImportReviewCandidate.transaction_id == request.matched_transaction_id,
                )
            )
            if matched is None:
                conflict(
                    "statement_import_resolution_invalid",
                    "The transaction is not a conservative review candidate",
                )
        elif request.matched_transaction_id is not None:
            conflict("statement_import_resolution_invalid", "The draft has incompatible fields")
        if request.resolution != "ignore_intentional" and request.ignored_reason is not None:
            conflict("statement_import_resolution_invalid", "The draft has incompatible fields")
        if request.resolution == "ignore_intentional" and request.ignored_reason is None:
            conflict(
                "statement_import_resolution_invalid", "An intentional ignore reason is required"
            )

    @staticmethod
    def _same(
        draft: StatementImportDraftResolution, request: StatementImportDraftResolutionPut
    ) -> bool:
        return (draft.resolution, draft.matched_transaction_id, draft.ignored_reason) == (
            request.resolution,
            request.matched_transaction_id,
            request.ignored_reason,
        )

    @staticmethod
    def _minor(raw_amount: str | None) -> int | None:
        return None if raw_amount is None else int(Decimal(raw_amount) * 100)

    async def _review(
        self, batch: StatementImport, run: StatementImportValidationRun, replay: bool
    ) -> StatementImportReviewResponse:
        checks = list(
            (
                await self.session.scalars(
                    select(StatementImportValidationCheck)
                    .where(StatementImportValidationCheck.validation_run_id == run.id)
                    .order_by(StatementImportValidationCheck.check_kind)
                )
            ).all()
        )
        candidates = list(
            (
                await self.session.scalars(
                    select(StatementImportReviewCandidate)
                    .where(StatementImportReviewCandidate.validation_run_id == run.id)
                    .order_by(StatementImportReviewCandidate.created_at)
                )
            ).all()
        )
        drafts = list(
            (
                await self.session.scalars(
                    select(StatementImportDraftResolution)
                    .where(StatementImportDraftResolution.validation_run_id == run.id)
                    .order_by(StatementImportDraftResolution.created_at)
                )
            ).all()
        )
        return StatementImportReviewResponse(
            batch_id=batch.id,
            batch_version=batch.version,
            status="review_required",
            validation_run_id=run.id,
            provider_snapshot_id=run.provider_snapshot_id,
            checks=[
                StatementImportValidationCheckResponse.model_validate(
                    {
                        "check_kind": check.check_kind,
                        "status": check.status,
                        "evidence_row_ids": check.evidence_row_ids,
                    }
                )
                for check in checks
            ],
            candidates=[
                StatementImportReviewCandidateResponse.model_validate(
                    {
                        "id": item.id,
                        "statement_import_row_id": item.statement_import_row_id,
                        "candidate_kind": item.candidate_kind,
                        "provider_candidate_index": item.provider_candidate_index,
                        "transaction_id": item.transaction_id,
                        "transaction_date": item.transaction_date,
                        "amount_minor": item.amount_minor,
                    }
                )
                for item in candidates
            ],
            drafts=[
                StatementImportDraftResolutionResponse.model_validate(
                    {
                        "id": item.id,
                        "statement_import_row_id": item.statement_import_row_id,
                        "resolution": item.resolution,
                        "matched_transaction_id": item.matched_transaction_id,
                        "ignored_reason": item.ignored_reason,
                        "version": item.version,
                    }
                )
                for item in drafts
            ],
            replay=replay,
        )
