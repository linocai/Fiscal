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
)
from fiscal_api.repositories.transactions import TransactionRepository
from fiscal_api.services.common import (
    acquire_mutation_lock,
    check_version,
    checked_int64,
    conflict,
    invalid,
    not_found,
)


class TransactionService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = TransactionRepository(session)

    async def create(self, draft: TransactionDraft, idempotency_key: UUID) -> TransactionResponse:
        await acquire_mutation_lock(self.session)
        request_hash = self._request_hash(draft)
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

        postings, category = await self._validated_postings(draft)
        transaction = LedgerTransaction(
            kind=draft.kind.value,
            occurred_at=ensure_utc(draft.occurred_at),
            title=draft.title,
            note=draft.note,
            category_id=category.id if category is not None else None,
            source="manual",
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
        await self._validate_mutation_ranges(self._account_ids(postings))
        response = self._response(transaction, postings)
        self._add_revision(transaction, RevisionEvent.CREATED, response)
        await self.session.commit()
        return response

    async def get(self, transaction_id: UUID) -> TransactionResponse:
        transaction = await self._required(transaction_id)
        return self._response(transaction, list(transaction.postings))

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
            items=[self._response(item, list(item.postings)) for item in page],
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
        check_version(transaction.version, expected_version)
        if transaction.voided_at is not None:
            conflict("transaction_voided", "Restore the transaction before editing it")
        old_response = self._response(transaction, list(transaction.postings))
        retain_accounts = {
            "account": old_response.account_id,
            "destination": old_response.destination_account_id,
        }
        postings, category = await self._validated_postings(
            draft,
            retain_accounts=retain_accounts,
            retain_category_id=old_response.category_id,
        )
        old_account_ids = self._account_ids(list(transaction.postings))
        old_category_id = transaction.category_id
        transaction.kind = draft.kind.value
        transaction.occurred_at = ensure_utc(draft.occurred_at)
        transaction.title = draft.title
        transaction.note = draft.note
        transaction.category_id = category.id if category is not None else None
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
        await self._validate_mutation_ranges(old_account_ids | self._account_ids(postings))
        response = self._response(transaction, postings)
        self._add_revision(transaction, RevisionEvent.UPDATED, response)
        await self.session.commit()
        return response

    async def void(self, transaction_id: UUID, expected_version: int) -> TransactionResponse:
        await acquire_mutation_lock(self.session)
        transaction = await self._required(transaction_id, for_update=True)
        check_version(transaction.version, expected_version)
        if transaction.voided_at is not None:
            return self._response(transaction, list(transaction.postings))
        transaction.voided_at = utc_now()
        transaction.version += 1
        transaction.updated_at = utc_now()
        await self.session.flush()
        await self._validate_mutation_ranges(self._account_ids(list(transaction.postings)))
        response = self._response(transaction, list(transaction.postings))
        self._add_revision(transaction, RevisionEvent.VOIDED, response)
        await self.session.commit()
        return response

    async def restore(self, transaction_id: UUID, expected_version: int) -> TransactionResponse:
        await acquire_mutation_lock(self.session)
        transaction = await self._required(transaction_id, for_update=True)
        check_version(transaction.version, expected_version)
        if transaction.voided_at is None:
            return self._response(transaction, list(transaction.postings))
        await self._validate_stored_references(transaction)
        transaction.voided_at = None
        transaction.version += 1
        transaction.updated_at = utc_now()
        await self.session.flush()
        await self._validate_mutation_ranges(self._account_ids(list(transaction.postings)))
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
        normalized = [
            (
                kind,
                category_id,
                category_name,
                checked_int64(
                    amount if kind == "income" else -amount,
                    label="category summary amount",
                ),
            )
            for kind, category_id, category_name, amount in rows
        ]
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

    async def _validate_mutation_ranges(self, account_ids: set[UUID]) -> None:
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
            self._summary_response(summary_rows)
        except APIError:
            await self.session.rollback()
            raise

    async def _validated_postings(
        self,
        draft: TransactionDraft,
        *,
        retain_accounts: dict[str, UUID | None] | None = None,
        retain_category_id: UUID | None = None,
    ) -> tuple[list[Posting], Category | None]:
        retain_accounts = retain_accounts or {}
        if draft.kind in {TransactionKind.INCOME, TransactionKind.EXPENSE}:
            if (
                draft.account_id is None
                or draft.category_id is None
                or draft.destination_account_id is not None
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
                direction=draft.kind,
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
            )
        if (
            draft.account_id is None
            or draft.destination_account_id is None
            or draft.category_id is not None
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
        )
        destination = await self._validated_account(
            draft.destination_account_id,
            allow_archived=draft.destination_account_id == retain_accounts.get("destination"),
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
        )

    async def _validated_account(self, account_id: UUID, *, allow_archived: bool) -> Account:
        account = await self.repository.account(account_id)
        if account is None:
            not_found("account_not_found", "The account does not exist")
        if account.kind not in {AccountKind.CASH.value, AccountKind.DEBIT.value}:
            invalid(
                "invalid_transaction_configuration",
                "P3 transactions require cash or debit accounts",
            )
        if account.archived_at is not None and not allow_archived:
            conflict("account_archived", "The selected account is archived")
        return account

    async def _validated_category(
        self,
        category_id: UUID,
        *,
        direction: TransactionKind,
        allow_archived: bool,
    ) -> Category:
        category = await self.repository.category(category_id)
        if category is None:
            not_found("category_not_found", "The category does not exist")
        if category.direction != direction.value:
            invalid(
                "category_direction_mismatch",
                "The category direction does not match the transaction kind",
            )
        if category.archived_at is not None and not allow_archived:
            conflict("category_archived", "The selected category is archived")
        return category

    async def _validate_stored_references(self, transaction: LedgerTransaction) -> None:
        for posting in transaction.postings:
            await self._validated_account(posting.account_id, allow_archived=True)
        if transaction.category_id is not None:
            await self._validated_category(
                transaction.category_id,
                direction=TransactionKind(transaction.kind),
                allow_archived=True,
            )

    async def _required(
        self, transaction_id: UUID, *, for_update: bool = False
    ) -> LedgerTransaction:
        transaction = await self.repository.get(transaction_id, for_update=for_update)
        if transaction is None:
            not_found("transaction_not_found", "The transaction does not exist")
        return transaction

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
    def _account_ids(postings: list[Posting]) -> set[UUID]:
        return {posting.account_id for posting in postings}

    @staticmethod
    def _request_hash(draft: TransactionDraft) -> str:
        payload = draft.model_dump(mode="json")
        payload["occurred_at"] = ensure_utc(draft.occurred_at).isoformat()
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
