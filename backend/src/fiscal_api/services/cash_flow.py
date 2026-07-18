from __future__ import annotations

import hashlib
import json
from calendar import monthrange
from collections.abc import Iterable
from datetime import date, timedelta
from uuid import UUID, uuid5

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p13_schemas import (
    CashFlowAction,
    CashFlowActiveResponse,
    CashFlowCreateResponse,
    CashFlowDraft,
    CashFlowHistoryResponse,
    CashFlowItemResponse,
    CashFlowMutationScope,
    CashFlowReplace,
    CashFlowSettlementDraft,
    CashFlowSummary,
    CashFlowSystemKind,
    CashFlowSystemReplace,
)
from fiscal_api.core.time import BUSINESS_TIMEZONE, utc_now
from fiscal_api.db.models import (
    Account,
    CashFlowDirection,
    CashFlowItem,
    CashFlowItemRevision,
    CashFlowRevisionEvent,
    CashFlowSeries,
    CashFlowSource,
    CashFlowStatus,
    CashFlowSystemOverride,
    Category,
    TransactionKind,
)
from fiscal_api.repositories.cash_flow import CashFlowRepository
from fiscal_api.repositories.reporting import ReimbursementFact, ReportingRepository
from fiscal_api.repositories.transactions import TransactionRepository
from fiscal_api.services.common import (
    acquire_mutation_lock,
    check_version,
    checked_int64,
    conflict,
    invalid,
    not_found,
)
from fiscal_api.services.reporting import ReportingService
from fiscal_api.services.transactions import TransactionService


class CashFlowService:
    MAX_OCCURRENCES = 120

    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = CashFlowRepository(session)
        self.reporting_repository = ReportingRepository(session)

    async def active(self, *, account_id: UUID | None = None) -> CashFlowActiveResponse:
        today = self._today()
        items = [
            await self._manual_response(item, today)
            for item in await self.repository.active(account_id)
        ]
        items.extend(await self._system_items(today, account_id=account_id))
        items.sort(key=lambda item: (not item.is_overdue, item.expected_date, item.title, item.id))
        window_end = today + timedelta(days=29)
        in_window = [item for item in items if today <= item.expected_date <= window_end]
        inflow = self._sum(
            item.planned_amount_minor
            for item in in_window
            if item.direction is CashFlowDirection.INFLOW
        )
        outflow = self._sum(
            item.planned_amount_minor
            for item in in_window
            if item.direction is CashFlowDirection.OUTFLOW
        )
        return CashFlowActiveResponse(
            summary=CashFlowSummary(
                date_from=today,
                date_to=window_end,
                inflow_minor=inflow,
                outflow_minor=outflow,
                net_minor=checked_int64(inflow - outflow, label="future cash flow net"),
            ),
            items=items,
        )

    async def history(self, month: str | None) -> CashFlowHistoryResponse:
        month_value, start, end = self._month_range(month)
        items = [
            await self._manual_response(item, self._today())
            for item in await self.repository.history(start, end)
        ]
        items.extend(
            self._system_override_response(item, self._today())
            for item in await self.repository.system_history(start, end)
        )
        items.sort(key=lambda item: (item.expected_date, item.id), reverse=True)
        return CashFlowHistoryResponse(month=month_value, items=items)

    async def get(self, item_id: UUID) -> CashFlowItemResponse:
        return await self._manual_response(await self._required(item_id), self._today())

    async def create(
        self,
        draft: CashFlowDraft,
        idempotency_key: UUID,
        *,
        source: CashFlowSource = CashFlowSource.MANUAL,
        legacy_source_ids: list[str] | None = None,
        commit: bool = True,
    ) -> CashFlowCreateResponse:
        await acquire_mutation_lock(self.session)
        request_hash = self._request_hash(draft, source)
        if draft.recurrence is None:
            existing = await self.repository.by_idempotency_key(idempotency_key)
            if existing is not None:
                self._assert_idempotent(existing.request_hash, request_hash)
                return CashFlowCreateResponse(
                    items=[await self._manual_response(existing, self._today())]
                )
            await self._validate_references(draft)
            item = self._new_item(
                draft,
                idempotency_key,
                request_hash,
                source=source,
                legacy_source_id=legacy_source_ids[0] if legacy_source_ids else None,
            )
            self.repository.add_item(item)
            await self.session.flush()
            self._revision(item, CashFlowRevisionEvent.CREATED)
            if commit:
                await self.session.commit()
            else:
                await self.session.flush()
            return CashFlowCreateResponse(items=[await self._manual_response(item, self._today())])

        existing_series = await self.repository.series_by_idempotency_key(idempotency_key)
        if existing_series is not None:
            self._assert_idempotent(existing_series.request_hash, request_hash)
            return CashFlowCreateResponse(
                items=[
                    await self._manual_response(item, self._today())
                    for item in existing_series.items
                ]
            )
        await self._validate_references(draft)
        assert draft.recurrence_end_date is not None
        dates = self._monthly_dates(draft.expected_date, draft.recurrence_end_date)
        if len(dates) > self.MAX_OCCURRENCES:
            invalid(
                "cash_flow_series_too_long",
                "A cash flow series may contain at most 120 occurrences",
            )
        series = CashFlowSeries(
            recurrence=draft.recurrence.value,
            anchor_day=draft.expected_date.day,
            end_date=draft.recurrence_end_date,
            idempotency_key=idempotency_key,
            request_hash=request_hash,
        )
        self.repository.add_series(series)
        await self.session.flush()
        items: list[CashFlowItem] = []
        for index, expected_date in enumerate(dates):
            occurrence = draft.model_copy(
                update={
                    "expected_date": expected_date,
                    "recurrence": None,
                    "recurrence_end_date": None,
                }
            )
            item = self._new_item(
                occurrence,
                uuid5(idempotency_key, expected_date.isoformat()),
                request_hash,
                source=source,
                series_id=series.id,
                legacy_source_id=(
                    legacy_source_ids[index]
                    if legacy_source_ids and index < len(legacy_source_ids)
                    else None
                ),
            )
            self.repository.add_item(item)
            items.append(item)
        await self.session.flush()
        for item in items:
            self._revision(item, CashFlowRevisionEvent.CREATED)
        if commit:
            await self.session.commit()
        else:
            await self.session.flush()
        return CashFlowCreateResponse(
            items=[await self._manual_response(item, self._today()) for item in items]
        )

    async def update(self, item_id: UUID, request: CashFlowReplace) -> CashFlowCreateResponse:
        await acquire_mutation_lock(self.session)
        item = await self._required(item_id, for_update=True)
        check_version(item.version, request.expected_version)
        if (
            item.status not in {CashFlowStatus.EXPECTED.value, CashFlowStatus.CONFIRMED.value}
            and request.scope is not CashFlowMutationScope.OCCURRENCE
        ):
            conflict(
                "cash_flow_completed_scope_invalid",
                "Completed cash flow records may only be edited individually",
            )
        await self._validate_references(request)
        targets = await self._targets(item, request.scope)
        if request.scope is CashFlowMutationScope.THIS_AND_FUTURE and item.series_id is not None:
            for target in targets:
                if target.status in {CashFlowStatus.SETTLED.value, CashFlowStatus.CANCELLED.value}:
                    continue
                month_offset = self._month_offset(item.expected_date, target.expected_date)
                shifted_date = self._add_months(request.expected_date, month_offset)
                self._apply_draft(target, request, expected_date=shifted_date)
                self._touch(target, CashFlowRevisionEvent.UPDATED)
        else:
            self._apply_draft(item, request)
            self._touch(item, CashFlowRevisionEvent.UPDATED)
        await self.session.commit()
        return CashFlowCreateResponse(
            items=[await self._manual_response(target, self._today()) for target in targets]
        )

    async def update_system(
        self,
        system_kind: CashFlowSystemKind,
        reference_id: UUID,
        request: CashFlowSystemReplace,
    ) -> CashFlowItemResponse:
        if system_kind is CashFlowSystemKind.CREDIT_CYCLE:
            conflict(
                "cash_flow_credit_projection_read_only",
                "Credit repayment cash flow is derived from ledger debt and cannot be edited",
            )
        await acquire_mutation_lock(self.session)
        override = await self.repository.system_override(
            system_kind.value, reference_id, for_update=True
        )
        if override is not None:
            check_version(override.version, request.expected_version)
        elif request.expected_version != 1:
            conflict("version_conflict", "The cash flow item changed on another device")

        base = next(
            (
                item
                for item in await self._raw_system_items(self._today(), account_id=None)
                if item.system_kind is system_kind and item.system_reference_id == reference_id
            ),
            None,
        )
        if base is None and override is None:
            not_found("cash_flow_system_item_not_found", "The system cash flow item was not found")

        completed_at = utc_now() if request.status is CashFlowStatus.COMPLETED else None
        if override is None:
            assert base is not None
            override = CashFlowSystemOverride(
                system_kind=system_kind.value,
                system_reference_id=reference_id,
                title=request.title,
                note=request.note,
                direction=base.direction.value,
                planned_amount_minor=request.planned_amount_minor,
                expected_date=request.expected_date,
                account_id=base.account_id,
                status=request.status.value,
                version=2,
                completed_at=completed_at,
            )
            self.repository.add_system_override(override)
        else:
            override.title = request.title
            override.note = request.note
            override.planned_amount_minor = request.planned_amount_minor
            override.expected_date = request.expected_date
            override.status = request.status.value
            override.completed_at = completed_at
            override.version += 1
            override.updated_at = utc_now()
        await self.session.commit()
        return self._system_override_response(override, self._today())

    async def confirm(self, item_id: UUID, expected_version: int) -> CashFlowItemResponse:
        await acquire_mutation_lock(self.session)
        item = await self._required(item_id, for_update=True)
        check_version(item.version, expected_version)
        if item.status == CashFlowStatus.CONFIRMED.value:
            return await self._manual_response(item, self._today())
        if item.status != CashFlowStatus.EXPECTED.value:
            conflict("cash_flow_cannot_confirm", "Only expected cash flow items can be confirmed")
        item.status = CashFlowStatus.CONFIRMED.value
        self._touch(item, CashFlowRevisionEvent.CONFIRMED)
        await self.session.commit()
        return await self._manual_response(item, self._today())

    async def cancel(
        self, item_id: UUID, expected_version: int, scope: CashFlowMutationScope
    ) -> CashFlowCreateResponse:
        await acquire_mutation_lock(self.session)
        item = await self._required(item_id, for_update=True)
        check_version(item.version, expected_version)
        targets = await self._targets(item, scope)
        changed: list[CashFlowItem] = []
        for target in targets:
            if target.status in {CashFlowStatus.EXPECTED.value, CashFlowStatus.CONFIRMED.value}:
                self._cancel(target)
                changed.append(target)
        if not changed and item.status != CashFlowStatus.CANCELLED.value:
            conflict("cash_flow_cannot_cancel", "Only pending cash flow items can be cancelled")
        await self.session.commit()
        return CashFlowCreateResponse(
            items=[
                await self._manual_response(target, self._today()) for target in (changed or [item])
            ]
        )

    async def settle(
        self, item_id: UUID, request: CashFlowSettlementDraft, idempotency_key: UUID
    ) -> CashFlowItemResponse:
        await acquire_mutation_lock(self.session)
        item = await self._required(item_id, for_update=True)
        if item.status == CashFlowStatus.SETTLED.value:
            if item.linked_transaction_id is None:
                raise RuntimeError("settled cash flow is missing its ledger transaction")
            return await self._manual_response(item, self._today())
        check_version(item.version, request.expected_version)
        if item.status != CashFlowStatus.CONFIRMED.value:
            conflict("cash_flow_not_confirmed", "Only confirmed cash flow items can be settled")
        kind = {
            CashFlowDirection.INFLOW.value: TransactionKind.INCOME,
            CashFlowDirection.OUTFLOW.value: TransactionKind.EXPENSE,
            CashFlowDirection.TRANSFER.value: TransactionKind.TRANSFER,
        }[item.direction]
        if kind is TransactionKind.TRANSFER and request.destination_account_id is None:
            invalid("cash_flow_destination_required", "A transfer requires a destination account")
        if kind is not TransactionKind.TRANSFER and request.destination_account_id is not None:
            invalid(
                "cash_flow_destination_not_allowed", "Only transfers have a destination account"
            )
        transaction = await TransactionService(self.session).create_cash_flow(
            TransactionDraft(
                kind=kind,
                amount_minor=request.actual_amount_minor,
                occurred_at=request.occurred_at,
                title=request.title or item.title,
                note=request.note if request.note is not None else item.note,
                account_id=request.account_id,
                destination_account_id=request.destination_account_id,
                category_id=request.category_id,
            ),
            idempotency_key,
            commit=False,
        )
        item.status = CashFlowStatus.SETTLED.value
        item.linked_transaction_id = transaction.id
        item.settled_at = utc_now()
        item.cancelled_at = None
        self._touch(item, CashFlowRevisionEvent.SETTLED)
        await self.session.commit()
        return await self._manual_response(item, self._today())

    async def sync_linked_transaction(self, transaction_id: UUID, *, voided: bool) -> None:
        item = await self.repository.by_linked_transaction(transaction_id, for_update=True)
        if item is None:
            return
        desired = CashFlowStatus.CONFIRMED if voided else CashFlowStatus.SETTLED
        if item.status == desired.value:
            return
        item.status = desired.value
        item.settled_at = None if voided else utc_now()
        self._touch(
            item,
            CashFlowRevisionEvent.REOPENED if voided else CashFlowRevisionEvent.SETTLED,
        )

    async def _system_items(
        self, today: date, *, account_id: UUID | None
    ) -> list[CashFlowItemResponse]:
        raw = await self._raw_system_items(today, account_id=account_id)
        overrides = {
            (item.system_kind, item.system_reference_id): item
            for item in await self.repository.system_overrides()
        }
        result: list[CashFlowItemResponse] = []
        for item in raw:
            assert item.system_kind is not None and item.system_reference_id is not None
            override = overrides.get((item.system_kind.value, item.system_reference_id))
            if override is not None:
                if override.status == CashFlowStatus.COMPLETED.value:
                    continue
                result.append(self._system_override_response(override, today))
            else:
                actions = list(item.actions)
                if item.system_kind is not CashFlowSystemKind.CREDIT_CYCLE:
                    actions.append(CashFlowAction.EDIT)
                result.append(item.model_copy(update={"actions": actions}))
        return result

    async def _raw_system_items(
        self, today: date, *, account_id: UUID | None
    ) -> list[CashFlowItemResponse]:
        result: list[CashFlowItemResponse] = []
        debt = await ReportingService(self.session).debt(as_of=today)
        for cycle in debt.cycles:
            if cycle.remaining_minor <= 0 or (
                account_id is not None and cycle.account_id != account_id
            ):
                continue
            result.append(
                CashFlowItemResponse(
                    id=f"credit_cycle:{cycle.cycle_id}",
                    system_kind=CashFlowSystemKind.CREDIT_CYCLE,
                    system_reference_id=cycle.cycle_id,
                    title=f"{cycle.account_name} 账单应还",
                    direction=CashFlowDirection.OUTFLOW,
                    planned_amount_minor=cycle.remaining_minor,
                    expected_date=cycle.due_date,
                    account_id=cycle.account_id,
                    status=CashFlowStatus.CONFIRMED,
                    source="system",
                    version=1,
                    is_overdue=cycle.due_date < today,
                    actions=[CashFlowAction.CONFIRM_REPAYMENT],
                )
            )
        party_values: dict[UUID, tuple[ReimbursementFact, int]] = {}
        for fact in await self.reporting_repository.reimbursement_facts():
            if (
                fact.claim_voided_at is not None
                or fact.cancelled_at is not None
                or fact.submitted_at is None
            ):
                continue
            outstanding = checked_int64(
                fact.allocated_minor - fact.received_minor, label="reimbursement outstanding"
            )
            if outstanding <= 0:
                continue
            current = party_values.get(fact.party_id)
            total = outstanding if current is None else checked_int64(current[1] + outstanding)
            party_values[fact.party_id] = (fact, total)
        for fact_value, amount in party_values.values():
            fact = fact_value
            expected = fact.expected_date or today
            result.append(
                CashFlowItemResponse(
                    id=f"reimbursement:{fact.party_id}",
                    system_kind=CashFlowSystemKind.REIMBURSEMENT,
                    system_reference_id=fact.party_id,
                    title=f"{fact.party_name} 报销待到账",
                    direction=CashFlowDirection.INFLOW,
                    planned_amount_minor=amount,
                    expected_date=expected,
                    status=CashFlowStatus.CONFIRMED,
                    source="system",
                    version=1,
                    is_overdue=expected < today,
                    actions=[CashFlowAction.MARK_RECEIVED],
                )
            )
        return result

    @staticmethod
    def _system_override_response(
        item: CashFlowSystemOverride, today: date
    ) -> CashFlowItemResponse:
        kind = CashFlowSystemKind(item.system_kind)
        status = CashFlowStatus(item.status)
        domain_action = (
            CashFlowAction.CONFIRM_REPAYMENT
            if kind is CashFlowSystemKind.CREDIT_CYCLE
            else CashFlowAction.MARK_RECEIVED
        )
        actions = [CashFlowAction.EDIT]
        if status is CashFlowStatus.CONFIRMED:
            actions.insert(0, domain_action)
        return CashFlowItemResponse(
            id=f"{item.system_kind}:{item.system_reference_id}",
            system_kind=kind,
            system_reference_id=item.system_reference_id,
            title=item.title,
            note=item.note,
            direction=CashFlowDirection(item.direction),
            planned_amount_minor=item.planned_amount_minor,
            expected_date=item.expected_date,
            account_id=item.account_id,
            status=status,
            source="system",
            version=item.version,
            is_overdue=status is CashFlowStatus.CONFIRMED and item.expected_date < today,
            actions=actions,
            created_at=item.created_at,
            updated_at=item.updated_at,
        )

    async def _manual_response(self, item: CashFlowItem, today: date) -> CashFlowItemResponse:
        actual_amount: int | None = None
        actual_date: date | None = None
        if item.linked_transaction_id is not None:
            transaction = await TransactionRepository(self.session).get(item.linked_transaction_id)
            if transaction is not None:
                primary = min(transaction.postings, key=lambda posting: posting.position)
                actual_amount = abs(primary.amount_minor)
                actual_date = transaction.occurred_at.astimezone(BUSINESS_TIMEZONE).date()
        status = CashFlowStatus(item.status)
        actions: list[CashFlowAction] = []
        if status is CashFlowStatus.EXPECTED:
            actions = [CashFlowAction.CONFIRM, CashFlowAction.EDIT, CashFlowAction.CANCEL]
        elif status is CashFlowStatus.CONFIRMED:
            actions = [CashFlowAction.SETTLE, CashFlowAction.EDIT, CashFlowAction.CANCEL]
        else:
            actions = [CashFlowAction.EDIT]
        return CashFlowItemResponse(
            id=str(item.id),
            manual_item_id=item.id,
            series_id=item.series_id,
            title=item.title,
            note=item.note,
            direction=CashFlowDirection(item.direction),
            planned_amount_minor=item.planned_amount_minor,
            expected_date=item.expected_date,
            account_id=item.account_id,
            destination_account_id=item.destination_account_id,
            category_id=item.category_id,
            status=status,
            source=CashFlowSource(item.source),
            version=item.version,
            linked_transaction_id=item.linked_transaction_id,
            actual_amount_minor=actual_amount,
            actual_date=actual_date,
            is_overdue=status in {CashFlowStatus.EXPECTED, CashFlowStatus.CONFIRMED}
            and item.expected_date < today,
            actions=actions,
            created_at=item.created_at,
            updated_at=item.updated_at,
        )

    async def _required(self, item_id: UUID, *, for_update: bool = False) -> CashFlowItem:
        item = await self.repository.get(item_id, for_update=for_update)
        if item is None:
            not_found("cash_flow_not_found", "Cash flow item was not found")
        return item

    async def _targets(
        self, item: CashFlowItem, scope: CashFlowMutationScope
    ) -> list[CashFlowItem]:
        if scope is CashFlowMutationScope.OCCURRENCE or item.series_id is None:
            return [item]
        return await self.repository.series_items_from(
            item.series_id, item.expected_date, for_update=True
        )

    async def _validate_references(self, draft: CashFlowDraft) -> None:
        account_ids = {draft.account_id, draft.destination_account_id} - {None}
        if account_ids:
            accounts = list(
                (
                    await self.session.scalars(select(Account).where(Account.id.in_(account_ids)))
                ).all()
            )
            if len(accounts) != len(account_ids) or any(
                account.archived_at is not None for account in accounts
            ):
                invalid("invalid_cash_flow_account", "Cash flow accounts must be active")
        if draft.category_id is not None:
            category = await self.session.get(Category, draft.category_id)
            expected_direction = (
                "income" if draft.direction is CashFlowDirection.INFLOW else "expense"
            )
            if (
                category is None
                or category.archived_at is not None
                or category.direction != expected_direction
            ):
                invalid("invalid_cash_flow_category", "Category direction does not match cash flow")

    @staticmethod
    def _new_item(
        draft: CashFlowDraft,
        idempotency_key: UUID,
        request_hash: str,
        *,
        source: CashFlowSource,
        series_id: UUID | None = None,
        legacy_source_id: str | None = None,
    ) -> CashFlowItem:
        return CashFlowItem(
            series_id=series_id,
            title=draft.title,
            note=draft.note,
            direction=draft.direction.value,
            planned_amount_minor=draft.planned_amount_minor,
            expected_date=draft.expected_date,
            account_id=draft.account_id,
            destination_account_id=draft.destination_account_id,
            category_id=draft.category_id,
            source=source.value,
            idempotency_key=idempotency_key,
            request_hash=request_hash,
            legacy_source_id=legacy_source_id,
        )

    @staticmethod
    def _apply_draft(
        item: CashFlowItem, draft: CashFlowDraft, *, expected_date: date | None = None
    ) -> None:
        item.title = draft.title
        item.note = draft.note
        item.direction = draft.direction.value
        item.planned_amount_minor = draft.planned_amount_minor
        item.expected_date = expected_date if expected_date is not None else draft.expected_date
        item.account_id = draft.account_id
        item.destination_account_id = draft.destination_account_id
        item.category_id = draft.category_id

    def _cancel(self, item: CashFlowItem) -> None:
        item.status = CashFlowStatus.CANCELLED.value
        item.cancelled_at = utc_now()
        self._touch(item, CashFlowRevisionEvent.CANCELLED)

    def _touch(self, item: CashFlowItem, event: CashFlowRevisionEvent) -> None:
        item.version += 1
        item.updated_at = utc_now()
        self._revision(item, event)

    def _revision(self, item: CashFlowItem, event: CashFlowRevisionEvent) -> None:
        self.repository.add_revision(
            CashFlowItemRevision(
                item_id=item.id,
                version=item.version,
                event=event.value,
                snapshot=self._snapshot(item),
            )
        )

    @staticmethod
    def _snapshot(item: CashFlowItem) -> dict[str, object]:
        return {
            "id": str(item.id),
            "series_id": str(item.series_id) if item.series_id else None,
            "title": item.title,
            "note": item.note,
            "direction": item.direction,
            "planned_amount_minor": item.planned_amount_minor,
            "expected_date": item.expected_date.isoformat(),
            "account_id": str(item.account_id) if item.account_id else None,
            "destination_account_id": (
                str(item.destination_account_id) if item.destination_account_id else None
            ),
            "category_id": str(item.category_id) if item.category_id else None,
            "status": item.status,
            "source": item.source,
            "linked_transaction_id": (
                str(item.linked_transaction_id) if item.linked_transaction_id else None
            ),
            "version": item.version,
        }

    @staticmethod
    def _request_hash(draft: CashFlowDraft, source: CashFlowSource) -> str:
        payload = draft.model_dump(mode="json")
        payload["source"] = source.value
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        return hashlib.sha256(canonical.encode()).hexdigest()

    @staticmethod
    def _assert_idempotent(existing_hash: str, request_hash: str) -> None:
        if existing_hash != request_hash:
            conflict(
                "idempotency_key_reused",
                "The idempotency key was already used for a different cash flow request",
            )

    @staticmethod
    def _monthly_dates(start: date, end: date) -> list[date]:
        result: list[date] = []
        cursor = start
        offset = 0
        while cursor <= end:
            result.append(cursor)
            offset += 1
            cursor = CashFlowService._add_months(start, offset)
        return result

    @staticmethod
    def _add_months(value: date, offset: int) -> date:
        month_index = value.year * 12 + value.month - 1 + offset
        year, month_zero = divmod(month_index, 12)
        month = month_zero + 1
        return date(year, month, min(value.day, monthrange(year, month)[1]))

    @staticmethod
    def _month_offset(start: date, value: date) -> int:
        return (value.year - start.year) * 12 + value.month - start.month

    @staticmethod
    def _sum(values: Iterable[int]) -> int:
        total = 0
        for value in values:
            total = checked_int64(total + value, label="cash flow total")
        return total

    @staticmethod
    def _today() -> date:
        return utc_now().astimezone(BUSINESS_TIMEZONE).date()

    @classmethod
    def _month_range(cls, month: str | None) -> tuple[str, date, date]:
        today = cls._today()
        value = month or f"{today.year:04d}-{today.month:02d}"
        try:
            year, month_number = (int(part) for part in value.split("-"))
            start = date(year, month_number, 1)
        except (TypeError, ValueError):
            invalid("invalid_cash_flow_month", "month must use YYYY-MM")
        end = cls._add_months(start, 1)
        return value, start, end
