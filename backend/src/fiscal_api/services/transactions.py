from __future__ import annotations

import base64
import hashlib
import json
from datetime import date, datetime, time, timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import (
    CategorySummaryItem,
    PostingResponse,
    TransactionDraft,
    TransactionPage,
    TransactionResponse,
    TransactionSummary,
)
from fiscal_api.core.errors import APIError
from fiscal_api.core.time import BUSINESS_TIMEZONE, UTC, ensure_utc, utc_now
from fiscal_api.db.models import (
    Account,
    AccountKind,
    Category,
    LedgerTransaction,
    Posting,
    PostingRole,
    RevisionEvent,
    TransactionKind,
    TransactionRevision,
    TransactionSource,
)
from fiscal_api.repositories.credit import CreditRepository
from fiscal_api.repositories.installments import InstallmentRepository
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
from fiscal_api.services.credit import ensure_regular_cycle, validate_credit_invariants


class TransactionService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = TransactionRepository(session)
        self.credit_repository = CreditRepository(session)
        self.installment_repository = InstallmentRepository(session)
        self.reimbursement_repository = ReimbursementRepository(session)

    async def create(self, draft: TransactionDraft, idempotency_key: UUID) -> TransactionResponse:
        return await self._create(
            draft,
            idempotency_key,
            source=TransactionSource.MANUAL,
            commit=True,
        )

    async def create_ai_text(
        self,
        draft: TransactionDraft,
        idempotency_key: UUID,
        *,
        commit: bool = True,
    ) -> TransactionResponse:
        return await self._create(
            draft,
            idempotency_key,
            source=TransactionSource.AI_TEXT,
            commit=commit,
        )

    async def create_ai(
        self,
        draft: TransactionDraft,
        idempotency_key: UUID,
        source: TransactionSource,
        *,
        commit: bool = True,
    ) -> TransactionResponse:
        if source not in {TransactionSource.AI_TEXT, TransactionSource.OCR}:
            raise ValueError("AI ledger source must be ai_text or ocr")
        return await self._create(
            draft,
            idempotency_key,
            source=source,
            commit=commit,
        )

    async def _create(
        self,
        draft: TransactionDraft,
        idempotency_key: UUID,
        *,
        source: TransactionSource,
        commit: bool,
    ) -> TransactionResponse:
        await acquire_mutation_lock(self.session)
        request_hash = self._request_hash(draft, source=source)
        existing = await self.repository.get_by_idempotency_key(idempotency_key)
        if existing is not None:
            if existing.request_hash != request_hash:
                conflict(
                    "idempotency_key_reused",
                    "The idempotency key was already used for a different request",
                )
            snapshot = await self.repository.created_snapshot(existing.id)
            if snapshot is None:
                raise RuntimeError("created transaction revision is missing")
            return TransactionResponse.model_validate(snapshot)

        postings, category, cycle_id = await self._validated_postings(draft)
        transaction = LedgerTransaction(
            kind=draft.kind.value,
            occurred_at=ensure_utc(draft.occurred_at),
            title=draft.title,
            note=draft.note,
            category_id=category.id if category is not None else None,
            credit_cycle_id=cycle_id,
            source=source.value,
            idempotency_key=idempotency_key,
            request_hash=request_hash,
        )
        self.repository.add(transaction)
        await self.session.flush()
        for posting in postings:
            posting.transaction_id = transaction.id
        self.session.add_all(postings)
        await self._adjust_usage(set(), self._account_ids(postings), None, transaction.category_id)
        await self.session.flush()
        credit_accounts = await self._credit_account_ids(postings)
        await self._validate_mutation_ranges(
            self._account_ids(postings),
            credit_accounts=credit_accounts,
            enforce_limit=(
                credit_accounts if draft.kind is TransactionKind.CREDIT_PURCHASE else set()
            ),
            repayment_error=draft.kind is TransactionKind.REPAYMENT,
        )
        response = self._response(transaction, postings)
        self._add_revision(transaction, RevisionEvent.CREATED, response)
        if commit:
            await self.session.commit()
        else:
            await self.session.flush()
        return response

    async def get(self, transaction_id: UUID) -> TransactionResponse:
        transaction = await self._required(transaction_id)
        return await self.response_with_relation(transaction, list(transaction.postings))

    async def list(
        self,
        *,
        cursor: str | None,
        limit: int,
        kind: TransactionKind | None,
        account_id: UUID | None,
        category_id: UUID | None,
        date_from: date | None,
        date_to: date | None,
        query: str | None,
        include_voided: bool,
    ) -> TransactionPage:
        occurred_from, occurred_to = self._date_bounds(date_from, date_to)
        cursor_time, cursor_id = self._decode_cursor(cursor)
        transactions = await self.repository.list_page(
            limit=limit,
            kind=kind,
            account_id=account_id,
            category_id=category_id,
            occurred_from=occurred_from,
            occurred_to_exclusive=occurred_to,
            query=query.strip() if query and query.strip() else None,
            include_voided=include_voided,
            cursor_occurred_at=cursor_time,
            cursor_id=cursor_id,
        )
        has_more = len(transactions) > limit
        page = transactions[:limit]
        next_cursor = None
        if has_more and page:
            last = page[-1]
            next_cursor = self._encode_cursor(last.occurred_at, last.id)
        return TransactionPage(
            items=[await self.response_with_relation(item, list(item.postings)) for item in page],
            next_cursor=next_cursor,
        )

    async def list_cycle(
        self, cycle_id: UUID, *, cursor: str | None, limit: int
    ) -> TransactionPage:
        cursor_time, cursor_id = self._decode_cursor(cursor)
        transactions = await self.repository.list_cycle_page(
            cycle_id,
            limit=limit,
            cursor_occurred_at=cursor_time,
            cursor_id=cursor_id,
        )
        has_more = len(transactions) > limit
        page = transactions[:limit]
        next_cursor = self._encode_cursor(page[-1].occurred_at, page[-1].id) if has_more else None
        return TransactionPage(
            items=[await self.response_with_relation(item, list(item.postings)) for item in page],
            next_cursor=next_cursor,
        )

    async def update(
        self,
        transaction_id: UUID,
        draft: TransactionDraft,
        expected_version: int,
    ) -> TransactionResponse:
        await acquire_mutation_lock(self.session)
        transaction = await self._required(transaction_id, for_update=True)
        await self._assert_generic_mutation_allowed(transaction, draft=draft)
        check_version(transaction.version, expected_version)
        if transaction.voided_at is not None:
            conflict("transaction_voided", "Restore the transaction before editing it")
        old_response = self._response(transaction, list(transaction.postings))
        retain_accounts = {
            "account": old_response.account_id,
            "destination": old_response.destination_account_id,
        }
        postings, category, cycle_id = await self._validated_postings(
            draft,
            retain_accounts=retain_accounts,
            retain_category_id=old_response.category_id,
        )
        old_account_ids = self._account_ids(list(transaction.postings))
        old_category_id = transaction.category_id
        old_kind = TransactionKind(transaction.kind)
        old_amount = old_response.amount_minor
        transaction.kind = draft.kind.value
        transaction.occurred_at = ensure_utc(draft.occurred_at)
        transaction.title = draft.title
        transaction.note = draft.note
        transaction.category_id = category.id if category is not None else None
        transaction.credit_cycle_id = cycle_id
        transaction.version += 1
        transaction.updated_at = utc_now()
        for posting in postings:
            posting.transaction_id = transaction.id
        await self.repository.replace_postings(transaction.id, postings)
        await self._adjust_usage(
            old_account_ids,
            self._account_ids(postings),
            old_category_id,
            transaction.category_id,
        )
        await self.session.flush()
        new_credit_accounts = await self._credit_account_ids(postings)
        old_credit_accounts = await self._credit_account_ids_from_response(old_response)
        enforce_limit: set[UUID] = set()
        if draft.kind is TransactionKind.CREDIT_PURCHASE and (
            old_kind is not TransactionKind.CREDIT_PURCHASE
            or old_response.account_id != draft.account_id
            or draft.amount_minor > old_amount
        ):
            enforce_limit = new_credit_accounts
        await self._validate_mutation_ranges(
            old_account_ids | self._account_ids(postings),
            credit_accounts=old_credit_accounts | new_credit_accounts,
            enforce_limit=enforce_limit,
            repayment_error=draft.kind is TransactionKind.REPAYMENT,
        )
        response = self._response(transaction, postings)
        self._add_revision(transaction, RevisionEvent.UPDATED, response)
        await self.session.commit()
        return response

    async def void(
        self,
        transaction_id: UUID,
        expected_version: int,
        *,
        commit: bool = True,
    ) -> TransactionResponse:
        await acquire_mutation_lock(self.session)
        transaction = await self._required(transaction_id, for_update=True)
        await self._assert_generic_mutation_allowed(transaction, voiding=True)
        check_version(transaction.version, expected_version)
        if transaction.voided_at is not None:
            return self._response(transaction, list(transaction.postings))
        transaction.voided_at = utc_now()
        transaction.version += 1
        transaction.updated_at = utc_now()
        await self.session.flush()
        credit_accounts = await self._credit_account_ids(list(transaction.postings))
        await self._validate_mutation_ranges(
            self._account_ids(list(transaction.postings)),
            credit_accounts=credit_accounts,
            enforce_limit=set(),
            repayment_error=False,
        )
        response = self._response(transaction, list(transaction.postings))
        self._add_revision(transaction, RevisionEvent.VOIDED, response)
        if commit:
            await self.session.commit()
        else:
            await self.session.flush()
        return response

    async def restore(self, transaction_id: UUID, expected_version: int) -> TransactionResponse:
        await acquire_mutation_lock(self.session)
        transaction = await self._required(transaction_id, for_update=True)
        await self._assert_generic_mutation_allowed(transaction)
        check_version(transaction.version, expected_version)
        if transaction.voided_at is None:
            return self._response(transaction, list(transaction.postings))
        await self._validate_stored_references(transaction)
        transaction.voided_at = None
        transaction.version += 1
        transaction.updated_at = utc_now()
        await self.session.flush()
        credit_accounts = await self._credit_account_ids(list(transaction.postings))
        kind = TransactionKind(transaction.kind)
        await self._validate_mutation_ranges(
            self._account_ids(list(transaction.postings)),
            credit_accounts=credit_accounts,
            enforce_limit=credit_accounts if kind is TransactionKind.CREDIT_PURCHASE else set(),
            repayment_error=kind is TransactionKind.REPAYMENT,
        )
        response = self._response(transaction, list(transaction.postings))
        self._add_revision(transaction, RevisionEvent.RESTORED, response)
        await self.session.commit()
        return response

    async def summary(
        self,
        *,
        date_from: date | None,
        date_to: date | None,
    ) -> TransactionSummary:
        occurred_from, occurred_to = self._date_bounds(date_from, date_to)
        rows = await self.repository.summary(
            occurred_from=occurred_from, occurred_to_exclusive=occurred_to
        )
        return self._summary_response(rows)

    @staticmethod
    def _summary_response(rows: list[tuple[str, UUID, str, int]]) -> TransactionSummary:
        grouped: dict[tuple[str, UUID, str], int] = {}
        for kind, category_id, category_name, amount in rows:
            direction = (
                "expense"
                if kind in {"credit_purchase", "installment_fee", "installment_refund"}
                else kind
            )
            key = (direction, category_id, category_name)
            normalized_amount = amount if direction == "income" else -amount
            grouped[key] = checked_int64(
                grouped.get(key, 0) + normalized_amount,
                label="category summary amount",
            )
        normalized = [(*key, amount) for key, amount in grouped.items()]
        income = checked_int64(
            sum(amount for kind, _category, _name, amount in normalized if kind == "income"),
            label="income summary",
        )
        expense = checked_int64(
            sum(amount for kind, _category, _name, amount in normalized if kind == "expense"),
            label="expense summary",
        )
        by_category = sorted(
            (
                CategorySummaryItem(
                    category_id=category_id,
                    category_name=category_name,
                    direction=TransactionKind(kind),
                    amount_minor=amount,
                )
                for kind, category_id, category_name, amount in normalized
            ),
            key=lambda item: (str(item.category_id), item.amount_minor),
        )
        return TransactionSummary(
            income_minor=income,
            expense_minor=expense,
            net_minor=checked_int64(income - expense, label="net summary"),
            by_category=by_category,
        )

    async def _validate_mutation_ranges(
        self,
        account_ids: set[UUID],
        *,
        credit_accounts: set[UUID],
        enforce_limit: set[UUID],
        repayment_error: bool,
    ) -> None:
        impacts = await self.repository.balance_impacts(list(account_ids))
        accounts = [await self.repository.account(account_id) for account_id in account_ids]
        summary_rows = await self.repository.summary(
            occurred_from=None,
            occurred_to_exclusive=None,
        )
        try:
            for account in accounts:
                if account is None:
                    raise RuntimeError("transaction account is missing")
                impact = impacts.get(account.id, 0)
                balance = (
                    account.opening_balance_minor - impact
                    if account.kind == AccountKind.CREDIT.value
                    else account.opening_balance_minor + impact
                )
                checked_int64(balance, label="account balance")
                if account.kind == AccountKind.CREDIT.value and balance < 0:
                    conflict(
                        "repayment_exceeds_cycle_remaining"
                        if repayment_error
                        else "credit_cycle_overpaid",
                        "Credit debt cannot be negative",
                    )
                if (
                    account.id in enforce_limit
                    and account.credit_limit_minor is not None
                    and balance > account.credit_limit_minor
                ):
                    conflict("credit_limit_exceeded", "The credit purchase exceeds the limit")
            self._summary_response(summary_rows)
            await validate_credit_invariants(
                self.credit_repository,
                credit_accounts,
                repayment_error=repayment_error,
            )
        except APIError:
            await self.session.rollback()
            raise

    async def validate_account_impacts(self, account_ids: set[UUID]) -> None:
        await self._validate_mutation_ranges(
            account_ids,
            credit_accounts=set(),
            enforce_limit=set(),
            repayment_error=False,
        )

    async def _validated_postings(
        self,
        draft: TransactionDraft,
        *,
        retain_accounts: dict[str, UUID | None] | None = None,
        retain_category_id: UUID | None = None,
    ) -> tuple[list[Posting], Category | None, UUID | None]:
        retain_accounts = retain_accounts or {}
        if draft.kind in {TransactionKind.INCOME, TransactionKind.EXPENSE}:
            if (
                draft.account_id is None
                or draft.category_id is None
                or draft.destination_account_id is not None
                or draft.credit_cycle_id is not None
            ):
                invalid(
                    "invalid_transaction_configuration",
                    "Income and expense require account_id and category_id only",
                )
            account = await self._validated_account(
                draft.account_id,
                allow_archived=draft.account_id == retain_accounts.get("account"),
            )
            category = await self._validated_category(
                draft.category_id,
                direction=draft.kind.value,
                allow_archived=draft.category_id == retain_category_id,
            )
            sign = 1 if draft.kind is TransactionKind.INCOME else -1
            return (
                [
                    Posting(
                        account_id=account.id,
                        role=PostingRole.ACCOUNT.value,
                        amount_minor=sign * draft.amount_minor,
                        position=0,
                    )
                ],
                category,
                None,
            )
        if draft.kind is TransactionKind.CREDIT_PURCHASE:
            if (
                draft.account_id is None
                or draft.category_id is None
                or draft.destination_account_id is not None
                or draft.credit_cycle_id is not None
            ):
                invalid(
                    "invalid_transaction_configuration",
                    "Credit purchases require a credit account and expense category",
                )
            account = await self._validated_account(
                draft.account_id,
                allow_archived=draft.account_id == retain_accounts.get("account"),
                allowed_kinds={AccountKind.CREDIT},
            )
            category = await self._validated_category(
                draft.category_id,
                direction=TransactionKind.EXPENSE.value,
                allow_archived=draft.category_id == retain_category_id,
            )
            business_date = ensure_utc(draft.occurred_at).astimezone(BUSINESS_TIMEZONE).date()
            if (
                account.opening_balance_as_of_date is not None
                and business_date < account.opening_balance_as_of_date
            ):
                invalid(
                    "invalid_transaction_configuration",
                    "Credit purchases cannot predate the opening balance",
                )
            cycle = await ensure_regular_cycle(self.credit_repository, account, business_date)
            return (
                [
                    Posting(
                        account_id=account.id,
                        role=PostingRole.ACCOUNT.value,
                        amount_minor=-draft.amount_minor,
                        position=0,
                    )
                ],
                category,
                cycle.id,
            )
        if draft.kind is TransactionKind.REPAYMENT:
            if (
                draft.account_id is None
                or draft.destination_account_id is None
                or draft.category_id is not None
                or draft.credit_cycle_id is None
            ):
                invalid(
                    "invalid_transaction_configuration",
                    "Repayments require payment account, credit account, and credit cycle",
                )
            source = await self._validated_account(
                draft.account_id,
                allow_archived=draft.account_id == retain_accounts.get("account"),
                allowed_kinds={AccountKind.CASH, AccountKind.DEBIT},
            )
            destination = await self._validated_account(
                draft.destination_account_id,
                allow_archived=draft.destination_account_id == retain_accounts.get("destination"),
                allowed_kinds={AccountKind.CREDIT},
            )
            cycle = await self.credit_repository.cycle(draft.credit_cycle_id)
            if cycle is None:
                not_found("credit_cycle_not_found", "The credit cycle does not exist")
            if cycle.account_id != destination.id:
                conflict(
                    "credit_cycle_account_mismatch",
                    "The credit cycle belongs to another account",
                )
            return (
                [
                    Posting(
                        account_id=source.id,
                        role=PostingRole.SOURCE.value,
                        amount_minor=-draft.amount_minor,
                        position=0,
                    ),
                    Posting(
                        account_id=destination.id,
                        role=PostingRole.DESTINATION.value,
                        amount_minor=draft.amount_minor,
                        position=1,
                    ),
                ],
                None,
                cycle.id,
            )
        if (
            draft.account_id is None
            or draft.destination_account_id is None
            or draft.category_id is not None
            or draft.credit_cycle_id is not None
        ):
            invalid(
                "invalid_transaction_configuration",
                "Transfer requires source account_id and destination_account_id only",
            )
        if draft.account_id == draft.destination_account_id:
            invalid("transfer_same_account", "Transfer accounts must be distinct")
        source = await self._validated_account(
            draft.account_id,
            allow_archived=draft.account_id == retain_accounts.get("account"),
            allowed_kinds={AccountKind.CASH, AccountKind.DEBIT},
        )
        destination = await self._validated_account(
            draft.destination_account_id,
            allow_archived=draft.destination_account_id == retain_accounts.get("destination"),
            allowed_kinds={AccountKind.CASH, AccountKind.DEBIT},
        )
        return (
            [
                Posting(
                    account_id=source.id,
                    role=PostingRole.SOURCE.value,
                    amount_minor=-draft.amount_minor,
                    position=0,
                ),
                Posting(
                    account_id=destination.id,
                    role=PostingRole.DESTINATION.value,
                    amount_minor=draft.amount_minor,
                    position=1,
                ),
            ],
            None,
            None,
        )

    async def _validated_account(
        self,
        account_id: UUID,
        *,
        allow_archived: bool,
        allowed_kinds: set[AccountKind] | None = None,
    ) -> Account:
        account = await self.repository.account(account_id)
        if account is None:
            not_found("account_not_found", "The account does not exist")
        allowed_kinds = allowed_kinds or {AccountKind.CASH, AccountKind.DEBIT}
        if account.kind not in {item.value for item in allowed_kinds}:
            invalid(
                "invalid_transaction_configuration",
                "The account kind does not match the transaction",
            )
        if account.archived_at is not None and not allow_archived:
            conflict("account_archived", "The selected account is archived")
        return account

    async def _validated_category(
        self,
        category_id: UUID,
        *,
        direction: str,
        allow_archived: bool,
    ) -> Category:
        category = await self.repository.category(category_id)
        if category is None:
            not_found("category_not_found", "The category does not exist")
        if category.direction != direction:
            invalid(
                "category_direction_mismatch",
                "The category direction does not match the transaction kind",
            )
        if category.archived_at is not None and not allow_archived:
            conflict("category_archived", "The selected category is archived")
        return category

    async def _validate_stored_references(self, transaction: LedgerTransaction) -> None:
        kind = TransactionKind(transaction.kind)
        for posting in transaction.postings:
            allowed = (
                {AccountKind.CREDIT}
                if kind is TransactionKind.CREDIT_PURCHASE
                or (
                    kind is TransactionKind.REPAYMENT
                    and posting.role == PostingRole.DESTINATION.value
                )
                else {AccountKind.CASH, AccountKind.DEBIT}
            )
            await self._validated_account(
                posting.account_id, allow_archived=True, allowed_kinds=allowed
            )
        if transaction.category_id is not None:
            await self._validated_category(
                transaction.category_id,
                direction=(
                    TransactionKind.EXPENSE.value
                    if kind is TransactionKind.CREDIT_PURCHASE
                    else kind.value
                ),
                allow_archived=True,
            )
        if transaction.credit_cycle_id is not None:
            cycle = await self.credit_repository.cycle(transaction.credit_cycle_id)
            if cycle is None:
                not_found("credit_cycle_not_found", "The credit cycle does not exist")

    async def _required(
        self, transaction_id: UUID, *, for_update: bool = False
    ) -> LedgerTransaction:
        transaction = await self.repository.get(transaction_id, for_update=for_update)
        if transaction is None:
            not_found("transaction_not_found", "The transaction does not exist")
        return transaction

    async def _assert_generic_mutation_allowed(
        self,
        transaction: LedgerTransaction,
        *,
        draft: TransactionDraft | None = None,
        voiding: bool = False,
    ) -> None:
        (
            reimbursement_allocations,
            reimbursement_receipt,
        ) = await self.reimbursement_repository.reimbursement_for_transaction(transaction.id)
        if reimbursement_receipt is not None or transaction.kind == "reimbursement_receipt":
            conflict(
                "reimbursement_receipt_in_use",
                "Use the reimbursement receipt command to change this transaction",
            )
        if reimbursement_allocations:
            if voiding or draft is None or draft.kind.value != transaction.kind:
                conflict(
                    "reimbursement_claim_in_use",
                    "The source expense is used by a reimbursement claim",
                )
            effective = await self.reimbursement_repository.allocated_for_expense(transaction.id)
            if draft.amount_minor < effective:
                conflict(
                    "reimbursement_claim_in_use",
                    "The source expense would fall below its reimbursement allocation",
                )
        if transaction.source == "system" or await self.installment_repository.linked(
            transaction.id
        ):
            conflict(
                "installment_plan_in_use",
                "Use the installment plan command to change this transaction",
            )

    async def _adjust_usage(
        self,
        old_accounts: set[UUID],
        new_accounts: set[UUID],
        old_category: UUID | None,
        new_category: UUID | None,
    ) -> None:
        for account_id in old_accounts - new_accounts:
            await self.repository.adjust_account_usage(account_id, -1)
        for account_id in new_accounts - old_accounts:
            await self.repository.adjust_account_usage(account_id, 1)
        if old_category != new_category:
            if old_category is not None:
                await self.repository.adjust_category_usage(old_category, -1)
            if new_category is not None:
                await self.repository.adjust_category_usage(new_category, 1)

    def _add_revision(
        self,
        transaction: LedgerTransaction,
        event: RevisionEvent,
        response: TransactionResponse,
    ) -> None:
        self.repository.add_revision(
            TransactionRevision(
                transaction_id=transaction.id,
                version=transaction.version,
                event=event.value,
                snapshot=response.model_dump(mode="json"),
            )
        )

    @staticmethod
    def _response(
        transaction: LedgerTransaction,
        postings: list[Posting],
    ) -> TransactionResponse:
        by_role = {PostingRole(posting.role): posting for posting in postings}
        kind = TransactionKind(transaction.kind)
        primary = by_role.get(PostingRole.ACCOUNT) or by_role.get(PostingRole.SOURCE)
        destination = by_role.get(PostingRole.DESTINATION)
        if primary is None:
            raise RuntimeError("transaction has no primary posting")
        return TransactionResponse(
            id=transaction.id,
            kind=kind,
            amount_minor=checked_int64(abs(primary.amount_minor), label="transaction amount"),
            occurred_at=ensure_utc(transaction.occurred_at),
            business_date=transaction.occurred_at.astimezone(BUSINESS_TIMEZONE).date(),
            title=transaction.title,
            note=transaction.note,
            category_id=transaction.category_id,
            account_id=primary.account_id,
            destination_account_id=destination.account_id if destination is not None else None,
            credit_cycle_id=transaction.credit_cycle_id,
            source=transaction.source,
            postings=[
                PostingResponse(
                    id=posting.id,
                    account_id=posting.account_id,
                    role=PostingRole(posting.role),
                    amount_minor=posting.amount_minor,
                    position=posting.position,
                )
                for posting in sorted(postings, key=lambda item: (item.position, item.id))
            ],
            version=transaction.version,
            voided_at=transaction.voided_at,
            created_at=transaction.created_at,
            updated_at=transaction.updated_at,
        )

    @staticmethod
    def snapshot_response(
        transaction: LedgerTransaction, postings: list[Posting]
    ) -> TransactionResponse:
        return TransactionService._response(transaction, postings)

    async def response_with_relation(
        self, transaction: LedgerTransaction, postings: list[Posting]
    ) -> TransactionResponse:
        response = self._response(transaction, postings)
        link = await self.installment_repository.linked(transaction.id)
        if link is not None:
            plan = await self.installment_repository.plan(link.plan_id)
            if plan is None:
                raise RuntimeError("installment relation plan missing")
            from fiscal_api.api.installment_types import InstallmentRelation
            from fiscal_api.db.models import InstallmentLedgerRole
            from fiscal_api.services.installments import InstallmentService

            plan_response = await InstallmentService(self.session).response(plan)
            response = response.model_copy(
                update={
                    "installment_plan_id": plan.id,
                    "installment_relation": InstallmentRelation(
                        plan_id=plan.id,
                        role=InstallmentLedgerRole(link.role),
                        plan_title=plan_response.title,
                        plan_status=plan_response.status,
                    ),
                }
            )
        allocations, receipt = await self.reimbursement_repository.reimbursement_for_transaction(
            transaction.id
        )
        if not allocations and receipt is None:
            return response
        from fiscal_api.api.reimbursement_types import ReimbursementRelation
        from fiscal_api.db.models import ReimbursementRelationRole
        from fiscal_api.services.reimbursements import ReimbursementService

        service = ReimbursementService(self.session)
        relations: list[ReimbursementRelation] = []
        for allocation in allocations:
            claim = await self.reimbursement_repository.claim(allocation.claim_id)
            if claim is None:
                raise RuntimeError("reimbursement relation claim missing")
            received = (await self.reimbursement_repository.active_received(claim.id)).get(
                allocation.id, 0
            )
            party = next(item for item in claim.parties if item.id == allocation.party_id)
            effective_allocated = (
                received if claim.cancelled_at is not None else allocation.amount_minor
            )
            relations.append(
                ReimbursementRelation(
                    role=ReimbursementRelationRole.EXPENSE,
                    claim_id=claim.id,
                    claim_title=claim.title,
                    claim_status=await service.derived_status(claim),
                    party_id=party.id,
                    party_name=party.name,
                    receipt_id=None,
                    allocated_minor=effective_allocated,
                    received_minor=received,
                    outstanding_minor=effective_allocated - received,
                )
            )
        if receipt is not None:
            claim = await self.reimbursement_repository.claim(receipt.claim_id)
            if claim is None:
                raise RuntimeError("reimbursement receipt claim missing")
            party = next(item for item in claim.parties if item.id == receipt.party_id)
            amount = response.amount_minor
            relations.append(
                ReimbursementRelation(
                    role=ReimbursementRelationRole.RECEIPT,
                    claim_id=claim.id,
                    claim_title=claim.title,
                    claim_status=await service.derived_status(claim),
                    party_id=party.id,
                    party_name=party.name,
                    receipt_id=receipt.id,
                    allocated_minor=amount,
                    received_minor=0 if transaction.voided_at else amount,
                    outstanding_minor=0,
                )
            )
        return response.model_copy(update={"reimbursement_relations": relations})

    @staticmethod
    def _account_ids(postings: list[Posting]) -> set[UUID]:
        return {posting.account_id for posting in postings}

    async def _credit_account_ids(self, postings: list[Posting]) -> set[UUID]:
        result: set[UUID] = set()
        for posting in postings:
            account = await self.repository.account(posting.account_id)
            if account is not None and account.kind == AccountKind.CREDIT.value:
                result.add(account.id)
        return result

    async def _credit_account_ids_from_response(self, response: TransactionResponse) -> set[UUID]:
        result: set[UUID] = set()
        for account_id in {response.account_id, response.destination_account_id} - {None}:
            assert account_id is not None
            account = await self.repository.account(account_id)
            if account is not None and account.kind == AccountKind.CREDIT.value:
                result.add(account.id)
        return result

    @staticmethod
    def _request_hash(draft: TransactionDraft, *, source: TransactionSource) -> str:
        payload = draft.model_dump(mode="json")
        payload["occurred_at"] = ensure_utc(draft.occurred_at).isoformat()
        payload["source"] = source.value
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        return hashlib.sha256(canonical.encode()).hexdigest()

    @staticmethod
    def _date_bounds(
        date_from: date | None,
        date_to: date | None,
    ) -> tuple[datetime | None, datetime | None]:
        if date_from is not None and date_to is not None and date_from > date_to:
            invalid("invalid_transaction_configuration", "date_from must not exceed date_to")
        start = (
            datetime.combine(date_from, time.min, BUSINESS_TIMEZONE).astimezone(UTC)
            if date_from is not None
            else None
        )
        end = (
            datetime.combine(date_to + timedelta(days=1), time.min, BUSINESS_TIMEZONE).astimezone(
                UTC
            )
            if date_to is not None
            else None
        )
        return start, end

    @staticmethod
    def _encode_cursor(occurred_at: datetime, transaction_id: UUID) -> str:
        payload = json.dumps(
            {"occurred_at": ensure_utc(occurred_at).isoformat(), "id": str(transaction_id)},
            separators=(",", ":"),
        )
        return base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")

    @staticmethod
    def _decode_cursor(cursor: str | None) -> tuple[datetime | None, UUID | None]:
        if cursor is None:
            return None, None
        try:
            padded = cursor + "=" * (-len(cursor) % 4)
            payload = json.loads(base64.urlsafe_b64decode(padded).decode())
            occurred_at = ensure_utc(datetime.fromisoformat(payload["occurred_at"]))
            transaction_id = UUID(payload["id"])
        except (ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
            invalid("invalid_transaction_configuration", "The cursor is invalid")
            raise AssertionError from error
        return occurred_at, transaction_id
