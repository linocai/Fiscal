from __future__ import annotations

from datetime import date
from uuid import UUID

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p2_schemas import AccountDraft, AccountPatch, AccountResponse
from fiscal_api.core.errors import APIError
from fiscal_api.core.time import BUSINESS_TIMEZONE, utc_now
from fiscal_api.db.models import Account, AccountKind
from fiscal_api.repositories.accounts import AccountRepository
from fiscal_api.repositories.credit import CreditRepository
from fiscal_api.services.common import (
    acquire_p2_mutation_lock,
    check_version,
    checked_int64,
    conflict,
    invalid,
    not_found,
)
from fiscal_api.services.credit import sync_opening_cycle, validate_credit_invariants


class AccountService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = AccountRepository(session)
        self.credit_repository = CreditRepository(session)

    @staticmethod
    def response(account: Account, impact: int = 0) -> AccountResponse:
        values: dict[str, object] = {
            field: getattr(account, field)
            for field in AccountResponse.model_fields
            if field != "current_balance_minor"
        }
        current_balance = (
            account.opening_balance_minor - impact
            if account.kind == AccountKind.CREDIT.value
            else account.opening_balance_minor + impact
        )
        values["current_balance_minor"] = checked_int64(current_balance, label="account balance")
        return AccountResponse.model_validate(values)

    async def list(self, *, include_archived: bool) -> list[AccountResponse]:
        accounts = await self.repository.list(include_archived=include_archived)
        impacts = await self.repository.balance_impacts([item.id for item in accounts])
        return [self.response(item, impacts.get(item.id, 0)) for item in accounts]

    async def get(self, account_id: UUID) -> AccountResponse:
        account = await self._required(account_id)
        impacts = await self.repository.balance_impacts([account.id])
        return self.response(account, impacts.get(account.id, 0))

    async def create(self, draft: AccountDraft) -> AccountResponse:
        await acquire_p2_mutation_lock(self.session)
        self._validate_configuration(
            kind=draft.kind,
            opening=draft.opening_balance_minor,
            limit=draft.credit_limit_minor,
            statement_day=draft.statement_day,
            due_day=draft.due_day,
            opening_as_of=draft.opening_balance_as_of_date,
            opening_due=draft.opening_due_date,
            today=utc_now().astimezone(BUSINESS_TIMEZONE).date(),
        )
        if await self.repository.active_name_exists(draft.name):
            conflict("account_name_conflict", "An active account already uses this name")
        account = Account(
            name=draft.name,
            kind=draft.kind.value,
            institution=draft.institution,
            last_four=draft.last_four,
            opening_balance_minor=draft.opening_balance_minor,
            credit_limit_minor=draft.credit_limit_minor,
            statement_day=draft.statement_day,
            due_day=draft.due_day,
            opening_balance_as_of_date=draft.opening_balance_as_of_date,
            opening_due_date=draft.opening_due_date,
            sort_order=await self.repository.next_sort_order(),
        )
        self.repository.add(account)
        await self.session.flush()
        if draft.kind is AccountKind.CREDIT:
            await sync_opening_cycle(self.credit_repository, account)
        await self._commit_name_safe()
        await self.session.refresh(account)
        return self.response(account)

    async def update(self, account_id: UUID, patch: AccountPatch) -> AccountResponse:
        await acquire_p2_mutation_lock(self.session)
        account = await self._required(account_id, for_update=True)
        check_version(account.version, patch.expected_version)
        updates = patch.model_dump(exclude={"expected_version"}, exclude_unset=True)
        kind_changes = "kind" in updates and updates["kind"].value != account.kind
        if kind_changes and (
            account.usage_count > 0 or await self.credit_repository.has_any_cycle(account.id)
        ):
            conflict("account_in_use", "A used account cannot change kind")
        kind = AccountKind(updates.get("kind", account.kind))
        opening = updates.get("opening_balance_minor", account.opening_balance_minor)
        limit = updates.get("credit_limit_minor", account.credit_limit_minor)
        statement_day = updates.get("statement_day", account.statement_day)
        due_day = updates.get("due_day", account.due_day)
        opening_as_of = updates.get(
            "opening_balance_as_of_date", account.opening_balance_as_of_date
        )
        opening_due = updates.get("opening_due_date", account.opening_due_date)
        schedule_changed = statement_day != account.statement_day or due_day != account.due_day
        if (
            account.kind == AccountKind.CREDIT.value
            and schedule_changed
            and await self.credit_repository.schedule_is_used(account.id)
        ):
            conflict(
                "credit_schedule_in_use",
                "The statement schedule is frozen after the first credit cycle",
            )
        self._validate_configuration(
            kind=kind,
            opening=opening,
            limit=limit,
            statement_day=statement_day,
            due_day=due_day,
            opening_as_of=opening_as_of,
            opening_due=opening_due,
            today=utc_now().astimezone(BUSINESS_TIMEZONE).date(),
        )
        name = updates.get("name", account.name)
        if account.archived_at is None and await self.repository.active_name_exists(
            name, excluding=account.id
        ):
            conflict("account_name_conflict", "An active account already uses this name")
        for field, value in updates.items():
            setattr(account, field, value.value if isinstance(value, AccountKind) else value)
        self._touch(account)
        try:
            if kind is AccountKind.CREDIT:
                await sync_opening_cycle(self.credit_repository, account)
                await validate_credit_invariants(self.credit_repository, {account.id})
        except APIError:
            await self.session.rollback()
            raise
        impacts = await self.repository.balance_impacts([account.id])
        try:
            self.response(account, impacts.get(account.id, 0))
        except APIError:
            await self.session.rollback()
            raise
        await self._commit_name_safe()
        await self.session.refresh(account)
        return self.response(account, impacts.get(account.id, 0))

    async def archive(self, account_id: UUID, expected_version: int) -> AccountResponse:
        await acquire_p2_mutation_lock(self.session)
        account = await self._required(account_id, for_update=True)
        check_version(account.version, expected_version)
        if account.archived_at is None:
            account.archived_at = utc_now()
            self._touch(account)
            await self.session.commit()
            await self.session.refresh(account)
        impacts = await self.repository.balance_impacts([account.id])
        return self.response(account, impacts.get(account.id, 0))

    async def restore(self, account_id: UUID, expected_version: int) -> AccountResponse:
        await acquire_p2_mutation_lock(self.session)
        account = await self._required(account_id, for_update=True)
        check_version(account.version, expected_version)
        if account.archived_at is not None:
            if await self.repository.active_name_exists(account.name, excluding=account.id):
                conflict("account_name_conflict", "An active account already uses this name")
            account.archived_at = None
            self._touch(account)
            await self._commit_name_safe()
            await self.session.refresh(account)
        impacts = await self.repository.balance_impacts([account.id])
        return self.response(account, impacts.get(account.id, 0))

    async def delete(self, account_id: UUID, expected_version: int) -> None:
        await acquire_p2_mutation_lock(self.session)
        account = await self._required(account_id, for_update=True)
        check_version(account.version, expected_version)
        if account.usage_count != 0:
            conflict("account_in_use", "The account is referenced and cannot be deleted")
        await self.repository.delete(account)
        try:
            await self.session.commit()
        except IntegrityError:
            await self.session.rollback()
            conflict("account_in_use", "The account is referenced and cannot be deleted")

    async def reorder(self, ordered_ids: list[UUID]) -> list[AccountResponse]:
        await acquire_p2_mutation_lock(self.session)
        accounts = await self.repository.list(include_archived=False, for_update=True)
        if len(ordered_ids) != len(set(ordered_ids)) or set(ordered_ids) != {
            account.id for account in accounts
        }:
            invalid(
                "invalid_account_configuration",
                "ordered_ids must contain every active account exactly once",
            )
        by_id = {account.id: account for account in accounts}
        for order, account_id in enumerate(ordered_ids):
            account = by_id[account_id]
            account.sort_order = order
            self._touch(account)
        await self.session.commit()
        impacts = await self.repository.balance_impacts(ordered_ids)
        return [
            self.response(by_id[account_id], impacts.get(account_id, 0))
            for account_id in ordered_ids
        ]

    async def _required(self, account_id: UUID, *, for_update: bool = False) -> Account:
        account = await self.repository.get(account_id, for_update=for_update)
        if account is None:
            not_found("account_not_found", "The account does not exist")
        return account

    async def _commit_name_safe(self) -> None:
        try:
            await self.session.commit()
        except IntegrityError as error:
            await self.session.rollback()
            if "uq_accounts_active_name_ci" in str(error.orig):
                conflict("account_name_conflict", "An active account already uses this name")
            raise

    @staticmethod
    def _touch(account: Account) -> None:
        account.version += 1
        account.updated_at = utc_now()

    @staticmethod
    def _validate_configuration(
        *,
        kind: AccountKind,
        opening: int,
        limit: int | None,
        statement_day: int | None,
        due_day: int | None,
        opening_as_of: date | None,
        opening_due: date | None,
        today: date,
    ) -> None:
        checked_int64(opening, label="account opening balance")
        if limit is not None:
            checked_int64(limit, label="credit limit")
        if kind is AccountKind.CREDIT:
            valid = (
                limit is not None
                and limit > 0
                and statement_day is not None
                and 1 <= statement_day <= 28
                and due_day is not None
                and 1 <= due_day <= 28
                and opening >= 0
                and (
                    (opening == 0 and opening_as_of is None and opening_due is None)
                    or (
                        opening > 0
                        and opening_as_of is not None
                        and opening_due is not None
                        and opening_as_of <= today
                        and opening_due >= opening_as_of
                    )
                )
            )
        else:
            valid = (
                limit is None
                and statement_day is None
                and due_day is None
                and opening_as_of is None
                and opening_due is None
            )
        if not valid:
            invalid("invalid_account_configuration", "The account fields do not match its kind")
