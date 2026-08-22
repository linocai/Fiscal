from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field
from datetime import date, datetime
from typing import Any, Literal
from uuid import UUID, uuid5

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p2_schemas import AccountDraft, CategoryDraft
from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p6_schemas import (
    ReimbursementAllocationDraft,
    ReimbursementClaimDraft,
    ReimbursementPartyDraft,
    ReimbursementReceiptDraft,
)
from fiscal_api.core.time import utc_now
from fiscal_api.db.models import (
    AccountKind,
    CategoryDirection,
    MigrationObjectLink,
    MigrationRun,
    MigrationRunMode,
    MigrationRunStatus,
    TransactionKind,
)
from fiscal_api.repositories.credit import CreditRepository
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.reimbursements import ReimbursementService
from fiscal_api.services.transactions import TransactionService

MIGRATION_NAMESPACE = UUID("432d62f4-03cb-4ac5-8ba4-3854d538ce36")


class LegacyApplyConflict(RuntimeError):
    """The target cannot safely apply the supplied legacy manifest."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class SourceIdentity:
    object_type: str
    object_id: str
    content_hash: str


@dataclass(frozen=True)
class AccountImport:
    source: SourceIdentity
    name: str
    kind: Literal["cash", "debit", "credit"]
    opening_balance_minor: int
    institution: str | None = None
    last_four: str | None = None
    credit_limit_minor: int | None = None
    statement_day: int | None = None
    due_day: int | None = None
    opening_balance_as_of_date: date | None = None
    opening_due_date: date | None = None


@dataclass(frozen=True)
class CategoryImport:
    source: SourceIdentity
    name: str
    direction: Literal["income", "expense"]
    icon: str = "tray.full"
    color_hex: str = "#64748B"


@dataclass(frozen=True)
class TransactionImport:
    source: SourceIdentity
    kind: Literal["income", "expense", "transfer", "credit_purchase", "repayment"]
    amount_minor: int
    occurred_at: datetime
    title: str
    account_source_id: str
    note: str | None = None
    category_source_id: str | None = None
    destination_account_source_id: str | None = None
    credit_cycle_id: UUID | None = None
    credit_cycle_selector: Literal["opening", "period"] | None = None
    credit_cycle_period_start: date | None = None
    credit_cycle_period_end: date | None = None


@dataclass(frozen=True)
class ClaimImport:
    source: SourceIdentity
    title: str
    expense_transaction_source_id: str
    amount_minor: int
    party_name: str
    expected_date: date | None = None
    note: str | None = None


@dataclass(frozen=True)
class ReceiptImport:
    source: SourceIdentity
    claim_source_id: str
    destination_account_source_id: str
    amount_minor: int
    received_at: datetime
    title: str
    suppressed_income_source_id: str
    note: str | None = None


@dataclass(frozen=True)
class SkippedImport:
    source: SourceIdentity
    reason: str


@dataclass(frozen=True)
class LegacyManifest:
    source_database_fingerprint: str
    accounts: tuple[AccountImport, ...] = ()
    categories: tuple[CategoryImport, ...] = ()
    transactions: tuple[TransactionImport, ...] = ()
    claims: tuple[ClaimImport, ...] = ()
    receipts: tuple[ReceiptImport, ...] = ()
    skipped: tuple[SkippedImport, ...] = ()
    selection_scope: dict[str, object] = field(default_factory=lambda: dict[str, object]())


@dataclass(frozen=True)
class ApplyResult:
    run_id: UUID
    created: int
    unchanged: int
    skipped: int


class LegacyShadowApplier:
    """Apply a fully resolved P12 manifest through Fiscal domain services."""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def apply(
        self,
        manifest: LegacyManifest,
        *,
        code_revision: str,
        mode: MigrationRunMode = MigrationRunMode.SHADOW,
    ) -> ApplyResult:
        self._validate(manifest)
        payload = _jsonable(asdict(manifest))
        manifest_hash = _digest(payload)
        run_id = _stable_uuid(manifest.source_database_fingerprint, "run", manifest_hash)
        run = MigrationRun(
            id=run_id,
            mode=mode.value,
            status=MigrationRunStatus.RUNNING.value,
            source_system="linofinance",
            source_database_fingerprint=manifest.source_database_fingerprint,
            source_manifest_hash=manifest_hash,
            source_manifest=payload,
            selection_scope=manifest.selection_scope,
            code_revision=code_revision,
        )
        existing_run = await self.session.get(MigrationRun, run_id)
        if existing_run is None:
            self.session.add(run)
            await self.session.commit()
        else:
            run = existing_run

        created = unchanged = 0
        targets: dict[tuple[str, str], UUID] = {}
        try:
            for item in manifest.accounts:
                target, was_created = await self._account(run, manifest, item)
                targets[(item.source.object_type, item.source.object_id)] = target
                created += was_created
                unchanged += not was_created
            for item in manifest.categories:
                target, was_created = await self._category(run, manifest, item)
                targets[(item.source.object_type, item.source.object_id)] = target
                created += was_created
                unchanged += not was_created
            for item in manifest.transactions:
                target, was_created = await self._transaction(run, manifest, item, targets)
                targets[(item.source.object_type, item.source.object_id)] = target
                created += was_created
                unchanged += not was_created
            for item in manifest.claims:
                target, was_created = await self._claim(run, manifest, item, targets)
                targets[(item.source.object_type, item.source.object_id)] = target
                created += was_created
                unchanged += not was_created
            for item in manifest.receipts:
                target, was_created = await self._receipt(run, manifest, item, targets)
                targets[(item.source.object_type, item.source.object_id)] = target
                created += was_created
                unchanged += not was_created
        except BaseException:
            await self.session.rollback()
            run = await self.session.get(MigrationRun, run_id)
            if run is not None:
                run.status = MigrationRunStatus.FAILED.value
                run.completed_at = utc_now()
                await self.session.commit()
            raise

        run.status = MigrationRunStatus.SUCCEEDED.value
        run.completed_at = utc_now()
        await self.session.commit()
        return ApplyResult(run_id, created, unchanged, len(manifest.skipped))

    async def _account(
        self, run: MigrationRun, manifest: LegacyManifest, item: AccountImport
    ) -> tuple[UUID, bool]:
        replay = await self._replay(manifest, item.source, "account")
        if replay is not None:
            return replay, False
        response = await AccountService(self.session).create(
            AccountDraft(
                name=item.name,
                kind=AccountKind(item.kind),
                institution=item.institution,
                last_four=item.last_four,
                opening_balance_minor=item.opening_balance_minor,
                credit_limit_minor=item.credit_limit_minor,
                statement_day=item.statement_day,
                due_day=item.due_day,
                opening_balance_as_of_date=item.opening_balance_as_of_date,
                opening_due_date=item.opening_due_date,
            ),
            commit=False,
        )
        await self._link(run, manifest, item.source, "account", response.id)
        return response.id, True

    async def _category(
        self, run: MigrationRun, manifest: LegacyManifest, item: CategoryImport
    ) -> tuple[UUID, bool]:
        replay = await self._replay(manifest, item.source, "category")
        if replay is not None:
            return replay, False
        response = await CategoryService(self.session).create(
            CategoryDraft(
                name=item.name,
                direction=CategoryDirection(item.direction),
                icon=item.icon,
                color_hex=item.color_hex,
            ),
            commit=False,
        )
        await self._link(run, manifest, item.source, "category", response.id)
        return response.id, True

    async def _transaction(
        self,
        run: MigrationRun,
        manifest: LegacyManifest,
        item: TransactionImport,
        targets: dict[tuple[str, str], UUID],
    ) -> tuple[UUID, bool]:
        replay = await self._replay(manifest, item.source, "transaction")
        if replay is not None:
            return replay, False
        credit_cycle_id = item.credit_cycle_id
        if item.kind == "repayment" and credit_cycle_id is None:
            credit_account_id = self._target(
                targets, "accounts", item.destination_account_source_id or ""
            )
            repository = CreditRepository(self.session)
            if item.credit_cycle_selector == "opening":
                cycle = await repository.opening_cycle(credit_account_id)
            elif (
                item.credit_cycle_selector == "period"
                and item.credit_cycle_period_start is not None
                and item.credit_cycle_period_end is not None
            ):
                cycle = await repository.cycle_for_period(
                    credit_account_id,
                    item.credit_cycle_period_start,
                    item.credit_cycle_period_end,
                )
            else:
                cycle = None
            if cycle is None:
                raise LegacyApplyConflict("unresolved_credit_cycle", item.source.object_id)
            credit_cycle_id = cycle.id
        draft = TransactionDraft(
            kind=TransactionKind(item.kind),
            amount_minor=item.amount_minor,
            occurred_at=item.occurred_at,
            title=item.title,
            note=item.note,
            account_id=self._target(targets, "accounts", item.account_source_id),
            category_id=(
                self._target(targets, "categories", item.category_source_id)
                if item.category_source_id is not None
                else None
            ),
            destination_account_id=(
                self._target(targets, "accounts", item.destination_account_source_id)
                if item.destination_account_source_id is not None
                else None
            ),
            credit_cycle_id=credit_cycle_id,
        )
        response = await TransactionService(self.session).create_legacy_import(
            draft,
            _stable_uuid(manifest.source_database_fingerprint, *self._key(item.source)),
            commit=False,
        )
        await self._link(run, manifest, item.source, "transaction", response.id)
        return response.id, True

    async def _claim(
        self,
        run: MigrationRun,
        manifest: LegacyManifest,
        item: ClaimImport,
        targets: dict[tuple[str, str], UUID],
    ) -> tuple[UUID, bool]:
        replay = await self._replay(manifest, item.source, "reimbursement_claim")
        if replay is not None:
            return replay, False
        expense_id = self._target(targets, "financial_entries", item.expense_transaction_source_id)
        response = await ReimbursementService(self.session).create(
            ReimbursementClaimDraft(
                title=item.title,
                note=item.note,
                parties=[
                    ReimbursementPartyDraft(
                        name=item.party_name,
                        expected_date=item.expected_date,
                        allocations=[
                            ReimbursementAllocationDraft(
                                transaction_id=expense_id, amount_minor=item.amount_minor
                            )
                        ],
                    )
                ],
            ),
            _stable_uuid(manifest.source_database_fingerprint, *self._key(item.source)),
            commit=False,
        )
        await self._link(run, manifest, item.source, "reimbursement_claim", response.id)
        return response.id, True

    async def _receipt(
        self,
        run: MigrationRun,
        manifest: LegacyManifest,
        item: ReceiptImport,
        targets: dict[tuple[str, str], UUID],
    ) -> tuple[UUID, bool]:
        replay = await self._replay(manifest, item.source, "reimbursement_receipt")
        if replay is not None:
            return replay, False
        claim_id = self._target(targets, "reimbursement_claims", item.claim_source_id)
        service = ReimbursementService(self.session)
        claim = await service.get(claim_id)
        if len(claim.parties) != 1:
            raise LegacyApplyConflict("ambiguous_claim_party", item.source.object_id)
        response = await service.create_receipt(
            claim_id,
            ReimbursementReceiptDraft(
                expected_claim_version=claim.version,
                party_id=claim.parties[0].id,
                amount_minor=item.amount_minor,
                received_at=item.received_at,
                destination_account_id=self._target(
                    targets, "accounts", item.destination_account_source_id
                ),
                title=item.title,
                note=item.note,
            ),
            _stable_uuid(manifest.source_database_fingerprint, *self._key(item.source)),
            commit=False,
        )
        await self._link(run, manifest, item.source, "reimbursement_receipt", response.id)
        return response.id, True

    async def _replay(
        self, manifest: LegacyManifest, source: SourceIdentity, target_type: str
    ) -> UUID | None:
        row = await self.session.scalar(
            select(MigrationObjectLink).where(
                MigrationObjectLink.source_database_fingerprint
                == manifest.source_database_fingerprint,
                MigrationObjectLink.source_object_type == source.object_type,
                MigrationObjectLink.source_object_id == source.object_id,
            )
        )
        if row is None:
            return None
        if row.source_content_hash != source.content_hash:
            raise LegacyApplyConflict(
                "source_hash_changed", f"{source.object_type}:{source.object_id} changed"
            )
        if row.target_object_type != target_type:
            raise LegacyApplyConflict(
                "target_type_changed", f"{source.object_type}:{source.object_id} changed target"
            )
        return row.target_object_id

    async def _link(
        self,
        run: MigrationRun,
        manifest: LegacyManifest,
        source: SourceIdentity,
        target_type: str,
        target_id: UUID,
    ) -> None:
        self.session.add(
            MigrationObjectLink(
                id=_stable_uuid(manifest.source_database_fingerprint, "link", *self._key(source)),
                migration_run_id=run.id,
                source_database_fingerprint=manifest.source_database_fingerprint,
                source_object_type=source.object_type,
                source_object_id=source.object_id,
                source_content_hash=source.content_hash,
                target_object_type=target_type,
                target_object_id=target_id,
            )
        )
        await self.session.commit()

    @staticmethod
    def _target(targets: dict[tuple[str, str], UUID], object_type: str, object_id: str) -> UUID:
        try:
            return targets[(object_type, object_id)]
        except KeyError as error:
            raise LegacyApplyConflict(
                "unresolved_dependency", f"{object_type}:{object_id} is not in the manifest"
            ) from error

    @staticmethod
    def _key(source: SourceIdentity) -> tuple[str, str]:
        return source.object_type, source.object_id

    @staticmethod
    def _validate(manifest: LegacyManifest) -> None:
        if len(manifest.source_database_fingerprint) != 64:
            raise LegacyApplyConflict("invalid_fingerprint", "fingerprint must be sha256")
        all_items: list[Any] = [
            *manifest.accounts,
            *manifest.categories,
            *manifest.transactions,
            *manifest.claims,
            *manifest.receipts,
            *manifest.skipped,
        ]
        identities: set[tuple[str, str]] = set()
        for item in all_items:
            source = item.source
            identity = (source.object_type, source.object_id)
            if identity in identities:
                raise LegacyApplyConflict("duplicate_source_identity", ":".join(identity))
            identities.add(identity)
            if len(source.content_hash) != 64:
                raise LegacyApplyConflict("invalid_source_hash", ":".join(identity))
        imported_entry_ids = {item.source.object_id for item in manifest.transactions}
        for receipt in manifest.receipts:
            if receipt.suppressed_income_source_id in imported_entry_ids:
                raise LegacyApplyConflict(
                    "duplicate_reimbursement_income",
                    "a received reimbursement income must be suppressed in favor of a receipt",
                )


def _stable_uuid(fingerprint: str, *parts: str) -> UUID:
    return uuid5(MIGRATION_NAMESPACE, ":".join((fingerprint, *parts)))


def _jsonable(value: object) -> dict[str, object]:
    return json.loads(json.dumps(value, default=str))


def _digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
