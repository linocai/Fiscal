from __future__ import annotations

from uuid import UUID

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p2_schemas import AccountDraft, AccountPatch, AccountResponse
from fiscal_api.core.time import utc_now
from fiscal_api.db.models import Account, AccountKind
from fiscal_api.repositories.accounts import AccountRepository
from fiscal_api.services.common import (
    acquire_p2_mutation_lock,
    check_version,
    conflict,
    invalid,
    not_found,
)


class AccountService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = AccountRepository(session)

    @staticmethod
    def response(account: Account) -> AccountResponse:
        return AccountResponse.model_validate(account)

    async def list(self, *, include_archived: bool) -> list[AccountResponse]:
        return [
            self.response(item)
            for item in await self.repository.list(include_archived=include_archived)
        ]

    async def get(self, account_id: UUID) -> AccountResponse:
        return self.response(await self._required(account_id))

    async def create(self, draft: AccountDraft) -> AccountResponse:
        await acquire_p2_mutation_lock(self.session)
        self._validate_configuration(
            kind=draft.kind,
            opening=draft.opening_balance_minor,
            limit=draft.credit_limit_minor,
            statement_day=draft.statement_day,
            due_day=draft.due_day,
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
            sort_order=await self.repository.next_sort_order(),
        )
        self.repository.add(account)
        await self._commit_name_safe()
        await self.session.refresh(account)
        return self.response(account)

    async def update(self, account_id: UUID, patch: AccountPatch) -> AccountResponse:
        await acquire_p2_mutation_lock(self.session)
        account = await self._required(account_id, for_update=True)
        check_version(account.version, patch.expected_version)
        updates = patch.model_dump(exclude={"expected_version"}, exclude_unset=True)
        kind = AccountKind(updates.get("kind", account.kind))
        opening = updates.get("opening_balance_minor", account.opening_balance_minor)
        limit = updates.get("credit_limit_minor", account.credit_limit_minor)
        statement_day = updates.get("statement_day", account.statement_day)
        due_day = updates.get("due_day", account.due_day)
        self._validate_configuration(
            kind=kind,
            opening=opening,
            limit=limit,
            statement_day=statement_day,
            due_day=due_day,
        )
        name = updates.get("name", account.name)
        if account.archived_at is None and await self.repository.active_name_exists(
            name, excluding=account.id
        ):
            conflict("account_name_conflict", "An active account already uses this name")
        for field, value in updates.items():
            setattr(account, field, value.value if isinstance(value, AccountKind) else value)
        self._touch(account)
        await self._commit_name_safe()
        await self.session.refresh(account)
        return self.response(account)

    async def archive(self, account_id: UUID, expected_version: int) -> AccountResponse:
        await acquire_p2_mutation_lock(self.session)
        account = await self._required(account_id, for_update=True)
        check_version(account.version, expected_version)
        if account.archived_at is None:
            account.archived_at = utc_now()
            self._touch(account)
            await self.session.commit()
            await self.session.refresh(account)
        return self.response(account)

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
        return self.response(account)

    async def delete(self, account_id: UUID, expected_version: int) -> None:
        await acquire_p2_mutation_lock(self.session)
        account = await self._required(account_id, for_update=True)
        check_version(account.version, expected_version)
        if account.usage_count != 0:
            conflict("account_in_use", "The account is referenced and cannot be deleted")
        await self.repository.delete(account)
        await self.session.commit()

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
        return [self.response(by_id[account_id]) for account_id in ordered_ids]

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
    ) -> None:
        if kind is AccountKind.CREDIT:
            valid = (
                limit is not None
                and limit > 0
                and statement_day is not None
                and 1 <= statement_day <= 28
                and due_day is not None
                and 1 <= due_day <= 28
                and 0 <= opening <= limit
            )
        else:
            valid = limit is None and statement_day is None and due_day is None
        if not valid:
            invalid("invalid_account_configuration", "The account fields do not match its kind")
