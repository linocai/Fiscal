from __future__ import annotations

import base64
import hashlib
import json
from datetime import date, datetime
from uuid import UUID, uuid4

from sqlalchemy import delete, func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p6_schemas import (
    ReimbursementAllocationResponse,
    ReimbursementCancelPreview,
    ReimbursementClaimDraft,
    ReimbursementClaimPage,
    ReimbursementClaimPreview,
    ReimbursementClaimReplace,
    ReimbursementClaimResponse,
    ReimbursementEligibility,
    ReimbursementExpenseOption,
    ReimbursementPartyResponse,
    ReimbursementReceiptAllocationResponse,
    ReimbursementReceiptDraft,
    ReimbursementReceiptPage,
    ReimbursementReceiptPreview,
    ReimbursementReceiptReplace,
    ReimbursementReceiptResponse,
    ReimbursementSummary,
)
from fiscal_api.core.time import BUSINESS_TIMEZONE, ensure_utc, utc_now
from fiscal_api.db.models import (
    Account,
    AccountKind,
    LedgerTransaction,
    Posting,
    PostingRole,
    ReimbursementAllocation,
    ReimbursementClaim,
    ReimbursementClaimRevision,
    ReimbursementClaimStatus,
    ReimbursementOperation,
    ReimbursementParty,
    ReimbursementReceipt,
    ReimbursementReceiptAllocation,
    ReimbursementReceiptRevision,
    RevisionEvent,
    TransactionKind,
    TransactionRevision,
)
from fiscal_api.repositories.reimbursements import ReimbursementRepository
from fiscal_api.repositories.transactions import TransactionRepository
from fiscal_api.services.common import (
    acquire_mutation_lock,
    check_version,
    checked_int64,
    conflict,
    invalid,
    not_found,
)
from fiscal_api.services.transactions import TransactionService


async def ensure_reimbursement_capacity(
    session: AsyncSession, transaction_id: UUID, proposed_capacity_minor: int
) -> None:
    allocated = await ReimbursementRepository(session).allocated_for_expense(transaction_id)
    if allocated > proposed_capacity_minor:
        conflict(
            "reimbursement_claim_in_use",
            "The installment change would reduce principal below reimbursement allocations",
        )


class ReimbursementService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = ReimbursementRepository(session)
        self.transactions = TransactionRepository(session)
        self.transaction_service = TransactionService(session)

    async def create(
        self, draft: ReimbursementClaimDraft, key: UUID, *, commit: bool = True
    ) -> ReimbursementClaimResponse:
        await acquire_mutation_lock(self.session)
        request_hash = self._hash(draft)
        existing = await self.repository.claim_for_key(key)
        if existing is not None:
            if existing.create_request_hash != request_hash:
                conflict("idempotency_key_reused", "The idempotency key was already used")
            snapshot = await self.session.scalar(
                select(ReimbursementClaimRevision.snapshot).where(
                    ReimbursementClaimRevision.claim_id == existing.id,
                    ReimbursementClaimRevision.version == 1,
                )
            )
            if snapshot is None:
                raise RuntimeError("created reimbursement snapshot missing")
            return ReimbursementClaimResponse.model_validate(snapshot)
        claim = ReimbursementClaim(
            title=draft.title,
            note=draft.note,
            create_idempotency_key=key,
            create_request_hash=request_hash,
            parties=[],
            allocations=[],
            receipts=[],
        )
        self.session.add(claim)
        await self.session.flush()
        await self._replace_matrix(claim, draft, creating=True)
        await self.session.flush()
        await self._refresh_claim(claim)
        response = await self.response(claim)
        self._claim_revision(claim, "created", response)
        if commit:
            await self.session.commit()
        else:
            await self.session.flush()
        return response

    async def get(self, claim_id: UUID) -> ReimbursementClaimResponse:
        return await self.response(await self._claim(claim_id))

    async def list(
        self,
        *,
        cursor: str | None,
        limit: int,
        status: ReimbursementClaimStatus | None,
        query: str | None,
        expense_transaction_id: UUID | None,
        include_archived: bool,
        include_voided: bool,
    ) -> ReimbursementClaimPage:
        cursor_time, cursor_id = self._decode_cursor(cursor)
        rows = await self.repository.claims(
            limit=limit,
            status=status.value if status is not None else None,
            query=query.strip() if query and query.strip() else None,
            expense_transaction_id=expense_transaction_id,
            include_archived=include_archived,
            include_voided=include_voided,
            cursor_time=cursor_time,
            cursor_id=cursor_id,
        )
        page = rows[:limit]
        return ReimbursementClaimPage(
            items=[await self.response(item) for item in page],
            next_cursor=self._encode_cursor(page[-1].created_at, page[-1].id)
            if len(rows) > limit and page
            else None,
        )

    async def preview(
        self, claim_id: UUID, draft: ReimbursementClaimReplace
    ) -> ReimbursementClaimPreview:
        claim = await self._claim(claim_id)
        check_version(claim.version, draft.expected_version)
        current = await self.response(claim)
        # Validate exact proposed matrix without mutating by computing eligibility and locks.
        await self._validate_draft(claim, draft, creating=False)
        proposed_total = sum(a.amount_minor for p in draft.parties for a in p.allocations)
        received_map = await self.repository.active_received(claim.id)
        transactions = await self.repository.transactions(
            {a.transaction_id for p in draft.parties for a in p.allocations}
        )
        proposed_parties: list[ReimbursementPartyResponse] = []
        allocation_position = 0
        for party_position, party_draft in enumerate(draft.parties):
            party_id = party_draft.id or uuid4()
            proposed_allocations: list[ReimbursementAllocationResponse] = []
            for allocation_draft in party_draft.allocations:
                allocation_id = allocation_draft.id or uuid4()
                received = received_map.get(allocation_id, 0)
                expense = transactions[allocation_draft.transaction_id]
                proposed_allocations.append(
                    ReimbursementAllocationResponse(
                        id=allocation_id,
                        transaction_id=allocation_draft.transaction_id,
                        expense_title=expense.title,
                        expense_amount_minor=abs(expense.postings[0].amount_minor),
                        amount_minor=allocation_draft.amount_minor,
                        received_minor=received,
                        outstanding_minor=(
                            0
                            if claim.cancelled_at is not None
                            else allocation_draft.amount_minor - received
                        ),
                        locked=received > 0,
                        position=allocation_position,
                    )
                )
                allocation_position += 1
            claimed = sum(item.amount_minor for item in proposed_allocations)
            received = sum(item.received_minor for item in proposed_allocations)
            party_status = (
                "cancelled"
                if claim.cancelled_at is not None and received == 0
                else "partially_received_cancelled"
                if claim.cancelled_at is not None
                else "received"
                if received == claimed
                else "partial_received"
                if received
                else "pending"
            )
            proposed_parties.append(
                ReimbursementPartyResponse(
                    id=party_id,
                    name=party_draft.name,
                    expected_date=party_draft.expected_date,
                    note=party_draft.note,
                    claimed_minor=claimed,
                    received_minor=received,
                    outstanding_minor=(0 if claim.cancelled_at is not None else claimed - received),
                    status=party_status,
                    position=party_position,
                    allocations=proposed_allocations,
                )
            )
        proposed_received = sum(item.received_minor for item in proposed_parties)
        proposed_status = (
            ReimbursementClaimStatus.CANCELLED
            if claim.cancelled_at is not None and proposed_received == 0
            else ReimbursementClaimStatus.PARTIALLY_RECEIVED_CANCELLED
            if claim.cancelled_at is not None
            else ReimbursementClaimStatus.RECEIVED
            if proposed_received == proposed_total
            else ReimbursementClaimStatus.PARTIAL_RECEIVED
            if proposed_received
            else ReimbursementClaimStatus.PENDING
            if claim.submitted_at is not None
            else ReimbursementClaimStatus.DRAFT
        )
        proposed = current.model_copy(
            update={
                "title": draft.title,
                "note": draft.note,
                "total_claimed_minor": proposed_total,
                "outstanding_minor": proposed_total - current.received_minor,
                "party_count": len(draft.parties),
                "parties": proposed_parties,
                "status": proposed_status,
                "expense_count": len(
                    {a.transaction_id for p in draft.parties for a in p.allocations}
                ),
            }
        )
        return ReimbursementClaimPreview(
            current=current,
            proposed=proposed,
            released_minor=max(current.total_claimed_minor - proposed_total, 0),
            newly_claimed_minor=max(proposed_total - current.total_claimed_minor, 0),
            warnings=[],
        )

    async def update(
        self, claim_id: UUID, draft: ReimbursementClaimReplace
    ) -> ReimbursementClaimResponse:
        await acquire_mutation_lock(self.session)
        claim = await self._claim(claim_id, for_update=True)
        self._mutable(claim)
        check_version(claim.version, draft.expected_version)
        if claim.cancelled_at is not None:
            # Matrix is immutable while cancelled; presentation fields remain correctable.
            current_ids = {
                (a.party_id, a.transaction_id, a.amount_minor) for a in claim.allocations
            }
            proposed_ids = {
                (p.id, a.transaction_id, a.amount_minor)
                for p in draft.parties
                for a in p.allocations
            }
            if current_ids != proposed_ids:
                conflict(
                    "reimbursement_claim_cancelled", "Reopen the claim before changing its matrix"
                )
        claim.title, claim.note = draft.title, draft.note
        await self._replace_matrix(claim, draft, creating=False)
        claim.version += 1
        claim.updated_at = utc_now()
        await self.session.flush()
        await self._refresh_claim(claim)
        response = await self.response(claim)
        self._claim_revision(claim, "updated", response)
        await self.session.commit()
        return response

    async def lifecycle(
        self, claim_id: UUID, expected: int, action: str
    ) -> ReimbursementClaimResponse:
        await acquire_mutation_lock(self.session)
        claim = await self._claim(claim_id, for_update=True)
        check_version(claim.version, expected)
        now = utc_now()
        received = sum((await self.repository.active_received(claim.id)).values())
        if action == "submit":
            self._mutable(claim)
            if claim.cancelled_at is not None or claim.submitted_at is not None:
                conflict("reimbursement_invalid_status_transition", "The claim cannot be submitted")
            claim.submitted_at = now
        elif action == "retract_submission":
            self._mutable(claim)
            if claim.submitted_at is None or received:
                conflict(
                    "reimbursement_invalid_status_transition",
                    "Only an unpaid submitted claim can be retracted",
                )
            claim.submitted_at = None
        elif action == "cancel_outstanding":
            self._mutable(claim)
            total = sum(a.amount_minor for a in claim.allocations)
            if claim.submitted_at is None or claim.cancelled_at is not None or received >= total:
                conflict(
                    "reimbursement_invalid_status_transition",
                    "The claim has no cancellable outstanding amount",
                )
            claim.cancelled_at = now
        elif action == "reopen":
            if (
                claim.archived_at is not None
                or claim.voided_at is not None
                or claim.cancelled_at is None
            ):
                conflict("reimbursement_invalid_status_transition", "The claim cannot be reopened")
            claim.cancelled_at = None
            await self._validate_capacity(claim)
        elif action == "void":
            if claim.submitted_at is not None or claim.voided_at is not None or claim.receipts:
                conflict(
                    "reimbursement_invalid_status_transition",
                    "Only a never-received draft can be voided",
                )
            claim.voided_at = now
        elif action == "restore":
            if claim.voided_at is None or claim.archived_at is not None:
                conflict("reimbursement_invalid_status_transition", "The claim cannot be restored")
            claim.voided_at = None
            await self._validate_capacity(claim)
        elif action == "archive":
            if claim.archived_at is not None or await self._status(claim) not in {
                ReimbursementClaimStatus.RECEIVED,
                ReimbursementClaimStatus.CANCELLED,
                ReimbursementClaimStatus.PARTIALLY_RECEIVED_CANCELLED,
            }:
                conflict(
                    "reimbursement_invalid_status_transition",
                    "Only terminal claims can be archived",
                )
            claim.archived_at = now
        elif action == "unarchive":
            if claim.archived_at is None:
                conflict("reimbursement_invalid_status_transition", "The claim is not archived")
            claim.archived_at = None
        else:
            raise RuntimeError("unknown lifecycle action")
        claim.version += 1
        claim.updated_at = now
        await self.session.flush()
        response = await self.response(claim)
        self._claim_revision(claim, action, response)
        await self.session.commit()
        return response

    async def cancel_preview(self, claim_id: UUID, expected: int) -> ReimbursementCancelPreview:
        claim = await self._claim(claim_id)
        check_version(claim.version, expected)
        current = await self.response(claim)
        if current.status not in {
            ReimbursementClaimStatus.PENDING,
            ReimbursementClaimStatus.PARTIAL_RECEIVED,
        }:
            conflict(
                "reimbursement_invalid_status_transition",
                "The claim has no cancellable outstanding amount",
            )
        status = (
            ReimbursementClaimStatus.CANCELLED
            if current.received_minor == 0
            else ReimbursementClaimStatus.PARTIALLY_RECEIVED_CANCELLED
        )
        return ReimbursementCancelPreview(
            current=current,
            proposed_status=status,
            released_minor=current.outstanding_minor,
            retained_received_minor=current.received_minor,
        )

    async def receipt_preview(
        self,
        claim_id: UUID,
        draft: ReimbursementReceiptDraft,
        *,
        exclude_receipt: UUID | None = None,
    ) -> ReimbursementReceiptPreview:
        claim = await self._claim(claim_id)
        check_version(claim.version, draft.expected_claim_version)
        replaced_amount = 0
        replaced_party_id: UUID | None = None
        if exclude_receipt is None:
            _account, allocations = await self._validate_receipt_create(claim, draft)
        else:
            if not isinstance(draft, ReimbursementReceiptReplace):
                invalid(
                    "invalid_transaction_configuration",
                    "Receipt replacement preview requires both expected versions",
                )
            receipt = await self._receipt(exclude_receipt)
            if receipt.claim_id != claim.id:
                not_found("reimbursement_receipt_not_found", "The receipt is not in this claim")
            check_version(receipt.version, draft.expected_receipt_version)
            transaction = await self.repository.transaction(receipt.transaction_id)
            if transaction is None:
                raise RuntimeError("receipt transaction missing")
            await self.session.refresh(transaction, attribute_names=["postings"])
            replaced_amount = abs(transaction.postings[0].amount_minor)
            replaced_party_id = receipt.party_id
            _account, allocations = await self._validate_receipt_replace(
                claim, receipt, transaction, draft
            )
        current = await self.response(claim)
        party = next((p for p in current.parties if p.id == draft.party_id), None)
        if party is None:
            not_found("reimbursement_party_not_found", "The party does not exist")
        party_before = party.received_minor
        claim_before = current.received_minor
        if replaced_party_id == draft.party_id:
            party_after = checked_int64(party_before - replaced_amount + draft.amount_minor)
        else:
            party_after = checked_int64(party_before + draft.amount_minor)
        claim_after = checked_int64(claim_before - replaced_amount + draft.amount_minor)
        return ReimbursementReceiptPreview(
            claim_before=current,
            party_id=draft.party_id,
            amount_minor=draft.amount_minor,
            party_received_before_minor=party_before,
            party_received_after_minor=party_after,
            claim_received_before_minor=claim_before,
            claim_received_after_minor=claim_after,
            persisted_allocations=[
                ReimbursementReceiptAllocationResponse(
                    id=uuid4(), allocation_id=a.id, amount_minor=amount, position=i
                )
                for i, (a, amount) in enumerate(allocations)
            ],
        )

    async def create_receipt(
        self,
        claim_id: UUID,
        draft: ReimbursementReceiptDraft,
        key: UUID,
        *,
        commit: bool = True,
    ) -> ReimbursementReceiptResponse:
        await acquire_mutation_lock(self.session)
        request_hash = self._hash(draft)
        replay = await self.repository.operation(key)
        if replay is not None:
            if (
                replay.claim_id != claim_id
                or replay.request_hash != request_hash
                or replay.kind != "create_receipt"
            ):
                conflict("idempotency_key_reused", "The idempotency key was already used")
            if replay.result_snapshot is None:
                raise RuntimeError("receipt replay snapshot missing")
            return ReimbursementReceiptResponse.model_validate(replay.result_snapshot)
        claim = await self._claim(claim_id, for_update=True)
        check_version(claim.version, draft.expected_claim_version)
        account, allocations = await self._validate_receipt_create(claim, draft)
        tx = LedgerTransaction(
            kind=TransactionKind.REIMBURSEMENT_RECEIPT.value,
            occurred_at=ensure_utc(draft.received_at),
            title=draft.title,
            note=draft.note,
            source="system",
            idempotency_key=key,
            request_hash=request_hash,
        )
        tx.postings.append(
            Posting(
                account_id=account.id,
                role=PostingRole.ACCOUNT.value,
                amount_minor=draft.amount_minor,
                position=0,
            )
        )
        self.session.add(tx)
        await self.session.flush()
        receipt = ReimbursementReceipt(
            claim_id=claim.id, party_id=draft.party_id, transaction_id=tx.id
        )
        self.session.add(receipt)
        await self.session.flush()
        for i, (allocation, amount) in enumerate(allocations):
            self.session.add(
                ReimbursementReceiptAllocation(
                    receipt_id=receipt.id,
                    allocation_id=allocation.id,
                    amount_minor=amount,
                    position=i,
                )
            )
        if claim.submitted_at is None:
            claim.submitted_at = utc_now()
        claim.version += 1
        claim.updated_at = utc_now()
        await self.transactions.adjust_account_usage(account.id, 1)
        await self.session.flush()
        await self.transaction_service.validate_account_impacts({account.id})
        await self._refresh_claim(claim)
        receipt = await self._receipt(receipt.id)
        response = await self.receipt_response(receipt, tx)
        self._receipt_revision(receipt, "created", response)
        self.transactions.add_revision(
            TransactionRevision(
                transaction_id=tx.id,
                version=tx.version,
                event=RevisionEvent.CREATED.value,
                snapshot=self.transaction_service.snapshot_response(
                    tx, list(tx.postings)
                ).model_dump(mode="json"),
            )
        )
        self._claim_revision(claim, "receipt_created", await self.response(claim))
        operation = ReimbursementOperation(
            claim_id=claim.id,
            receipt_id=receipt.id,
            kind="create_receipt",
            idempotency_key=key,
            request_hash=request_hash,
            result_snapshot=response.model_dump(mode="json"),
        )
        self.session.add(operation)
        if commit:
            await self.session.commit()
        else:
            await self.session.flush()
        return response

    async def receipt_get(self, receipt_id: UUID) -> ReimbursementReceiptResponse:
        receipt = await self._receipt(receipt_id)
        tx = await self.repository.transaction(receipt.transaction_id)
        if tx is None:
            raise RuntimeError("receipt transaction missing")
        return await self.receipt_response(receipt, tx)

    async def receipt_claim_id(self, receipt_id: UUID) -> UUID:
        return (await self._receipt(receipt_id)).claim_id

    async def receipts(
        self, claim_id: UUID, *, cursor: str | None, limit: int
    ) -> ReimbursementReceiptPage:
        await self._claim(claim_id)
        time, rid = self._decode_cursor(cursor)
        rows = await self.repository.receipts_page(
            claim_id, limit=limit, cursor_time=time, cursor_id=rid
        )
        page = rows[:limit]
        items: list[ReimbursementReceiptResponse] = []
        for receipt in page:
            tx = await self.repository.transaction(receipt.transaction_id)
            assert tx is not None
            items.append(await self.receipt_response(receipt, tx))
        last_tx = await self.repository.transaction(page[-1].transaction_id) if page else None
        return ReimbursementReceiptPage(
            items=items,
            next_cursor=self._encode_cursor(last_tx.occurred_at, page[-1].id)
            if len(rows) > limit and last_tx
            else None,
        )

    async def replace_receipt(
        self, receipt_id: UUID, draft: ReimbursementReceiptReplace
    ) -> ReimbursementReceiptResponse:
        await acquire_mutation_lock(self.session)
        receipt = await self._receipt(receipt_id, for_update=True)
        claim = await self._claim(receipt.claim_id, for_update=True)
        check_version(claim.version, draft.expected_claim_version)
        check_version(receipt.version, draft.expected_receipt_version)
        tx = await self.repository.transaction(receipt.transaction_id)
        assert tx is not None
        await self.session.refresh(tx, attribute_names=["postings"])
        account, allocations = await self._validate_receipt_replace(claim, receipt, tx, draft)
        old_account = tx.postings[0].account_id
        await self.session.execute(
            delete(ReimbursementReceiptAllocation).where(
                ReimbursementReceiptAllocation.receipt_id == receipt.id
            )
        )
        await self.session.execute(delete(Posting).where(Posting.transaction_id == tx.id))
        await self.session.flush()
        posting = Posting(
            transaction_id=tx.id,
            account_id=account.id,
            role=PostingRole.ACCOUNT.value,
            amount_minor=draft.amount_minor,
            position=0,
        )
        self.session.add(posting)
        for i, (allocation, amount) in enumerate(allocations):
            self.session.add(
                ReimbursementReceiptAllocation(
                    receipt_id=receipt.id,
                    allocation_id=allocation.id,
                    amount_minor=amount,
                    position=i,
                )
            )
        tx.occurred_at = ensure_utc(draft.received_at)
        tx.title = draft.title
        tx.note = draft.note
        tx.version += 1
        tx.updated_at = utc_now()
        receipt.party_id = draft.party_id
        receipt.version += 1
        receipt.updated_at = utc_now()
        claim.version += 1
        claim.updated_at = utc_now()
        if old_account != account.id:
            await self.transactions.adjust_account_usage(old_account, -1)
            await self.transactions.adjust_account_usage(account.id, 1)
        await self.session.flush()
        await self.transaction_service.validate_account_impacts({old_account, account.id})
        await self.session.refresh(receipt, attribute_names=["allocations"])
        tx = await self.repository.transaction(tx.id)
        assert tx is not None
        await self.session.refresh(tx, attribute_names=["postings"])
        response = await self.receipt_response(receipt, tx)
        self._receipt_revision(receipt, "updated", response)
        self.transactions.add_revision(
            TransactionRevision(
                transaction_id=tx.id,
                version=tx.version,
                event=RevisionEvent.UPDATED.value,
                snapshot=self.transaction_service.snapshot_response(
                    tx, list(tx.postings)
                ).model_dump(mode="json"),
            )
        )
        self._claim_revision(claim, "receipt_updated", await self.response(claim))
        await self.session.commit()
        return response

    async def receipt_lifecycle(
        self, receipt_id: UUID, expected_claim: int, expected_receipt: int, action: str
    ) -> ReimbursementReceiptResponse:
        await acquire_mutation_lock(self.session)
        receipt = await self._receipt(receipt_id, for_update=True)
        claim = await self._claim(receipt.claim_id, for_update=True)
        check_version(claim.version, expected_claim)
        check_version(receipt.version, expected_receipt)
        if claim.archived_at is not None:
            conflict("reimbursement_claim_archived", "Unarchive the claim before changing receipts")
        tx = await self.repository.transaction(receipt.transaction_id)
        assert tx is not None
        await self.session.refresh(tx, attribute_names=["postings"])
        now = utc_now()
        if action == "void":
            if tx.voided_at is not None:
                return await self.receipt_response(receipt, tx)
            await self.session.execute(
                delete(ReimbursementReceiptAllocation).where(
                    ReimbursementReceiptAllocation.receipt_id == receipt.id
                )
            )
            tx.voided_at = now
            event = RevisionEvent.VOIDED
        elif action == "restore":
            if tx.voided_at is None:
                return await self.receipt_response(receipt, tx)
            if claim.voided_at is not None or (claim.cancelled_at is not None):
                conflict(
                    "reimbursement_invalid_status_transition",
                    "Reopen the claim before restoring this receipt",
                )
            account = await self._receipt_account(tx.postings[0].account_id, allow_archived=True)
            await self.session.execute(
                delete(ReimbursementReceiptAllocation).where(
                    ReimbursementReceiptAllocation.receipt_id == receipt.id
                )
            )
            await self.session.flush()
            distribution = await self._receipt_distribution(
                claim,
                receipt.party_id,
                abs(tx.postings[0].amount_minor),
                exclude_receipt=receipt.id,
            )
            for i, (allocation, amount) in enumerate(distribution):
                self.session.add(
                    ReimbursementReceiptAllocation(
                        receipt_id=receipt.id,
                        allocation_id=allocation.id,
                        amount_minor=amount,
                        position=i,
                    )
                )
            tx.voided_at = None
            event = RevisionEvent.RESTORED
            _ = account
        else:
            raise RuntimeError("unknown receipt lifecycle")
        tx.version += 1
        tx.updated_at = now
        receipt.version += 1
        receipt.updated_at = now
        claim.version += 1
        claim.updated_at = now
        await self.session.flush()
        await self.transaction_service.validate_account_impacts({tx.postings[0].account_id})
        await self.session.refresh(receipt, attribute_names=["allocations"])
        tx = await self.repository.transaction(tx.id)
        assert tx is not None
        response = await self.receipt_response(receipt, tx)
        self._receipt_revision(receipt, action, response)
        self.transactions.add_revision(
            TransactionRevision(
                transaction_id=tx.id,
                version=tx.version,
                event=event.value,
                snapshot=self.transaction_service.snapshot_response(
                    tx, list(tx.postings)
                ).model_dump(mode="json"),
            )
        )
        self._claim_revision(claim, f"receipt_{action}", await self.response(claim))
        await self.session.commit()
        return response

    async def eligibility(self, transaction_id: UUID) -> ReimbursementEligibility:
        tx = await self.repository.transaction(transaction_id)
        if tx is None:
            not_found("transaction_not_found", "The transaction does not exist")
        capacity = await self._capacity(transaction_id)
        allocated = await self._effective_allocated(transaction_id)
        reasons: list[str] = []
        if tx.kind not in {"expense", "credit_purchase"} or tx.voided_at is not None:
            reasons.append("not_eligible_expense")
        if capacity <= allocated:
            reasons.append("fully_allocated")
        return ReimbursementEligibility(
            eligible=not reasons,
            transaction_id=transaction_id,
            canonical_amount_minor=abs(tx.postings[0].amount_minor),
            allocated_minor=allocated,
            available_minor=max(capacity - allocated, 0),
            reasons=reasons,
        )

    async def expense_options(self) -> list[ReimbursementExpenseOption]:
        result: list[ReimbursementExpenseOption] = []
        for tx in await self.repository.expense_options():
            eligibility = await self.eligibility(tx.id)
            if eligibility.available_minor <= 0 or tx.category_id is None:
                continue
            result.append(
                ReimbursementExpenseOption(
                    transaction_id=tx.id,
                    title=tx.title,
                    business_date=tx.occurred_at.astimezone(BUSINESS_TIMEZONE).date(),
                    kind=tx.kind,
                    account_id=tx.postings[0].account_id,
                    category_id=tx.category_id,
                    canonical_amount_minor=eligibility.canonical_amount_minor,
                    allocated_minor=eligibility.allocated_minor,
                    available_minor=eligibility.available_minor,
                )
            )
        return result

    async def summary(
        self, *, date_from: date | None, date_to: date | None
    ) -> ReimbursementSummary:
        options = await self.repository.expense_options()
        gross = refund = expected = received = 0
        for tx in options:
            business = tx.occurred_at.astimezone(BUSINESS_TIMEZONE).date()
            if (date_from and business < date_from) or (date_to and business > date_to):
                continue
            canonical = abs(tx.postings[0].amount_minor)
            capacity = await self._capacity(tx.id)
            gross = checked_int64(gross + canonical)
            refund = checked_int64(refund + canonical - capacity)
            allocations, _ = await self.repository.reimbursement_for_transaction(tx.id)
            for allocation in allocations:
                claim = await self.repository.claim(allocation.claim_id)
                assert claim is not None
                active_received = (await self.repository.active_received(claim.id)).get(
                    allocation.id, 0
                )
                effective = (
                    0
                    if claim.voided_at
                    else active_received
                    if claim.cancelled_at
                    else allocation.amount_minor
                )
                expected = checked_int64(expected + effective)
                received = checked_int64(received + active_received)
        return ReimbursementSummary(
            gross_expense_minor=gross,
            merchant_principal_refund_minor=refund,
            expected_reimbursement_minor=expected,
            received_reimbursement_minor=received,
            personal_expected_expense_minor=checked_int64(gross - refund - expected),
            personal_realized_expense_minor=checked_int64(gross - refund - received),
            outstanding_minor=checked_int64(expected - received),
        )

    async def response(self, claim: ReimbursementClaim) -> ReimbursementClaimResponse:
        received_map = await self.repository.active_received(claim.id)
        txs = await self.repository.transactions(
            {a.transaction_id for a in claim.allocations}
            | {r.transaction_id for r in claim.receipts}
        )
        parties: list[ReimbursementPartyResponse] = []
        allocations_by_party: dict[UUID, list[ReimbursementAllocationResponse]] = {
            p.id: [] for p in claim.parties
        }
        for allocation in claim.allocations:
            tx = txs[allocation.transaction_id]
            received = received_map.get(allocation.id, 0)
            allocations_by_party[allocation.party_id].append(
                ReimbursementAllocationResponse(
                    id=allocation.id,
                    transaction_id=allocation.transaction_id,
                    expense_title=tx.title,
                    expense_amount_minor=abs(tx.postings[0].amount_minor),
                    amount_minor=allocation.amount_minor,
                    received_minor=received,
                    outstanding_minor=0
                    if claim.cancelled_at is not None
                    else allocation.amount_minor - received,
                    locked=received > 0,
                    position=allocation.position,
                )
            )
        for party in claim.parties:
            rows = allocations_by_party[party.id]
            claimed = sum(a.amount_minor for a in rows)
            got = sum(a.received_minor for a in rows)
            status = (
                "cancelled"
                if claim.cancelled_at and got == 0
                else "partially_received_cancelled"
                if claim.cancelled_at
                else "received"
                if got == claimed
                else "partial_received"
                if got
                else "pending"
            )
            parties.append(
                ReimbursementPartyResponse(
                    id=party.id,
                    name=party.name,
                    expected_date=party.expected_date,
                    note=party.note,
                    claimed_minor=claimed,
                    received_minor=got,
                    outstanding_minor=0 if claim.cancelled_at is not None else claimed - got,
                    status=status,
                    position=party.position,
                    allocations=rows,
                )
            )
        total = sum(a.amount_minor for a in claim.allocations)
        received = sum(received_map.values())
        latest = None
        if claim.receipts:
            latest_receipt = max(
                claim.receipts, key=lambda r: (txs[r.transaction_id].occurred_at, r.id)
            )
            latest = await self.receipt_response(latest_receipt, txs[latest_receipt.transaction_id])
        return ReimbursementClaimResponse(
            id=claim.id,
            title=claim.title,
            note=claim.note,
            status=await self._status(claim, total=total, received=received),
            total_claimed_minor=total,
            received_minor=received,
            outstanding_minor=0 if claim.cancelled_at is not None else max(total - received, 0),
            expense_count=len({a.transaction_id for a in claim.allocations}),
            party_count=len(claim.parties),
            receipt_count=len(claim.receipts),
            parties=parties,
            latest_receipt=latest,
            version=claim.version,
            submitted_at=claim.submitted_at,
            cancelled_at=claim.cancelled_at,
            voided_at=claim.voided_at,
            archived_at=claim.archived_at,
            created_at=claim.created_at,
            updated_at=claim.updated_at,
        )

    async def receipt_response(
        self, receipt: ReimbursementReceipt, tx: LedgerTransaction
    ) -> ReimbursementReceiptResponse:
        transaction = await self.transaction_service.response_with_relation(tx, list(tx.postings))
        return ReimbursementReceiptResponse(
            id=receipt.id,
            claim_id=receipt.claim_id,
            party_id=receipt.party_id,
            amount_minor=abs(tx.postings[0].amount_minor),
            received_at=tx.occurred_at,
            destination_account_id=tx.postings[0].account_id,
            title=tx.title,
            note=tx.note,
            transaction=transaction,
            allocations=[
                ReimbursementReceiptAllocationResponse(
                    id=a.id,
                    allocation_id=a.allocation_id,
                    amount_minor=a.amount_minor,
                    position=a.position,
                )
                for a in receipt.allocations
            ],
            version=receipt.version,
            voided_at=tx.voided_at,
            created_at=receipt.created_at,
            updated_at=receipt.updated_at,
        )

    async def _replace_matrix(
        self, claim: ReimbursementClaim, draft: ReimbursementClaimDraft, *, creating: bool
    ) -> None:
        await self._validate_draft(claim, draft, creating=creating)
        existing_parties = {p.id: p for p in claim.parties}
        existing_allocations = {a.id: a for a in claim.allocations}
        received = await self.repository.active_received(claim.id) if not creating else {}
        if not creating:
            for party in claim.parties:
                party.position += 1_000_000
            for allocation in claim.allocations:
                allocation.position += 1_000_000
            await self.session.flush()
        keep_parties: set[UUID] = set()
        keep_allocations: set[UUID] = set()
        position = 0
        for ppos, pdraft in enumerate(draft.parties):
            if pdraft.id is not None:
                party = existing_parties.get(pdraft.id)
                if party is None:
                    invalid(
                        "reimbursement_party_not_found", "A party id does not belong to this claim"
                    )
                keep_parties.add(party.id)
                party.name = pdraft.name
                party.expected_date = pdraft.expected_date
                party.note = pdraft.note
                party.position = ppos
            else:
                party = ReimbursementParty(
                    claim_id=claim.id,
                    name=pdraft.name,
                    expected_date=pdraft.expected_date,
                    note=pdraft.note,
                    position=ppos,
                )
                self.session.add(party)
                await self.session.flush()
                keep_parties.add(party.id)
            for adraft in pdraft.allocations:
                if adraft.id is not None:
                    allocation = existing_allocations.get(adraft.id)
                    if allocation is None:
                        invalid(
                            "reimbursement_allocation_locked",
                            "An allocation id does not belong to this claim",
                        )
                    if received.get(allocation.id, 0) and (
                        allocation.party_id != party.id
                        or allocation.transaction_id != adraft.transaction_id
                        or adraft.amount_minor < received[allocation.id]
                    ):
                        conflict(
                            "reimbursement_allocation_locked",
                            "A received matrix row cannot change identity or fall below received",
                        )
                    allocation.party_id = party.id
                    allocation.transaction_id = adraft.transaction_id
                    allocation.amount_minor = adraft.amount_minor
                    allocation.position = position
                else:
                    allocation = ReimbursementAllocation(
                        claim_id=claim.id,
                        party_id=party.id,
                        transaction_id=adraft.transaction_id,
                        amount_minor=adraft.amount_minor,
                        position=position,
                    )
                    self.session.add(allocation)
                    await self.session.flush()
                keep_allocations.add(allocation.id)
                position += 1
        for allocation in claim.allocations:
            if allocation.id not in keep_allocations:
                if received.get(allocation.id, 0):
                    conflict(
                        "reimbursement_allocation_locked", "A received allocation cannot be removed"
                    )
                await self.session.delete(allocation)
        receipt_party_ids = {r.party_id for r in claim.receipts}
        for party in claim.parties:
            if party.id not in keep_parties:
                if party.id in receipt_party_ids:
                    conflict(
                        "reimbursement_party_in_use", "A party with receipts cannot be removed"
                    )
                await self.session.delete(party)

    async def _refresh_claim(self, claim: ReimbursementClaim) -> None:
        await self.session.refresh(claim, attribute_names=["parties", "allocations", "receipts"])
        for receipt in claim.receipts:
            await self.session.refresh(receipt, attribute_names=["allocations"])

    async def _validate_draft(
        self, claim: ReimbursementClaim, draft: ReimbursementClaimDraft, *, creating: bool
    ) -> None:
        party_ids = [p.id for p in draft.parties if p.id]
        allocation_ids = [a.id for p in draft.parties for a in p.allocations if a.id]
        if len(set(party_ids)) != len(party_ids) or len(set(allocation_ids)) != len(allocation_ids):
            invalid("reimbursement_amount_mismatch", "Stable ids cannot repeat")
        proposed: dict[UUID, int] = {}
        for party in draft.parties:
            for allocation in party.allocations:
                proposed[allocation.transaction_id] = checked_int64(
                    proposed.get(allocation.transaction_id, 0) + allocation.amount_minor,
                    label="reimbursement allocation",
                )
        for transaction_id, amount in proposed.items():
            tx = await self.repository.transaction(transaction_id)
            if (
                tx is None
                or tx.kind not in {"expense", "credit_purchase"}
                or tx.voided_at is not None
            ):
                invalid("reimbursement_expense_not_eligible", "The source expense is not eligible")
            allocated = await self._effective_allocated(
                transaction_id, exclude_claim=None if creating else claim.id
            )
            capacity = await self._capacity(transaction_id)
            if checked_int64(allocated + amount, label="reimbursement allocation") > capacity:
                conflict(
                    "reimbursement_expense_overallocated",
                    "The source expense has insufficient reimbursable capacity",
                )

    async def _validate_capacity(self, claim: ReimbursementClaim) -> None:
        for transaction_id in {a.transaction_id for a in claim.allocations}:
            own = sum(
                a.amount_minor for a in claim.allocations if a.transaction_id == transaction_id
            )
            other = await self._effective_allocated(transaction_id, exclude_claim=claim.id)
            if checked_int64(own + other) > await self._capacity(transaction_id):
                conflict(
                    "reimbursement_expense_overallocated",
                    "The released expense capacity is now in use",
                )

    async def _receipt_distribution(
        self,
        claim: ReimbursementClaim,
        party_id: UUID,
        amount: int,
        *,
        exclude_receipt: UUID | None = None,
    ) -> list[tuple[ReimbursementAllocation, int]]:
        if not any(p.id == party_id for p in claim.parties):
            not_found("reimbursement_party_not_found", "The party does not exist")
        received = await self.repository.active_received(claim.id)
        if exclude_receipt is not None:
            old = await self.repository.receipt(exclude_receipt)
            if old:
                tx = await self.repository.transaction(old.transaction_id)
                if tx and tx.voided_at is None:
                    for item in old.allocations:
                        received[item.allocation_id] = (
                            received.get(item.allocation_id, 0) - item.amount_minor
                        )
        remaining = amount
        result: list[tuple[ReimbursementAllocation, int]] = []
        for allocation in sorted(
            (a for a in claim.allocations if a.party_id == party_id),
            key=lambda a: (a.position, a.id),
        ):
            available = allocation.amount_minor - received.get(allocation.id, 0)
            take = min(available, remaining)
            if take > 0:
                result.append((allocation, take))
                remaining -= take
            if remaining == 0:
                break
        if remaining:
            conflict(
                "reimbursement_receipt_exceeds_outstanding",
                "The receipt exceeds the party outstanding amount",
            )
        return result

    async def _validate_receipt_create(
        self,
        claim: ReimbursementClaim,
        draft: ReimbursementReceiptDraft,
    ) -> tuple[Account, list[tuple[ReimbursementAllocation, int]]]:
        self._receipt_claim_mutable(claim)
        self._validate_received_at(draft.received_at)
        account = await self._receipt_account(draft.destination_account_id, allow_archived=False)
        allocations = await self._receipt_distribution(claim, draft.party_id, draft.amount_minor)
        return account, allocations

    async def _validate_receipt_replace(
        self,
        claim: ReimbursementClaim,
        receipt: ReimbursementReceipt,
        transaction: LedgerTransaction,
        draft: ReimbursementReceiptReplace,
    ) -> tuple[Account, list[tuple[ReimbursementAllocation, int]]]:
        self._receipt_claim_mutable(claim, allow_cancelled_reduction=True)
        if transaction.voided_at is not None:
            conflict("reimbursement_receipt_in_use", "Restore the receipt before editing it")
        current_amount = abs(transaction.postings[0].amount_minor)
        if claim.cancelled_at is not None and draft.amount_minor > current_amount:
            conflict(
                "reimbursement_claim_cancelled",
                "A cancelled claim only permits reducing an existing receipt",
            )
        self._validate_received_at(draft.received_at)
        account = await self._receipt_account(
            draft.destination_account_id,
            allow_archived=(draft.destination_account_id == transaction.postings[0].account_id),
        )
        allocations = await self._receipt_distribution(
            claim,
            draft.party_id,
            draft.amount_minor,
            exclude_receipt=receipt.id,
        )
        return account, allocations

    async def _capacity(self, transaction_id: UUID) -> int:
        value = await self.session.scalar(
            select(func.fiscal_reimbursement_expense_capacity(transaction_id))
        )
        return int(value or 0)

    async def _effective_allocated(
        self, transaction_id: UUID, *, exclude_claim: UUID | None = None
    ) -> int:
        params = {"tid": transaction_id, "exclude": exclude_claim}
        value = await self.session.scalar(
            text(
                """
                SELECT COALESCE(sum(
                  CASE WHEN c.voided_at IS NOT NULL THEN 0
                       WHEN c.cancelled_at IS NULL THEN a.amount_minor
                       ELSE COALESCE((
                         SELECT sum(ra.amount_minor)
                           FROM reimbursement_receipt_allocations ra
                           JOIN reimbursement_receipts r ON r.id=ra.receipt_id
                           JOIN transactions rt
                             ON rt.id=r.transaction_id AND rt.voided_at IS NULL
                          WHERE ra.allocation_id=a.id
                       ),0)
                  END
                ),0)
                  FROM reimbursement_allocations a
                  JOIN reimbursement_claims c ON c.id=a.claim_id
                 WHERE a.transaction_id=:tid
                   AND (CAST(:exclude AS uuid) IS NULL OR c.id<>CAST(:exclude AS uuid))
                """
            ),
            params,
        )
        return int(value or 0)

    async def _claim(self, claim_id: UUID, *, for_update: bool = False) -> ReimbursementClaim:
        claim = await self.repository.claim(claim_id, for_update=for_update)
        if claim is None:
            not_found("reimbursement_claim_not_found", "The reimbursement claim does not exist")
        return claim

    async def _receipt(self, receipt_id: UUID, *, for_update: bool = False) -> ReimbursementReceipt:
        receipt = await self.repository.receipt(receipt_id, for_update=for_update)
        if receipt is None:
            not_found("reimbursement_receipt_not_found", "The reimbursement receipt does not exist")
        return receipt

    @staticmethod
    def _mutable(claim: ReimbursementClaim) -> None:
        if claim.archived_at is not None:
            conflict("reimbursement_claim_archived", "Unarchive the claim before editing it")
        if claim.voided_at is not None:
            conflict(
                "reimbursement_invalid_status_transition", "Restore the claim before editing it"
            )

    @staticmethod
    def _receipt_claim_mutable(
        claim: ReimbursementClaim, *, allow_cancelled_reduction: bool = False
    ) -> None:
        ReimbursementService._mutable(claim)
        if claim.cancelled_at is not None and not allow_cancelled_reduction:
            conflict("reimbursement_claim_cancelled", "Reopen the claim before adding a receipt")

    async def _receipt_account(self, account_id: UUID, *, allow_archived: bool) -> Account:
        account = await self.session.get(Account, account_id)
        if account is None:
            not_found("account_not_found", "The account does not exist")
        if account.kind not in {AccountKind.CASH.value, AccountKind.DEBIT.value}:
            invalid(
                "invalid_transaction_configuration", "A receipt requires a cash or debit account"
            )
        if account.archived_at is not None and not allow_archived:
            conflict("account_archived", "The selected account is archived")
        return account

    @staticmethod
    def _validate_received_at(value: datetime) -> None:
        if ensure_utc(value) > utc_now():
            invalid("invalid_received_at", "Receipt time cannot be in the future")

    async def _status(
        self, claim: ReimbursementClaim, *, total: int | None = None, received: int | None = None
    ) -> ReimbursementClaimStatus:
        total = total if total is not None else sum(a.amount_minor for a in claim.allocations)
        received = (
            received
            if received is not None
            else sum((await self.repository.active_received(claim.id)).values())
        )
        if claim.cancelled_at is not None:
            return (
                ReimbursementClaimStatus.CANCELLED
                if received == 0
                else ReimbursementClaimStatus.PARTIALLY_RECEIVED_CANCELLED
            )
        if received == total and total > 0:
            return ReimbursementClaimStatus.RECEIVED
        if received > 0:
            return ReimbursementClaimStatus.PARTIAL_RECEIVED
        return (
            ReimbursementClaimStatus.PENDING
            if claim.submitted_at is not None
            else ReimbursementClaimStatus.DRAFT
        )

    async def derived_status(self, claim: ReimbursementClaim) -> ReimbursementClaimStatus:
        return await self._status(claim)

    def _claim_revision(
        self, claim: ReimbursementClaim, event: str, response: ReimbursementClaimResponse
    ) -> None:
        self.session.add(
            ReimbursementClaimRevision(
                claim_id=claim.id,
                version=claim.version,
                event=event,
                snapshot=response.model_dump(mode="json"),
            )
        )

    def _receipt_revision(
        self, receipt: ReimbursementReceipt, event: str, response: ReimbursementReceiptResponse
    ) -> None:
        self.session.add(
            ReimbursementReceiptRevision(
                receipt_id=receipt.id,
                version=receipt.version,
                event=event,
                snapshot=response.model_dump(mode="json"),
            )
        )

    @staticmethod
    def _hash(model: object) -> str:
        payload = model.model_dump(mode="json")  # type: ignore[attr-defined]
        return hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        ).hexdigest()

    @staticmethod
    def _encode_cursor(value: datetime, item_id: UUID) -> str:
        return (
            base64.urlsafe_b64encode(f"{ensure_utc(value).isoformat()}|{item_id}".encode())
            .decode()
            .rstrip("=")
        )

    @staticmethod
    def _decode_cursor(cursor: str | None) -> tuple[datetime | None, UUID | None]:
        if cursor is None:
            return None, None
        try:
            decoded = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
            timestamp, item_id = decoded.rsplit("|", 1)
            value = datetime.fromisoformat(timestamp)
            if value.tzinfo is None:
                raise ValueError
            return ensure_utc(value), UUID(item_id)
        except (ValueError, UnicodeDecodeError):
            invalid("invalid_cursor", "The cursor is invalid")
