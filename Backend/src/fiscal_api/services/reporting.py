from __future__ import annotations

import base64
import binascii
import json
import re
from calendar import monthrange
from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import TypedDict, cast
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import TransactionResponse
from fiscal_api.api.p6_schemas import ReimbursementClaimResponse, ReimbursementReceiptResponse
from fiscal_api.api.p7_schemas import (
    CashAccountFact,
    CashFacts,
    CashFlowAccountRow,
    CashFlowReport,
    CashFlowTrendPoint,
    CompletenessFacts,
    CompletenessIssueFact,
    CompletenessIssueType,
    CreditCycleFact,
    CreditFacts,
    DebtAccountRow,
    DebtCycleRow,
    DebtInstallmentGroup,
    DebtReport,
    FactsDrillDownItem,
    FactsDrillDownPage,
    FactsDrillDownScope,
    FactsDrillDownScopeType,
    FactsMeta,
    FactsWindow,
    ForecastBasis,
    ForecastCertainty,
    ForecastDirection,
    ForecastEvent,
    ForecastSummary,
    KnownFutureCertainty,
    KnownFutureDirection,
    KnownFutureEvent,
    KnownFutureEventPage,
    KnownFutureSourceType,
    KnownFutureTotals,
    OverviewCashFlowSummary,
    OverviewCreditDueEvent,
    OverviewReport,
    OverviewSpendingSummary,
    ReimbursementFacts,
    ReimbursementOutstandingFact,
    ReportDrillDownPage,
    ReportFacts,
    ReportLens,
    ReportLineItem,
    ReportMeta,
    SpendingAmounts,
    SpendingBucket,
    SpendingCategoryRoot,
    SpendingReport,
    SpendingTrendPoint,
)
from fiscal_api.api.p34_schemas import (
    MAX_REPORT_YEAR,
    MIN_REPORT_YEAR,
    SUPPORTED_REPORT_YEAR_RANGE,
    PeriodReport,
    PeriodReportDrillDownItem,
    PeriodReportDrillDownItemV2,
    PeriodReportDrillDownPage,
    PeriodReportDrillDownPageV2,
    PeriodReportV2,
    ReportAccountBalance,
    ReportCategoryTotal,
    ReportCategoryTotalV2,
    ReportCompleteness,
    ReportDailyPointV2,
    ReportDrillDownDimension,
    ReportMerchantTotal,
    ReportPeriodKind,
    ReportSourceTotal,
    ReportSummary,
)
from fiscal_api.api.p34_schemas import (
    ReportMeta as PeriodReportMeta,
)
from fiscal_api.api.p34_schemas import (
    ReportMetaV2 as PeriodReportMetaV2,
)
from fiscal_api.core.time import BUSINESS_TIMEZONE, UTC, utc_now
from fiscal_api.db.models import (
    Account,
    AccountKind,
    CashFlowDirection,
    CashFlowStatus,
    Category,
    CreditCycle,
    CreditCycleStatus,
    DataRevision,
    InstallmentPeriod,
    InstallmentPlan,
    LedgerTransaction,
    Merchant,
    Posting,
    PostingRole,
    TransactionKind,
    TransactionMerchantMapping,
    TransactionSource,
)
from fiscal_api.repositories.cash_flow import CashFlowRepository
from fiscal_api.repositories.reporting import ReimbursementFact, ReportingRepository
from fiscal_api.services.common import INT64_MIN, checked_int64, conflict, invalid

SPENDING_KINDS = {"expense", "credit_purchase", "installment_fee"}
MONTH_PATTERN = re.compile(r"^(\d{4})-(\d{2})$")
# Asia/Shanghai uses a positive historical offset for 0001-01-01. Converting
# that business boundary to UTC underflows Python's datetime range, so public
# reports begin at 0002. The range is declared in p34_schemas for OpenAPI.
OVERVIEW_RECENT_TRANSACTION_LIMIT = 10
OVERVIEW_CREDIT_DUE_WINDOW_DAYS = 30


@dataclass(frozen=True)
class _SpendingFact:
    transaction: LedgerTransaction
    account_id: UUID
    gross: int
    refund: int
    expected: int
    received: int

    @property
    def net(self) -> int:
        return checked_int64(self.gross - self.refund, label="net consumption")

    @property
    def personal_expected(self) -> int:
        return checked_int64(self.net - self.expected, label="personal expected spending")

    @property
    def personal_realized(self) -> int:
        return checked_int64(self.net - self.received, label="personal realized spending")


class _CashFlowProjection(TypedDict):
    inflow_minor: int
    outflow_minor: int
    net_minor: int
    internal_transfer_inflow_minor: int
    internal_transfer_outflow_minor: int
    accounts: list[CashFlowAccountRow]
    trend: list[CashFlowTrendPoint]


class _FactsSnapshot(TypedDict):
    cash: CashFacts
    credit: CreditFacts
    reimbursements: ReimbursementFacts
    completeness: CompletenessFacts
    future: KnownFutureTotals
    known_future_events: list[KnownFutureEvent]


class ReportingService:
    def __init__(self, session: AsyncSession, *, facts_today: date | None = None) -> None:
        self.session = session
        self.repository = ReportingRepository(session)
        self._facts_today = facts_today

    async def spending(self, *, date_from: date | None, date_to: date | None) -> SpendingReport:
        start, end = self._range(date_from, date_to)
        categories = await self.repository.categories()
        facts = await self._spending_facts(
            start,
            end,
            excluded_category_ids=self._excluded_category_ids(categories),
        )
        totals = self._sum_spending(facts)
        uncategorized_facts = [item for item in facts if item.transaction.category_id is None]
        uncategorized = self._bucket(
            uncategorized_facts,
            category_id=None,
            root_category_id=None,
            name="待归类",
            icon=None,
            color_hex=None,
        )
        roots = self._category_rows(facts, categories)
        by_day: dict[date, list[_SpendingFact]] = defaultdict(list)
        for fact in facts:
            by_day[self._business_date(fact.transaction.occurred_at)].append(fact)
        trend: list[SpendingTrendPoint] = []
        cursor = start
        while cursor <= end:
            amounts = self._sum_spending(by_day.get(cursor, []))
            trend.append(SpendingTrendPoint(date=cursor, **amounts.model_dump()))
            if cursor == end:
                break
            cursor += timedelta(days=1)
        return SpendingReport(
            meta=self._meta(start, end),
            **totals.model_dump(),
            uncategorized=uncategorized,
            categories=roots,
            trend=trend,
        )

    async def cash_flow(
        self,
        *,
        date_from: date | None,
        date_to: date | None,
        forecast_days: int,
        today: date | None,
    ) -> CashFlowReport:
        start, end = self._range(date_from, date_to)
        if not 1 <= forecast_days <= 90:
            invalid("invalid_forecast_window", "forecast_days must be between 1 and 90")
        actual = await self._cash_flow_actual(start, end)
        forecast = await self._forecast(today or self._today(), forecast_days)
        return CashFlowReport(meta=self._meta(start, end), forecast=forecast, **actual)

    async def debt(self, *, as_of: date | None) -> DebtReport:
        day = as_of or self._today()
        accounts = await self.repository.accounts()
        credit_accounts = [item for item in accounts.values() if item.kind == "credit"]
        impacts = await self.repository.account_impacts([item.id for item in credit_accounts])
        cycles = await self.repository.credit_cycles()
        amounts = await self.repository.credit_cycle_amounts([item.id for item in cycles])
        cycle_rows: list[DebtCycleRow] = []
        cycles_by_account: dict[UUID, list[DebtCycleRow]] = defaultdict(list)
        for cycle in cycles:
            account = accounts.get(cycle.account_id)
            if account is None:
                continue
            row = self._debt_cycle(cycle, account, amounts.get(cycle.id, (0, 0)), day)
            cycle_rows.append(row)
            cycles_by_account[cycle.account_id].append(row)
        account_rows: list[DebtAccountRow] = []
        total_debt = total_available = overdue_total = 0
        for account in sorted(credit_accounts, key=lambda item: (item.sort_order, item.id)):
            if account.credit_limit_minor is None:
                continue
            raw_debt = checked_int64(
                account.opening_balance_minor - impacts.get(account.id, 0),
                label="credit account debt",
            )
            debt = max(raw_debt, 0)
            available = max(account.credit_limit_minor - debt, 0)
            rows = cycles_by_account.get(account.id, [])
            overdue = self._checked_sum(row.remaining_minor for row in rows if row.is_overdue)
            remaining = [row for row in rows if row.remaining_minor > 0]
            next_due = min(remaining, key=lambda row: (row.due_date, row.cycle_id), default=None)
            unresolved = account.opening_balance_minor > 0 and (
                account.opening_balance_as_of_date is None or account.opening_due_date is None
            )
            account_rows.append(
                DebtAccountRow(
                    account_id=account.id,
                    account_name=account.name,
                    institution=account.institution,
                    last_four=account.last_four,
                    credit_limit_minor=account.credit_limit_minor,
                    current_debt_minor=debt,
                    available_credit_minor=available,
                    over_limit_minor=max(debt - account.credit_limit_minor, 0),
                    overdue_minor=overdue,
                    opening_configuration_required=unresolved,
                    has_overdue_cycle=overdue > 0,
                    next_due_cycle=next_due,
                )
            )
            total_debt = checked_int64(total_debt + debt, label="current credit debt")
            total_available = checked_int64(total_available + available, label="available credit")
            overdue_total = checked_int64(overdue_total + overdue, label="overdue debt")
        installments = await self._installment_groups(day, cycle_rows)
        return DebtReport(
            as_of=day,
            current_credit_debt_minor=total_debt,
            total_available_credit_minor=total_available,
            overdue_minor=overdue_total,
            accounts=account_rows,
            cycles=cycle_rows,
            installments=installments,
        )

    async def facts(self, *, window_days: int) -> ReportFacts:
        """Return the one read model for current balances and known future facts.

        The endpoint deliberately projects each credit cycle directly instead of
        reusing the legacy cash-flow system rows.  That keeps a credit due amount
        attributable to exactly one domain source and prevents a client from
        double-counting a cycle that is also visible in another report.
        """
        if not 1 <= window_days <= 90:
            invalid("invalid_facts_window", "window_days must be between 1 and 90")
        window_start = self._facts_today or self._today()
        window_end = window_start + timedelta(days=window_days - 1)
        for _ in range(2):
            revision_before = await self._data_revision()
            snapshot = await self._facts_snapshot(window_start, window_end)
            # Check the revision from a separate read transaction.  PostgreSQL
            # snapshots and the ORM identity map can otherwise both retain the
            # first read while a formal writer has already committed.
            await self._restart_facts_read_boundary()
            revision_after = await self._data_revision()
            if revision_before == revision_after:
                meta = FactsMeta(as_of=utc_now(), data_revision=revision_after)
                return ReportFacts(
                    meta=meta,
                    window=FactsWindow(date_from=window_start, date_to=window_end),
                    cash=snapshot["cash"].model_copy(
                        update={
                            "scope": self._facts_scope(
                                FactsDrillDownScopeType.CASH_ACCOUNTS, revision_after
                            )
                        }
                    ),
                    credit=snapshot["credit"].model_copy(
                        update={
                            "scope": self._facts_scope(
                                FactsDrillDownScopeType.CREDIT_CYCLES, revision_after
                            )
                        }
                    ),
                    reimbursements=snapshot["reimbursements"].model_copy(
                        update={
                            "scope": self._facts_scope(
                                FactsDrillDownScopeType.REIMBURSEMENT_OUTSTANDING,
                                revision_after,
                            )
                        }
                    ),
                    completeness=snapshot["completeness"].model_copy(
                        update={
                            "scope": self._facts_scope(
                                FactsDrillDownScopeType.COMPLETENESS_ISSUES,
                                revision_after,
                            )
                        }
                    ),
                    future=snapshot["future"],
                    known_future_events=snapshot["known_future_events"],
                )
            # The retry needs a new database transaction and fresh ORM state.
            # Without this boundary, the identity map can mix the first read's
            # domain rows with the second read's data revision.
            await self._restart_facts_read_boundary()
        invalid(
            "report_facts_changed_during_read",
            "Fiscal data changed while report facts were being read; retry the request",
        )

    async def future_events(
        self,
        *,
        window_days: int,
        account_id: UUID | None,
        cursor: str | None,
        limit: int,
    ) -> KnownFutureEventPage:
        """Return a revision-bound page for the v1.5 timeline.

        P30's home snapshot intentionally carries a small convenience array.
        This endpoint is the authoritative timeline read path: its opaque
        cursor binds the business window, account filter, revision and full
        same-day sort key, so changing any of them cannot skip or duplicate a
        future fact across pages.
        """
        if window_days not in {7, 30, 60, 90}:
            invalid("invalid_future_events_window", "window_days must be one of 7, 30, 60, or 90")
        today = self._facts_today or self._today()
        window = FactsWindow(date_from=today, date_to=today + timedelta(days=window_days - 1))
        for _ in range(2):
            revision_before = await self._data_revision()
            decoded_cursor = self._decode_future_events_cursor(
                cursor,
                window=window,
                account_id=account_id,
            )
            if decoded_cursor is not None and decoded_cursor[0] != revision_before:
                self._future_events_scope_changed(decoded_cursor[0], revision_before)
            cursor_key = decoded_cursor[1] if decoded_cursor is not None else None
            events = await self._future_events_page(
                window=window, account_id=account_id, cursor=cursor_key, limit=limit
            )
            page = events[:limit]
            await self._restart_facts_read_boundary()
            revision_after = await self._data_revision()
            if revision_before == revision_after:
                return KnownFutureEventPage(
                    meta=FactsMeta(as_of=utc_now(), data_revision=revision_after),
                    window=window,
                    account_id=account_id,
                    items=page,
                    next_cursor=(
                        self._encode_future_events_cursor(
                            window=window,
                            account_id=account_id,
                            data_revision=revision_after,
                            key=self._future_sort_key(page[-1]),
                        )
                        if len(events) > limit and page
                        else None
                    ),
                )
            await self._restart_facts_read_boundary()
        invalid(
            "future_events_changed_during_read",
            "Fiscal data changed while future events were being read; retry the request",
        )

    async def _future_events_page(
        self,
        *,
        window: FactsWindow,
        account_id: UUID | None,
        cursor: tuple[str, str, str, str] | None,
        limit: int,
    ) -> list[KnownFutureEvent]:
        """Bounded three-source merge for the timeline, never a facts snapshot."""
        sql_cursor = (
            (date.fromisoformat(cursor[0]), cursor[1], cursor[2], UUID(cursor[3]))
            if cursor is not None
            else None
        )
        credit_rows = await self.repository.future_credit_cycle_page(
            date_from=window.date_from,
            date_to=window.date_to,
            account_id=account_id,
            cursor=sql_cursor,
            limit=limit,
        )
        credit_events = [
            KnownFutureEvent(
                source_type=KnownFutureSourceType.CREDIT_CYCLE,
                source_id=cycle.id,
                date=cycle.due_date,
                direction=KnownFutureDirection.OUTFLOW,
                amount_minor=remaining_minor,
                certainty=KnownFutureCertainty.EXACT_DUE,
                title=f"{account.name} 账单应还",
                deep_link=f"fiscal://credit/cycles/{cycle.id}",
                account_id=account.id,
                cycle_id=cycle.id,
            )
            for cycle, account, remaining_minor in credit_rows
        ]
        cash_rows = await self.repository.future_cash_flow_page(
            date_from=window.date_from,
            date_to=window.date_to,
            account_id=account_id,
            cursor=sql_cursor,
            limit=limit,
        )
        cash_events = [
            KnownFutureEvent(
                source_type=KnownFutureSourceType.CASH_FLOW_ITEM,
                source_id=item.id,
                date=item.expected_date,
                direction=KnownFutureDirection(item.direction),
                amount_minor=item.planned_amount_minor,
                certainty=(
                    KnownFutureCertainty.CONFIRMED
                    if item.status == CashFlowStatus.CONFIRMED.value
                    else KnownFutureCertainty.SCHEDULED
                    if item.series_id is not None
                    else KnownFutureCertainty.EXPECTED
                ),
                title=item.title,
                deep_link=f"fiscal://cash-flow/items/{item.id}",
                account_id=item.account_id,
            )
            for item in cash_rows
        ]
        reimbursement_events: list[KnownFutureEvent] = []
        reimbursement_rows = await self.repository.future_reimbursement_page(
            date_from=window.date_from,
            date_to=window.date_to,
            account_id=account_id,
            cursor=sql_cursor,
            limit=limit,
        )
        reimbursement_events = [
            KnownFutureEvent(
                source_type=KnownFutureSourceType.REIMBURSEMENT_PARTY,
                source_id=row.party_id,
                date=row.expected_date,
                direction=KnownFutureDirection.INFLOW,
                amount_minor=row.outstanding_minor,
                certainty=KnownFutureCertainty.EXPECTED,
                title=f"{row.party_name} 预计报销",
                deep_link=f"fiscal://reimbursements/{row.claim_id}/parties/{row.party_id}",
                claim_id=row.claim_id,
                party_id=row.party_id,
            )
            for row in reimbursement_rows
        ]
        return sorted(
            [*credit_events, *cash_events, *reimbursement_events], key=self._future_sort_key
        )[: limit + 1]

    async def facts_drill_down(
        self,
        *,
        scope_type: FactsDrillDownScopeType,
        expected_data_revision: int,
        cursor: str | None,
        limit: int,
    ) -> FactsDrillDownPage:
        """Read one current-facts scope without silently mixing snapshot versions."""
        cursor_key = self._decode_facts_scope_cursor(cursor, scope_type, expected_data_revision)
        today = self._facts_today or self._today()
        revision_before = await self._data_revision()
        if revision_before != expected_data_revision:
            self._facts_scope_changed(expected_data_revision, revision_before)
        if scope_type is FactsDrillDownScopeType.CASH_ACCOUNTS:
            page, next_key = await self._cash_scope_page(cursor_key, limit)
        elif scope_type is FactsDrillDownScopeType.CREDIT_CYCLES:
            page, next_key = await self._credit_scope_page(cursor_key, limit, today)
        elif scope_type is FactsDrillDownScopeType.REIMBURSEMENT_OUTSTANDING:
            page, next_key = await self._reimbursement_scope_page(cursor_key, limit)
        else:
            page, next_key = await self._completeness_scope_page(cursor_key, limit)
        await self._restart_facts_read_boundary()
        revision_after = await self._data_revision()
        if revision_after != expected_data_revision:
            self._facts_scope_changed(expected_data_revision, revision_after)
        return FactsDrillDownPage(
            meta=FactsMeta(as_of=utc_now(), data_revision=revision_after),
            scope=self._facts_scope(scope_type, expected_data_revision),
            items=page,
            next_cursor=(
                self._encode_facts_scope_cursor(scope_type, expected_data_revision, next_key)
                if next_key is not None
                else None
            ),
        )

    async def _cash_scope_page(
        self, cursor_key: str | None, limit: int
    ) -> tuple[list[FactsDrillDownItem], str | None]:
        cursor_sort, cursor_id = self._decode_pair_key(cursor_key)
        rows = await self.repository.facts_cash_page(
            cursor_sort_order=cursor_sort, cursor_id=cursor_id, limit=limit
        )
        page = rows[:limit]
        impacts = await self.repository.account_impacts([item.id for item in page])
        items: list[FactsDrillDownItem] = [
            CashAccountFact(
                account_id=account.id,
                name=account.name,
                current_balance_minor=checked_int64(
                    account.opening_balance_minor + impacts.get(account.id, 0),
                    label="cash account balance",
                ),
                read_path=f"/api/v1/accounts/{account.id}",
                deep_link=f"fiscal://accounts/{account.id}",
            )
            for account in page
        ]
        next_key = (
            self._encode_pair_key(rows[limit - 1].sort_order, rows[limit - 1].id)
            if len(rows) > limit
            else None
        )
        return items, next_key

    async def _credit_scope_page(
        self, cursor_key: str | None, limit: int, today: date
    ) -> tuple[list[FactsDrillDownItem], str | None]:
        cursor_due, cursor_id = self._decode_date_pair_key(cursor_key)
        rows = await self.repository.facts_credit_cycle_page(
            cursor_due_date=cursor_due, cursor_id=cursor_id, limit=limit
        )
        page = rows[:limit]
        amounts = await self.repository.credit_cycle_amounts([cycle.id for cycle, _ in page])
        items: list[FactsDrillDownItem] = []
        for cycle, account in page:
            row = self._debt_cycle(cycle, account, amounts.get(cycle.id, (0, 0)), today)
            items.append(
                CreditCycleFact(
                    cycle_id=row.cycle_id,
                    account_id=row.account_id,
                    account_name=row.account_name,
                    due_date=row.due_date,
                    amount_due_minor=row.amount_due_minor,
                    repaid_minor=row.repaid_minor,
                    remaining_minor=row.remaining_minor,
                    read_path=f"/api/v1/credit-cycles/{row.cycle_id}",
                    deep_link=f"fiscal://credit/cycles/{row.cycle_id}",
                )
            )
        next_key = (
            self._encode_date_pair_key(rows[limit - 1][0].due_date, rows[limit - 1][0].id)
            if len(rows) > limit
            else None
        )
        return items, next_key

    async def _reimbursement_scope_page(
        self, cursor_key: str | None, limit: int
    ) -> tuple[list[FactsDrillDownItem], str | None]:
        cursor_id = self._decode_uuid_key(cursor_key)
        rows = await self.repository.facts_reimbursement_page(cursor_id=cursor_id, limit=limit)
        page = rows[:limit]
        items: list[FactsDrillDownItem] = [
            ReimbursementOutstandingFact(
                claim_id=claim_id,
                party_id=party_id,
                party_name=party_name,
                expected_date=expected_date,
                expected_minor=expected_minor,
                received_minor=received_minor,
                outstanding_minor=outstanding_minor,
                read_path=f"/api/v1/reimbursement-claims/{claim_id}",
                deep_link=f"fiscal://reimbursements/{claim_id}",
            )
            for (
                _allocation_id,
                claim_id,
                party_id,
                party_name,
                expected_date,
                expected_minor,
                received_minor,
                outstanding_minor,
            ) in page
        ]
        next_key = str(rows[limit - 1][0]) if len(rows) > limit else None
        return items, next_key

    async def _completeness_scope_page(
        self, cursor_key: str | None, limit: int
    ) -> tuple[list[FactsDrillDownItem], str | None]:
        facts, issues = await self._completeness_facts()
        _ = facts
        offset = self._decode_completeness_key(cursor_key)
        page = issues[offset : offset + limit]
        next_offset = offset + len(page)
        return list(page), str(next_offset) if next_offset < len(issues) else None

    async def _facts_snapshot(self, window_start: date, window_end: date) -> _FactsSnapshot:
        current_cash = await self.repository.facts_cash_total()

        debt = await self.debt(as_of=window_start)
        reimbursement_outstanding = await self.repository.facts_reimbursement_total()
        events = await self._known_future_events(
            debt=debt,
            window_start=window_start,
            window_end=window_end,
        )
        future = self._known_future_totals(events, current_cash)
        completeness, _ = await self._completeness_facts()
        return {
            "cash": CashFacts(current_balance_minor=current_cash),
            "credit": CreditFacts(current_debt_minor=debt.current_credit_debt_minor),
            "reimbursements": ReimbursementFacts(outstanding_minor=reimbursement_outstanding),
            "completeness": completeness,
            "future": future,
            "known_future_events": events,
        }

    async def _known_future_events(
        self,
        *,
        debt: DebtReport,
        window_start: date,
        window_end: date,
    ) -> list[KnownFutureEvent]:
        events: list[KnownFutureEvent] = []
        for cycle in debt.cycles:
            if cycle.remaining_minor <= 0 or not window_start <= cycle.due_date <= window_end:
                continue
            events.append(
                KnownFutureEvent(
                    source_type=KnownFutureSourceType.CREDIT_CYCLE,
                    source_id=cycle.cycle_id,
                    date=cycle.due_date,
                    direction=KnownFutureDirection.OUTFLOW,
                    amount_minor=cycle.remaining_minor,
                    certainty=KnownFutureCertainty.EXACT_DUE,
                    title=f"{cycle.account_name} 账单应还",
                    deep_link=f"fiscal://credit/cycles/{cycle.cycle_id}",
                    account_id=cycle.account_id,
                    cycle_id=cycle.cycle_id,
                )
            )

        party_values: dict[UUID, tuple[ReimbursementFact, int]] = {}
        for fact in await self.repository.reimbursement_facts():
            if (
                fact.claim_voided_at is not None
                or fact.cancelled_at is not None
                or fact.submitted_at is None
            ):
                continue
            outstanding = checked_int64(
                fact.allocated_minor - fact.received_minor,
                label="reimbursement future outstanding",
            )
            if outstanding <= 0 or fact.expected_date is None:
                continue
            current = party_values.get(fact.party_id)
            party_values[fact.party_id] = (
                fact,
                outstanding
                if current is None
                else checked_int64(
                    current[1] + outstanding,
                    label="reimbursement party future outstanding",
                ),
            )
        for fact, outstanding in party_values.values():
            assert fact.expected_date is not None
            if not window_start <= fact.expected_date <= window_end:
                continue
            events.append(
                KnownFutureEvent(
                    source_type=KnownFutureSourceType.REIMBURSEMENT_PARTY,
                    source_id=fact.party_id,
                    date=fact.expected_date,
                    direction=KnownFutureDirection.INFLOW,
                    amount_minor=outstanding,
                    certainty=KnownFutureCertainty.EXPECTED,
                    title=f"{fact.party_name} 预计报销",
                    deep_link=(f"fiscal://reimbursements/{fact.claim_id}/parties/{fact.party_id}"),
                    claim_id=fact.claim_id,
                    party_id=fact.party_id,
                )
            )

        manual_items = await CashFlowRepository(self.session).active()
        for item in manual_items:
            if item.direction == CashFlowDirection.TRANSFER.value:
                # An internal cash transfer has account-level movement but does
                # not change the combined cash fact and must not be deducted.
                continue
            if not window_start <= item.expected_date <= window_end:
                continue
            direction = KnownFutureDirection(item.direction)
            certainty = (
                KnownFutureCertainty.CONFIRMED
                if item.status == CashFlowStatus.CONFIRMED.value
                else (
                    KnownFutureCertainty.SCHEDULED
                    if item.series_id is not None
                    else KnownFutureCertainty.EXPECTED
                )
            )
            events.append(
                KnownFutureEvent(
                    source_type=KnownFutureSourceType.CASH_FLOW_ITEM,
                    source_id=item.id,
                    date=item.expected_date,
                    direction=direction,
                    amount_minor=item.planned_amount_minor,
                    certainty=certainty,
                    title=item.title,
                    deep_link=f"fiscal://cash-flow/items/{item.id}",
                    account_id=item.account_id,
                )
            )
        return sorted(
            events,
            key=lambda item: (
                item.date,
                item.direction.value,
                item.source_type.value,
                str(item.source_id),
            ),
        )

    @staticmethod
    def _known_future_totals(
        events: list[KnownFutureEvent], current_cash: int
    ) -> KnownFutureTotals:
        values = {
            "exact_due_outflow_minor": 0,
            "confirmed_outflow_minor": 0,
            "expected_outflow_minor": 0,
            "scheduled_outflow_minor": 0,
            "confirmed_inflow_minor": 0,
            "expected_inflow_minor": 0,
            "scheduled_inflow_minor": 0,
        }
        for event in events:
            if event.direction is KnownFutureDirection.OUTFLOW:
                if event.certainty is KnownFutureCertainty.EXACT_DUE:
                    key = "exact_due_outflow_minor"
                elif event.certainty is KnownFutureCertainty.CONFIRMED:
                    key = "confirmed_outflow_minor"
                elif event.certainty is KnownFutureCertainty.EXPECTED:
                    key = "expected_outflow_minor"
                else:
                    key = "scheduled_outflow_minor"
            elif event.certainty is KnownFutureCertainty.CONFIRMED:
                key = "confirmed_inflow_minor"
            elif event.certainty is KnownFutureCertainty.EXPECTED:
                key = "expected_inflow_minor"
            else:
                key = "scheduled_inflow_minor"
            values[key] = checked_int64(values[key] + event.amount_minor, label=key)
        return KnownFutureTotals(
            **values,
            after_confirmed_outflow_minor=checked_int64(
                current_cash
                - values["exact_due_outflow_minor"]
                - values["confirmed_outflow_minor"],
                label="cash after confirmed outflow",
            ),
        )

    @staticmethod
    def _future_sort_key(event: KnownFutureEvent) -> tuple[str, str, str, str]:
        """Stable ascending order, including the full tie-breaker on one day."""
        return (
            event.date.isoformat(),
            event.direction.value,
            event.source_type.value,
            str(event.source_id),
        )

    @classmethod
    def _encode_future_events_cursor(
        cls,
        *,
        window: FactsWindow,
        account_id: UUID | None,
        data_revision: int,
        key: tuple[str, str, str, str],
    ) -> str:
        payload = json.dumps(
            {
                "v": 1,
                "schema_version": "1",
                "revision": data_revision,
                "window_from": window.date_from.isoformat(),
                "window_to": window.date_to.isoformat(),
                "account_id": str(account_id) if account_id is not None else None,
                "sort": "date,direction,source_type,source_id:asc:v1",
                "key": list(key),
            },
            separators=(",", ":"),
        )
        return base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")

    @classmethod
    def _decode_future_events_cursor(
        cls,
        cursor: str | None,
        *,
        window: FactsWindow,
        account_id: UUID | None,
    ) -> tuple[int, tuple[str, str, str, str]] | None:
        if cursor is None:
            return None
        try:
            raw = json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode())
            if not isinstance(raw, dict):
                raise ValueError
            payload = cast(dict[str, object], raw)
            key = payload.get("key")
            if (
                type(payload.get("v")) is not int
                or payload["v"] != 1
                or payload.get("schema_version") != "1"
                or type(payload.get("revision")) is not int
                or cast(int, payload["revision"]) < 0
                or payload.get("window_from") != window.date_from.isoformat()
                or payload.get("window_to") != window.date_to.isoformat()
                or payload.get("account_id") != (str(account_id) if account_id else None)
                or payload.get("sort") != "date,direction,source_type,source_id:asc:v1"
            ):
                raise ValueError
            if not isinstance(key, list):
                raise ValueError
            key_values = cast(list[object], key)
            if len(key_values) != 4 or not all(isinstance(item, str) for item in key_values):
                raise ValueError
            key_parts = cast(list[str], key_values)
            key_date = date.fromisoformat(key_parts[0])
            if not window.date_from <= key_date <= window.date_to:
                raise ValueError
            KnownFutureDirection(key_parts[1])
            source_type = KnownFutureSourceType(key_parts[2])
            if source_type is KnownFutureSourceType.CREDIT_CYCLE and key_parts[1] != "outflow":
                raise ValueError
            if (
                source_type is KnownFutureSourceType.REIMBURSEMENT_PARTY
                and key_parts[1] != "inflow"
            ):
                raise ValueError
            UUID(key_parts[3])
            return cast(int, payload["revision"]), cast(tuple[str, str, str, str], tuple(key_parts))
        except (ValueError, TypeError, KeyError, UnicodeDecodeError, binascii.Error) as error:
            invalid("invalid_future_events_cursor", "The future events cursor is invalid")
            raise AssertionError from error

    @staticmethod
    def _future_events_scope_changed(
        expected_data_revision: int, current_data_revision: int
    ) -> None:
        conflict(
            "future_events_scope_changed",
            "Fiscal data changed after the future-events page; reload before continuing",
            details={
                "reason": "future_events_snapshot_changed",
                "expected_data_revision": expected_data_revision,
                "current_data_revision": current_data_revision,
                "safe_to_reload": True,
                "reload_path": "/api/v1/reports/future-events",
            },
        )

    async def _completeness_facts(
        self,
    ) -> tuple[CompletenessFacts, list[CompletenessIssueFact]]:
        (
            unresolved_import_count,
            failed_import_count,
            uncategorized_transaction_count,
            uncategorized_amount_minor,
        ) = await self.repository.facts_completeness_counts()
        facts = CompletenessFacts(
            unresolved_import_count=unresolved_import_count,
            failed_import_count=failed_import_count,
            uncategorized_transaction_count=uncategorized_transaction_count,
            uncategorized_transaction_amount_minor=uncategorized_amount_minor,
        )
        items: list[CompletenessIssueFact] = []
        if facts.unresolved_import_count:
            items.append(
                CompletenessIssueFact(
                    issue_type=CompletenessIssueType.UNRESOLVED_IMPORTS,
                    count=facts.unresolved_import_count,
                    read_path="/api/v1/reports/facts/drill-down?scope=completeness_issues",
                    deep_link="fiscal://reports/facts/completeness/imports",
                )
            )
        if facts.failed_import_count:
            items.append(
                CompletenessIssueFact(
                    issue_type=CompletenessIssueType.FAILED_IMPORTS,
                    count=facts.failed_import_count,
                    read_path="/api/v1/reports/facts/drill-down?scope=completeness_issues",
                    deep_link="fiscal://reports/facts/completeness/imports",
                )
            )
        if facts.uncategorized_transaction_count:
            items.append(
                CompletenessIssueFact(
                    issue_type=CompletenessIssueType.UNCATEGORIZED_TRANSACTIONS,
                    count=facts.uncategorized_transaction_count,
                    amount_minor=facts.uncategorized_transaction_amount_minor,
                    read_path="/api/v1/transactions?classification=uncategorized",
                    deep_link="fiscal://transactions?classification=uncategorized",
                )
            )
        return facts, items

    @staticmethod
    def _facts_scope(
        scope_type: FactsDrillDownScopeType, expected_data_revision: int
    ) -> FactsDrillDownScope:
        query = f"scope={scope_type.value}&expected_data_revision={expected_data_revision}"
        return FactsDrillDownScope(
            scope_type=scope_type,
            expected_data_revision=expected_data_revision,
            read_path=f"/api/v1/reports/facts/drill-down?{query}",
            deep_link=f"fiscal://reports/facts/{scope_type.value}",
        )

    @staticmethod
    def _facts_scope_changed(expected_data_revision: int, current_data_revision: int) -> None:
        conflict(
            "report_facts_scope_changed",
            "Fiscal data changed after the facts snapshot; reload before drilling down",
            details={
                "reason": "facts_snapshot_changed",
                "expected_data_revision": expected_data_revision,
                "current_data_revision": current_data_revision,
                "safe_to_reload": True,
                "reload_path": "/api/v1/reports/facts",
            },
        )

    @staticmethod
    def _encode_facts_scope_cursor(
        scope_type: FactsDrillDownScopeType, expected_data_revision: int, key: str
    ) -> str:
        payload = json.dumps(
            {
                "v": 1,
                "schema_version": "1",
                "scope": scope_type.value,
                "revision": expected_data_revision,
                "filter": "none",
                "sort": f"{scope_type.value}:v1",
                "key": key,
            },
            separators=(",", ":"),
        )
        return base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")

    @staticmethod
    def _decode_facts_scope_cursor(
        cursor: str | None,
        scope_type: FactsDrillDownScopeType,
        expected_data_revision: int,
    ) -> str | None:
        if cursor is None:
            return None
        try:
            raw_payload = json.loads(
                base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
            )
            if not isinstance(raw_payload, dict):
                raise ValueError
            payload = cast(dict[str, object], raw_payload)
            version = payload.get("v")
            schema_version = payload.get("schema_version")
            scope = payload.get("scope")
            revision = payload.get("revision")
            filter_fingerprint = payload.get("filter")
            sort_fingerprint = payload.get("sort")
            key = payload.get("key")
            if (
                type(version) is not int
                or version != 1
                or not isinstance(schema_version, str)
                or schema_version != "1"
                or not isinstance(scope, str)
                or scope != scope_type.value
                or type(revision) is not int
                or revision < 0
                or revision != expected_data_revision
                or not isinstance(filter_fingerprint, str)
                or filter_fingerprint != "none"
                or not isinstance(sort_fingerprint, str)
                or sort_fingerprint != f"{scope_type.value}:v1"
                or not isinstance(key, str)
            ):
                raise ValueError
            return key
        except (ValueError, TypeError, KeyError, UnicodeDecodeError, binascii.Error) as error:
            invalid("invalid_facts_scope_cursor", "The facts drill-down cursor is invalid")
            raise AssertionError from error

    @staticmethod
    def _encode_pair_key(sort_order: int, item_id: UUID) -> str:
        return f"{sort_order}:{item_id}"

    @staticmethod
    def _decode_pair_key(key: str | None) -> tuple[int | None, UUID | None]:
        if key is None:
            return None, None
        try:
            order, item_id = key.split(":", maxsplit=1)
            return int(order), UUID(item_id)
        except (ValueError, AttributeError) as error:
            invalid("invalid_facts_scope_cursor", "The facts drill-down cursor is invalid")
            raise AssertionError from error

    @staticmethod
    def _encode_date_pair_key(value: date, item_id: UUID) -> str:
        return f"{value.isoformat()}:{item_id}"

    @staticmethod
    def _decode_date_pair_key(key: str | None) -> tuple[date | None, UUID | None]:
        if key is None:
            return None, None
        try:
            value, item_id = key.split(":", maxsplit=1)
            return date.fromisoformat(value), UUID(item_id)
        except (ValueError, AttributeError) as error:
            invalid("invalid_facts_scope_cursor", "The facts drill-down cursor is invalid")
            raise AssertionError from error

    @staticmethod
    def _decode_uuid_key(key: str | None) -> UUID | None:
        if key is None:
            return None
        try:
            return UUID(key)
        except (ValueError, AttributeError) as error:
            invalid("invalid_facts_scope_cursor", "The facts drill-down cursor is invalid")
            raise AssertionError from error

    @staticmethod
    def _decode_completeness_key(key: str | None) -> int:
        if key is None:
            return 0
        try:
            offset = int(key)
            if offset < 0:
                raise ValueError
            return offset
        except (ValueError, TypeError) as error:
            invalid("invalid_facts_scope_cursor", "The facts drill-down cursor is invalid")
            raise AssertionError from error

    async def _data_revision(self) -> int:
        revision = await self.session.scalar(
            select(DataRevision.revision).where(DataRevision.id == 1)
        )
        if revision is None:
            raise RuntimeError("data_revision singleton is missing")
        return revision

    async def _restart_facts_read_boundary(self) -> None:
        await self.session.rollback()
        self.session.expire_all()

    async def overview(self, *, month: str | None) -> OverviewReport:
        start, end = self._month_range(month)
        spending = await self.spending(date_from=start, date_to=end)
        monthly_income = await self._monthly_income_minor(start, end)
        cash = await self.cash_flow(
            date_from=start,
            date_to=end,
            forecast_days=30,
            today=self._today(),
        )
        from fiscal_api.services.cash_flow import CashFlowService

        future_cash = await CashFlowService(self.session).active()
        debt = await self.debt(as_of=self._today())
        accounts = await self.repository.accounts()
        asset_accounts = [item for item in accounts.values() if item.kind in {"cash", "debit"}]
        impacts = await self.repository.account_impacts([item.id for item in asset_accounts])
        account_value = 0
        for account in asset_accounts:
            current = checked_int64(
                account.opening_balance_minor + impacts.get(account.id, 0),
                label="asset account value",
            )
            account_value = checked_int64(account_value + current, label="account value")
        reimbursement_outstanding = await self._reimbursement_outstanding()
        transactions = await self.repository.transactions()
        from fiscal_api.services.transactions import TransactionService

        recent = await TransactionService(self.session).responses_with_capabilities(
            transactions[:OVERVIEW_RECENT_TRANSACTION_LIMIT]
        )
        return OverviewReport(
            meta=self._meta(start, end),
            account_value_minor=account_value,
            current_credit_debt_minor=debt.current_credit_debt_minor,
            monthly_income_minor=monthly_income,
            reimbursement_outstanding_minor=reimbursement_outstanding,
            spending=OverviewSpendingSummary(**self._spending_values(spending)),
            top_spending_categories=spending.categories[:3],
            cash_flow=OverviewCashFlowSummary(
                inflow_minor=future_cash.summary.inflow_minor,
                outflow_minor=future_cash.summary.outflow_minor,
                net_minor=future_cash.summary.net_minor,
            ),
            uncategorized_count=spending.uncategorized.transaction_count,
            uncategorized_amount_minor=spending.uncategorized.net_consumption_minor,
            recent_transactions=recent,
            forecast=cash.forecast,
            credit_due_events=self._overview_credit_due_events(
                cycles=debt.cycles,
                today=self._today(),
            ),
        )

    async def _monthly_income_minor(self, start: date, end: date) -> int:
        occurred_from, occurred_to = self._bounds(start, end)
        categories = await self.repository.categories()
        transactions = await self.repository.transactions(
            occurred_from=occurred_from,
            occurred_to_exclusive=occurred_to,
            kinds={TransactionKind.INCOME.value},
            excluded_category_ids=self._excluded_category_ids(categories),
        )
        accounts = await self.repository.accounts()
        total = 0
        for transaction in transactions:
            for posting in transaction.postings:
                account = accounts.get(posting.account_id)
                if (
                    account is not None
                    and account.kind in {AccountKind.CASH.value, AccountKind.DEBIT.value}
                    and posting.amount_minor > 0
                ):
                    total = checked_int64(
                        total + posting.amount_minor,
                        label="monthly income",
                    )
        return total

    async def drill_down(
        self,
        *,
        lens: ReportLens,
        date_from: date | None,
        date_to: date | None,
        category_id: UUID | None,
        account_id: UUID | None,
        cursor: str | None,
        limit: int,
    ) -> ReportDrillDownPage:
        start, end = self._range(date_from, date_to)
        if not 1 <= limit <= 100:
            invalid("invalid_report_limit", "limit must be between 1 and 100")
        occurred_from, occurred_to = self._bounds(start, end)
        cursor_time, cursor_id = self._decode_cursor(cursor, lens)
        categories = await self.repository.categories()
        accounts = await self.repository.accounts()
        excluded_category_ids = self._excluded_category_ids(categories)
        if category_id in excluded_category_ids:
            return ReportDrillDownPage(items=[], next_cursor=None)
        if lens is ReportLens.CASH_FLOW:
            category_ids: set[UUID] | None = None
            if category_id is not None:
                category = categories.get(category_id)
                category_ids = {category_id}
                if category is not None and category.parent_id is None:
                    category_ids.update(
                        item.id for item in categories.values() if item.parent_id == category_id
                    )
            rows = await self.repository.cash_posting_page(
                occurred_from=occurred_from,
                occurred_to_exclusive=occurred_to,
                account_id=account_id,
                category_ids=category_ids,
                excluded_category_ids=excluded_category_ids,
                cursor_time=cursor_time,
                cursor_id=cursor_id,
                limit=limit,
            )
            items = [
                self._cash_line(posting, tx, account, categories)
                for posting, tx, account in rows[:limit]
            ]
            next_cursor = (
                self._encode_cursor(rows[limit - 1][1].occurred_at, rows[limit - 1][0].id, lens)
                if len(rows) > limit
                else None
            )
            return ReportDrillDownPage(items=items, next_cursor=next_cursor)
        category_ids: set[UUID] | None = None
        if category_id is not None:
            category = categories.get(category_id)
            category_ids = {category_id}
            if category is not None and category.parent_id is None:
                category_ids.update(
                    item.id for item in categories.values() if item.parent_id == category_id
                )
        transactions = await self.repository.transaction_page(
            occurred_from=occurred_from,
            occurred_to_exclusive=occurred_to,
            kinds=SPENDING_KINDS,
            category_ids=category_ids,
            excluded_category_ids=excluded_category_ids,
            account_id=account_id,
            cursor_time=cursor_time,
            cursor_id=cursor_id,
            limit=limit,
        )
        page = transactions[:limit]
        facts = await self._facts_for_transactions(page)
        items = [self._spending_line(item, categories, accounts) for item in facts]
        next_cursor = (
            self._encode_cursor(page[-1].occurred_at, page[-1].id, lens)
            if len(transactions) > limit and page
            else None
        )
        return ReportDrillDownPage(items=items, next_cursor=next_cursor)

    async def monthly_report(
        self, *, period: str, expected_data_revision: int | None = None
    ) -> PeriodReport:
        start, end = self._month_range(period)
        return await self._period_report(
            ReportPeriodKind.MONTH,
            period,
            start,
            end,
            expected_data_revision=expected_data_revision,
        )

    async def yearly_report(
        self, *, period: str, expected_data_revision: int | None = None
    ) -> PeriodReport:
        start, end = self._period_bounds(ReportPeriodKind.YEAR, period)
        return await self._period_report(
            ReportPeriodKind.YEAR,
            period,
            start,
            end,
            expected_data_revision=expected_data_revision,
        )

    async def monthly_report_v2(
        self, *, period: str, expected_data_revision: int | None = None
    ) -> PeriodReportV2:
        start, end = self._month_range(period)
        return await self._period_report_v2(
            ReportPeriodKind.MONTH,
            period,
            start,
            end,
            expected_data_revision=expected_data_revision,
        )

    async def yearly_report_v2(
        self, *, period: str, expected_data_revision: int | None = None
    ) -> PeriodReportV2:
        start, end = self._period_bounds(ReportPeriodKind.YEAR, period)
        return await self._period_report_v2(
            ReportPeriodKind.YEAR,
            period,
            start,
            end,
            expected_data_revision=expected_data_revision,
        )

    async def period_report_drill_down(
        self,
        *,
        period_kind: ReportPeriodKind,
        period: str,
        expected_data_revision: int,
        category_id: UUID | None,
        account_id: UUID | None,
        merchant_id: UUID | None,
        source: TransactionSource | None,
        cursor: str | None,
        limit: int,
    ) -> PeriodReportDrillDownPage:
        if not 1 <= limit <= 100:
            invalid("invalid_period_report_limit", "limit must be between 1 and 100")
        start, end = self._period_bounds(period_kind, period)
        cursor_time, cursor_id = self._decode_period_report_cursor(
            cursor,
            period_kind=period_kind,
            period=period,
            expected_data_revision=expected_data_revision,
            category_id=category_id,
            account_id=account_id,
            merchant_id=merchant_id,
            source=source,
        )
        revision_before = await self._data_revision()
        if revision_before != expected_data_revision:
            self._period_report_changed(
                expected_data_revision,
                revision_before,
                period_kind=period_kind,
                period=period,
                drill_down=True,
            )
        occurred_from, occurred_to = self._bounds(start, end)
        page = await self.repository.period_ledger_page(
            occurred_from=occurred_from,
            occurred_to_exclusive=occurred_to,
            category_id=category_id,
            account_id=account_id,
            merchant_id=merchant_id,
            source=source.value if source is not None else None,
            cursor_time=cursor_time,
            cursor_id=cursor_id,
            limit=limit,
        )
        category_by_id = await self.repository.categories()
        merchant_by_transaction = await self._merchant_by_transaction({item.id for item in page})
        facts = await self._facts_for_transactions(
            [item for item in page[:limit] if item.kind in SPENDING_KINDS]
        )
        spending_by_id = {item.transaction.id: item for item in facts}
        items = [
            self._period_drill_down_item(
                transaction,
                categories=category_by_id,
                merchant=merchant_by_transaction.get(transaction.id),
                spending=spending_by_id.get(transaction.id),
            )
            for transaction in page[:limit]
        ]
        next_cursor = (
            self._encode_period_report_cursor(
                period_kind=period_kind,
                period=period,
                expected_data_revision=expected_data_revision,
                category_id=category_id,
                account_id=account_id,
                merchant_id=merchant_id,
                source=source,
                occurred_at=page[limit - 1].occurred_at,
                transaction_id=page[limit - 1].id,
            )
            if len(page) > limit
            else None
        )
        await self._restart_facts_read_boundary()
        revision_after = await self._data_revision()
        if revision_after != expected_data_revision:
            self._period_report_changed(
                expected_data_revision,
                revision_after,
                period_kind=period_kind,
                period=period,
                drill_down=True,
            )
        meta = self._period_report_meta(
            period_kind, period, start, end, data_revision=revision_after
        )
        return PeriodReportDrillDownPage(
            meta=meta,
            dimension=ReportDrillDownDimension.LEDGER,
            category_id=category_id,
            account_id=account_id,
            merchant_id=merchant_id,
            source=source,
            items=items,
            next_cursor=next_cursor,
        )

    async def period_report_drill_down_v2(
        self,
        *,
        period_kind: ReportPeriodKind,
        period: str,
        expected_data_revision: int,
        category_id: UUID | None,
        account_id: UUID | None,
        merchant_id: UUID | None,
        source: TransactionSource | None,
        cursor: str | None,
        limit: int,
    ) -> PeriodReportDrillDownPageV2:
        if not 1 <= limit <= 100:
            invalid("invalid_period_report_limit", "limit must be between 1 and 100")
        start, end = self._period_bounds(period_kind, period)
        cursor_time, cursor_id = self._decode_period_report_cursor(
            cursor,
            period_kind=period_kind,
            period=period,
            expected_data_revision=expected_data_revision,
            category_id=category_id,
            account_id=account_id,
            merchant_id=merchant_id,
            source=source,
        )
        revision_before = await self._data_revision()
        if revision_before != expected_data_revision:
            self._period_report_changed(
                expected_data_revision,
                revision_before,
                period_kind=period_kind,
                period=period,
                drill_down=True,
                version=2,
            )
        occurred_from, occurred_to = self._bounds(start, end)
        page = await self.repository.period_ledger_page(
            occurred_from=occurred_from,
            occurred_to_exclusive=occurred_to,
            category_id=category_id,
            account_id=account_id,
            merchant_id=merchant_id,
            source=source.value if source is not None else None,
            cursor_time=cursor_time,
            cursor_id=cursor_id,
            limit=limit,
        )
        categories = await self.repository.categories()
        accounts = await self.repository.accounts()
        merchants = await self._merchant_by_transaction({item.id for item in page})
        facts = await self._facts_for_transactions(
            [item for item in page[:limit] if item.kind in SPENDING_KINDS]
        )
        spending_by_id = {item.transaction.id: item for item in facts}
        items = [
            self._period_drill_down_item_v2(
                transaction,
                categories=categories,
                accounts=accounts,
                merchant=merchants.get(transaction.id),
                spending=spending_by_id.get(transaction.id),
            )
            for transaction in page[:limit]
        ]
        next_cursor = (
            self._encode_period_report_cursor(
                period_kind=period_kind,
                period=period,
                expected_data_revision=expected_data_revision,
                category_id=category_id,
                account_id=account_id,
                merchant_id=merchant_id,
                source=source,
                occurred_at=page[limit - 1].occurred_at,
                transaction_id=page[limit - 1].id,
            )
            if len(page) > limit
            else None
        )
        await self._restart_facts_read_boundary()
        revision_after = await self._data_revision()
        if revision_after != expected_data_revision:
            self._period_report_changed(
                expected_data_revision,
                revision_after,
                period_kind=period_kind,
                period=period,
                drill_down=True,
                version=2,
            )
        return PeriodReportDrillDownPageV2(
            meta=self._period_report_meta_v2(
                period_kind, period, start, end, data_revision=revision_after
            ),
            dimension=ReportDrillDownDimension.LEDGER,
            category_id=category_id,
            account_id=account_id,
            merchant_id=merchant_id,
            source=source,
            items=items,
            next_cursor=next_cursor,
        )

    async def _period_report(
        self,
        period_kind: ReportPeriodKind,
        period: str,
        start: date,
        end: date,
        *,
        expected_data_revision: int | None = None,
    ) -> PeriodReport:
        """Construct a report in one read-revision boundary, retrying once only.

        A report intentionally is not persisted as a mutable snapshot.  It is
        re-derived from the formal ledger, and a concurrent formal write yields
        either a wholly old/new read or a safe conflict--never a mixed export.
        """
        for attempt in range(2):
            revision_before = await self._data_revision()
            if expected_data_revision is not None and revision_before != expected_data_revision:
                self._period_report_changed(
                    expected_data_revision,
                    revision_before,
                    period_kind=period_kind,
                    period=period,
                )
            report = await self._build_period_report(
                period_kind, period, start, end, revision_before
            )
            await self._restart_facts_read_boundary()
            revision_after = await self._data_revision()
            if revision_after == revision_before:
                return report
            if expected_data_revision is not None:
                self._period_report_changed(
                    expected_data_revision,
                    revision_after,
                    period_kind=period_kind,
                    period=period,
                )
            if attempt == 0:
                continue
            self._period_report_changed(
                revision_before,
                revision_after,
                period_kind=period_kind,
                period=period,
            )
        raise AssertionError("unreachable")

    async def _period_report_v2(
        self,
        period_kind: ReportPeriodKind,
        period: str,
        start: date,
        end: date,
        *,
        expected_data_revision: int | None = None,
    ) -> PeriodReportV2:
        for attempt in range(2):
            revision_before = await self._data_revision()
            if expected_data_revision is not None and revision_before != expected_data_revision:
                self._period_report_changed(
                    expected_data_revision,
                    revision_before,
                    period_kind=period_kind,
                    period=period,
                    version=2,
                )
            report = await self._build_period_report_v2(
                period_kind, period, start, end, revision_before
            )
            await self._restart_facts_read_boundary()
            revision_after = await self._data_revision()
            if revision_after == revision_before:
                return report
            if expected_data_revision is not None:
                self._period_report_changed(
                    expected_data_revision,
                    revision_after,
                    period_kind=period_kind,
                    period=period,
                    version=2,
                )
            if attempt == 0:
                continue
            self._period_report_changed(
                revision_before,
                revision_after,
                period_kind=period_kind,
                period=period,
                version=2,
            )
        raise AssertionError("unreachable")

    async def _build_period_report_v2(
        self,
        period_kind: ReportPeriodKind,
        period: str,
        start: date,
        end: date,
        data_revision: int,
    ) -> PeriodReportV2:
        base = await self._build_period_report(period_kind, period, start, end, data_revision)
        categories = await self.repository.categories()
        spending = await self._spending_facts(
            start,
            end,
            excluded_category_ids=self._excluded_category_ids(categories),
        )
        by_day: dict[date, list[_SpendingFact]] = defaultdict(list)
        for fact in spending:
            by_day[self._business_date(fact.transaction.occurred_at)].append(fact)
        daily: list[ReportDailyPointV2] = []
        cursor = start
        while cursor <= end:
            daily.append(
                ReportDailyPointV2(
                    date=cursor, **self._sum_spending(by_day.get(cursor, [])).model_dump()
                )
            )
            if cursor == end:
                break
            cursor += timedelta(days=1)

        debt = await self.debt(as_of=end)
        debt_cycles = [
            cycle
            for cycle in debt.cycles
            if start <= cycle.statement_date <= end or start <= cycle.due_date <= end
        ]
        known_future_events = await self._known_future_events(
            debt=debt,
            window_start=start,
            window_end=end,
        )
        return PeriodReportV2(
            meta=self._period_report_meta_v2(
                period_kind, period, start, end, data_revision=data_revision
            ),
            summary=base.summary,
            accounts=base.accounts,
            categories=self._period_category_rows_v2(spending, categories),
            merchants=base.merchants,
            sources=base.sources,
            completeness=base.completeness,
            daily=daily,
            known_future_events=known_future_events,
            debt_cycles=debt_cycles,
            installments=debt.installments,
            drill_down_path=(
                "/api/v1/reports/v2/period-drill-down?"
                f"period_kind={period_kind.value}&period={period}"
                f"&expected_data_revision={data_revision}"
            ),
        )

    async def _build_period_report(
        self,
        period_kind: ReportPeriodKind,
        period: str,
        start: date,
        end: date,
        data_revision: int,
    ) -> PeriodReport:
        occurred_from, occurred_to = self._bounds(start, end)
        accounts = await self.repository.accounts()
        categories = await self.repository.categories()
        transactions = await self.repository.transactions(
            occurred_from=occurred_from, occurred_to_exclusive=occurred_to
        )
        excluded_categories = self._excluded_category_ids(categories)
        spending = await self._facts_for_transactions(
            [
                item
                for item in transactions
                if item.kind in SPENDING_KINDS
                and (item.category_id is None or item.category_id not in excluded_categories)
            ]
        )
        spending_totals = self._sum_spending(spending)
        cash = await self._cash_flow_actual(start, end)
        income = self._period_income(transactions, accounts, excluded_categories)
        opening_boundary, _ = self._bounds(start, start)
        opening_impacts = await self.repository.period_account_impacts(
            occurred_before=opening_boundary
        )
        closing_impacts = await self.repository.period_account_impacts(occurred_before=occurred_to)
        account_rows = self._period_account_rows(
            accounts, transactions, opening_impacts, closing_impacts
        )
        credit_debt = self._period_credit_debt(accounts, closing_impacts)
        reimbursement = await self._period_reimbursement_outstanding(occurred_to)
        counts = await self.repository.facts_completeness_counts()
        merchant_by_transaction = await self._merchant_by_transaction(
            {item.transaction.id for item in spending}
        )
        categories_rows = self._period_category_rows(spending, categories)
        merchant_rows = self._period_merchant_rows(spending, merchant_by_transaction)
        source_rows = self._period_source_rows(transactions)
        summary = ReportSummary(
            income_minor=income,
            gross_consumption_minor=spending_totals.gross_consumption_minor,
            merchant_refund_minor=spending_totals.merchant_refund_minor,
            net_consumption_minor=spending_totals.net_consumption_minor,
            expected_reimbursement_minor=spending_totals.expected_reimbursement_minor,
            received_reimbursement_minor=spending_totals.received_reimbursement_minor,
            personal_expected_minor=spending_totals.personal_expected_minor,
            personal_realized_minor=spending_totals.personal_realized_minor,
            net_income_expense_minor=checked_int64(
                income - spending_totals.net_consumption_minor, label="report net income expense"
            ),
            cash_inflow_minor=cash["inflow_minor"],
            cash_outflow_minor=cash["outflow_minor"],
            cash_net_minor=cash["net_minor"],
            internal_transfer_inflow_minor=cash["internal_transfer_inflow_minor"],
            internal_transfer_outflow_minor=cash["internal_transfer_outflow_minor"],
            credit_debt_at_period_end_minor=credit_debt,
            reimbursement_outstanding_at_period_end_minor=reimbursement,
        )
        meta = self._period_report_meta(
            period_kind, period, start, end, data_revision=data_revision
        )
        return PeriodReport(
            meta=meta,
            summary=summary,
            accounts=account_rows,
            categories=categories_rows,
            merchants=merchant_rows,
            sources=source_rows,
            completeness=ReportCompleteness(
                unresolved_import_count=counts[0],
                failed_import_count=counts[1],
                uncategorized_transaction_count=counts[2],
            ),
            drill_down_path=(
                "/api/v1/reports/period-drill-down?"
                f"period_kind={period_kind.value}&period={period}&expected_data_revision={data_revision}"
            ),
        )

    @staticmethod
    def _period_bounds(period_kind: ReportPeriodKind, period: str) -> tuple[date, date]:
        if period_kind is ReportPeriodKind.MONTH:
            return ReportingService._month_range_static(period)
        try:
            if len(period) != 4 or not period.isascii() or not period.isdigit():
                raise ValueError
            year = int(period)
            if not MIN_REPORT_YEAR <= year <= MAX_REPORT_YEAR:
                raise ValueError
            return date(year, 1, 1), date(year, 12, 31)
        except ValueError as error:
            invalid(
                "invalid_report_year",
                f"period must use YYYY within {SUPPORTED_REPORT_YEAR_RANGE}",
                details=ReportingService._period_year_range_details(),
            )
            raise AssertionError from error

    @staticmethod
    def _month_range_static(month: str) -> tuple[date, date]:
        match = MONTH_PATTERN.fullmatch(month)
        if match is None:
            invalid("invalid_report_month", "period must use YYYY-MM")
        try:
            year, number = int(match.group(1)), int(match.group(2))
            if not MIN_REPORT_YEAR <= year <= MAX_REPORT_YEAR:
                raise ValueError
            return date(year, number, 1), date(year, number, monthrange(year, number)[1])
        except ValueError as error:
            invalid(
                "invalid_report_month",
                f"period must use YYYY-MM within {SUPPORTED_REPORT_YEAR_RANGE}",
                details=ReportingService._period_year_range_details(),
            )
            raise AssertionError from error

    @staticmethod
    def _period_year_range_details() -> dict[str, object]:
        return {
            "minimum_year": MIN_REPORT_YEAR,
            "maximum_year": MAX_REPORT_YEAR,
            "supported_year_range": SUPPORTED_REPORT_YEAR_RANGE,
        }

    @staticmethod
    def _period_report_meta(
        period_kind: ReportPeriodKind,
        period: str,
        start: date,
        end: date,
        *,
        data_revision: int,
    ) -> PeriodReportMeta:
        generated_at = utc_now()
        return PeriodReportMeta(
            period_kind=period_kind,
            period=period,
            date_from=start,
            date_to=end,
            as_of=generated_at,
            data_revision=data_revision,
            generated_at=generated_at,
        )

    @staticmethod
    def _period_report_meta_v2(
        period_kind: ReportPeriodKind,
        period: str,
        start: date,
        end: date,
        *,
        data_revision: int,
    ) -> PeriodReportMetaV2:
        generated_at = utc_now()
        return PeriodReportMetaV2(
            period_kind=period_kind,
            period=period,
            date_from=start,
            date_to=end,
            as_of=generated_at,
            data_revision=data_revision,
            generated_at=generated_at,
        )

    @staticmethod
    def _period_income(
        transactions: list[LedgerTransaction],
        accounts: dict[UUID, Account],
        excluded_categories: set[UUID],
    ) -> int:
        total = 0
        for transaction in transactions:
            if (
                transaction.kind != TransactionKind.INCOME.value
                or transaction.category_id in excluded_categories
            ):
                continue
            for posting in transaction.postings:
                account = accounts.get(posting.account_id)
                if (
                    account is not None
                    and account.kind in {"cash", "debit"}
                    and posting.amount_minor > 0
                ):
                    total = checked_int64(total + posting.amount_minor, label="period income")
        return total

    @staticmethod
    def _period_credit_debt(accounts: dict[UUID, Account], impacts: dict[UUID, int]) -> int:
        total = 0
        for account in accounts.values():
            if account.kind != AccountKind.CREDIT.value:
                continue
            debt = checked_int64(
                account.opening_balance_minor - impacts.get(account.id, 0),
                label="period credit debt",
            )
            if debt < 0:
                invalid("invalid_reporting_projection", "Credit debt cannot be negative")
            total = checked_int64(total + debt, label="period total credit debt")
        return total

    async def _period_reimbursement_outstanding(self, recorded_before: datetime) -> int:
        """Rebuild period-end outstanding from immutable formal revisions.

        A period report is an as-of accounting read, not a view over today's
        mutable claim matrix.  We select each claim's last revision recorded
        before the Shanghai period end, then select the corresponding source
        and receipt transaction *revision* snapshots with the same cutoff.
        The current transaction table is deliberately not read: later edits to
        occurred_at, amount, kind or void state cannot rewrite a closed period.
        Receipt snapshots establish allocation ownership; transaction revision
        snapshots are the sole authority for receipt business time and ledger
        state.  Later allocations, cancellation/void transitions, receipt
        edits, and received cash cannot rewrite a previously closed period.

        Draft and submitted claims are both included: P30's outstanding facts
        define the measure as an active reimbursable allocation, while the
        revision snapshot retains the lifecycle for an auditor to distinguish
        draft/pending/partial.  A cancelled or voided snapshot contributes no
        outstanding amount.
        """
        claim_snapshots = await self.repository.period_reimbursement_claim_snapshots(
            recorded_before=recorded_before
        )
        if not claim_snapshots:
            return 0
        claims: dict[UUID, ReimbursementClaimResponse] = {}
        allocation_sources: dict[UUID, UUID] = {}
        allocation_amounts: dict[UUID, int] = {}
        for claim_id, snapshot in claim_snapshots:
            response = ReimbursementClaimResponse.model_validate(snapshot)
            if response.voided_at is not None or response.cancelled_at is not None:
                continue
            claims[claim_id] = response
            for party in response.parties:
                for allocation in party.allocations:
                    allocation_sources[allocation.id] = allocation.transaction_id
                    allocation_amounts[allocation.id] = allocation.amount_minor
        source_transactions = await self.repository.period_transaction_snapshots(
            transaction_ids=set(allocation_sources.values()), recorded_before=recorded_before
        )
        eligible_allocations: set[UUID] = set()
        for allocation_id, transaction_id in allocation_sources.items():
            snapshot = source_transactions.get(transaction_id)
            if snapshot is None:
                continue
            transaction = TransactionResponse.model_validate(snapshot)
            if transaction.id != transaction_id:
                invalid("invalid_reporting_projection", "Transaction revision identity mismatch")
            if transaction.kind not in {TransactionKind.EXPENSE, TransactionKind.CREDIT_PURCHASE}:
                continue
            if transaction.amount_minor < allocation_amounts[allocation_id]:
                invalid(
                    "invalid_reporting_projection",
                    "Reimbursement allocation exceeds its transaction revision amount",
                )
            if transaction.occurred_at >= recorded_before or transaction.voided_at is not None:
                continue
            eligible_allocations.add(allocation_id)
        received_by_allocation: dict[UUID, int] = defaultdict(int)
        receipt_snapshots = await self.repository.period_reimbursement_receipt_snapshots(
            recorded_before=recorded_before
        )
        receipt_transaction_ids: set[UUID] = set()
        parsed_receipts: list[ReimbursementReceiptResponse] = []
        for snapshot in receipt_snapshots:
            receipt = ReimbursementReceiptResponse.model_validate(snapshot)
            if receipt.claim_id in claims and receipt.voided_at is None:
                parsed_receipts.append(receipt)
                receipt_transaction_ids.add(receipt.transaction.id)
        receipt_transactions = await self.repository.period_transaction_snapshots(
            transaction_ids=receipt_transaction_ids, recorded_before=recorded_before
        )
        for receipt in parsed_receipts:
            snapshot = receipt_transactions.get(receipt.transaction.id)
            if snapshot is None:
                continue
            transaction = TransactionResponse.model_validate(snapshot)
            if transaction.id != receipt.transaction.id:
                invalid(
                    "invalid_reporting_projection", "Receipt transaction revision identity mismatch"
                )
            if transaction.kind is not TransactionKind.REIMBURSEMENT_RECEIPT:
                continue
            allocated_minor = 0
            for allocation in receipt.allocations:
                allocated_minor = checked_int64(
                    allocated_minor + allocation.amount_minor,
                    label="period reimbursement receipt allocations",
                )
            if (
                transaction.amount_minor != receipt.amount_minor
                or allocated_minor != receipt.amount_minor
            ):
                invalid(
                    "invalid_reporting_projection",
                    "Receipt revision and transaction revision amounts disagree",
                )
            if transaction.occurred_at >= recorded_before or transaction.voided_at is not None:
                continue
            for allocation in receipt.allocations:
                if allocation.allocation_id not in eligible_allocations:
                    continue
                received_by_allocation[allocation.allocation_id] = checked_int64(
                    received_by_allocation[allocation.allocation_id] + allocation.amount_minor,
                    label="period reimbursement received",
                )
        total = 0
        for allocation_id in eligible_allocations:
            outstanding = checked_int64(
                allocation_amounts[allocation_id] - received_by_allocation[allocation_id],
                label="period reimbursement outstanding",
            )
            if outstanding < 0:
                invalid(
                    "invalid_reporting_projection",
                    "Reimbursement receipts exceed their period-end allocation",
                )
            total = checked_int64(total + outstanding, label="period reimbursement total")
        return total

    @classmethod
    def _period_account_rows(
        cls,
        accounts: dict[UUID, Account],
        transactions: list[LedgerTransaction],
        opening_impacts: dict[UUID, int],
        closing_impacts: dict[UUID, int],
    ) -> list[ReportAccountBalance]:
        activity: dict[UUID, list[int]] = defaultdict(lambda: [0, 0, 0, 0])
        for transaction in transactions:
            for posting in transaction.postings:
                account = accounts.get(posting.account_id)
                if account is None:
                    continue
                if transaction.kind == TransactionKind.TRANSFER.value:
                    if posting.amount_minor > 0:
                        activity[account.id][2] = checked_int64(
                            activity[account.id][2] + posting.amount_minor,
                            label="period account transfer inflow",
                        )
                    else:
                        activity[account.id][3] = checked_int64(
                            activity[account.id][3] + cls._magnitude(posting.amount_minor),
                            label="period account transfer outflow",
                        )
                elif posting.amount_minor > 0:
                    activity[account.id][0] = checked_int64(
                        activity[account.id][0] + posting.amount_minor,
                        label="period account inflow",
                    )
                else:
                    activity[account.id][1] = checked_int64(
                        activity[account.id][1] + cls._magnitude(posting.amount_minor),
                        label="period account outflow",
                    )
        rows: list[ReportAccountBalance] = []
        for account in sorted(accounts.values(), key=lambda item: (item.sort_order, item.id)):
            opening_impact = opening_impacts.get(account.id, 0)
            closing_impact = closing_impacts.get(account.id, 0)
            if account.kind == AccountKind.CREDIT.value:
                opening = checked_int64(
                    account.opening_balance_minor - opening_impact,
                    label="report credit opening balance",
                )
                closing = checked_int64(
                    account.opening_balance_minor - closing_impact,
                    label="report credit closing balance",
                )
            else:
                opening = checked_int64(
                    account.opening_balance_minor + opening_impact,
                    label="report account opening balance",
                )
                closing = checked_int64(
                    account.opening_balance_minor + closing_impact,
                    label="report account closing balance",
                )
            amounts = activity[account.id]
            rows.append(
                ReportAccountBalance(
                    account_id=account.id,
                    account_name=account.name,
                    account_kind=AccountKind(account.kind),
                    opening_balance_minor=opening,
                    closing_balance_minor=closing,
                    period_inflow_minor=amounts[0],
                    period_outflow_minor=amounts[1],
                    internal_transfer_inflow_minor=amounts[2],
                    internal_transfer_outflow_minor=amounts[3],
                )
            )
        return rows

    @staticmethod
    def _period_category_rows(
        spending: list[_SpendingFact], categories: dict[UUID, Category]
    ) -> list[ReportCategoryTotal]:
        grouped: dict[UUID | None, list[_SpendingFact]] = defaultdict(list)
        for fact in spending:
            grouped[fact.transaction.category_id].append(fact)
        return sorted(
            [
                ReportCategoryTotal(
                    category_id=category_id,
                    category_name=(
                        categories[category_id].name
                        if category_id is not None and category_id in categories
                        else "未归类"
                    ),
                    gross_consumption_minor=values.gross_consumption_minor,
                    merchant_refund_minor=values.merchant_refund_minor,
                    net_consumption_minor=values.net_consumption_minor,
                    transaction_count=len(facts),
                )
                for category_id, facts in grouped.items()
                for values in [ReportingService._sum_spending(facts)]
            ],
            key=lambda item: (
                -item.net_consumption_minor,
                item.category_name,
                str(item.category_id),
            ),
        )

    @staticmethod
    def _period_category_rows_v2(
        spending: list[_SpendingFact], categories: dict[UUID, Category]
    ) -> list[ReportCategoryTotalV2]:
        grouped: dict[UUID | None, list[_SpendingFact]] = defaultdict(list)
        for fact in spending:
            grouped[fact.transaction.category_id].append(fact)
        return sorted(
            [
                ReportCategoryTotalV2(
                    category_id=category_id,
                    category_name=(
                        categories[category_id].name
                        if category_id is not None and category_id in categories
                        else "未归类"
                    ),
                    transaction_count=len(facts),
                    **ReportingService._sum_spending(facts).model_dump(),
                )
                for category_id, facts in grouped.items()
            ],
            key=lambda item: (
                -item.net_consumption_minor,
                item.category_name,
                str(item.category_id),
            ),
        )

    @staticmethod
    def _period_merchant_rows(
        spending: list[_SpendingFact], merchant_by_transaction: dict[UUID, Merchant]
    ) -> list[ReportMerchantTotal]:
        grouped: dict[UUID | None, list[_SpendingFact]] = defaultdict(list)
        for fact in spending:
            merchant = merchant_by_transaction.get(fact.transaction.id)
            grouped[merchant.id if merchant else None].append(fact)
        return sorted(
            [
                ReportMerchantTotal(
                    merchant_id=merchant_id,
                    merchant_name=(
                        merchant_by_transaction[facts[0].transaction.id].name
                        if merchant_id is not None
                        else "未映射商户"
                    ),
                    net_consumption_minor=ReportingService._sum_spending(
                        facts
                    ).net_consumption_minor,
                    transaction_count=len(facts),
                )
                for merchant_id, facts in grouped.items()
            ],
            key=lambda item: (
                -item.net_consumption_minor,
                item.merchant_name,
                str(item.merchant_id),
            ),
        )

    @staticmethod
    def _period_source_rows(transactions: list[LedgerTransaction]) -> list[ReportSourceTotal]:
        counts: dict[str, int] = defaultdict(int)
        for transaction in transactions:
            counts[transaction.source] += 1
        return [
            ReportSourceTotal(source=TransactionSource(source), transaction_count=count)
            for source, count in sorted(counts.items())
        ]

    async def _merchant_by_transaction(self, transaction_ids: set[UUID]) -> dict[UUID, Merchant]:
        if not transaction_ids:
            return {}
        rows = await self.session.execute(
            select(TransactionMerchantMapping.transaction_id, Merchant)
            .join(Merchant, Merchant.id == TransactionMerchantMapping.merchant_id)
            .where(TransactionMerchantMapping.transaction_id.in_(transaction_ids))
        )
        return {transaction_id: merchant for transaction_id, merchant in rows.tuples()}

    @classmethod
    def _period_drill_down_item(
        cls,
        transaction: LedgerTransaction,
        *,
        categories: dict[UUID, Category],
        merchant: Merchant | None,
        spending: _SpendingFact | None,
    ) -> PeriodReportDrillDownItem:
        external_cash = 0
        if transaction.kind != TransactionKind.TRANSFER.value:
            external_cash = checked_int64(
                sum(posting.amount_minor for posting in transaction.postings),
                label="period drill-down transaction amount",
            )
        return PeriodReportDrillDownItem(
            transaction_id=transaction.id,
            occurred_at=transaction.occurred_at,
            business_date=cls._business_date(transaction.occurred_at),
            kind=TransactionKind(transaction.kind),
            source=TransactionSource(transaction.source),
            category_id=transaction.category_id,
            category_name=(
                categories[transaction.category_id].name
                if transaction.category_id is not None and transaction.category_id in categories
                else None
            ),
            merchant_id=merchant.id if merchant else None,
            merchant_name=merchant.name if merchant else None,
            external_cash_amount_minor=external_cash,
            gross_consumption_minor=spending.gross if spending else 0,
            merchant_refund_minor=spending.refund if spending else 0,
            net_consumption_minor=spending.net if spending else 0,
        )

    @classmethod
    def _period_drill_down_item_v2(
        cls,
        transaction: LedgerTransaction,
        *,
        categories: dict[UUID, Category],
        accounts: dict[UUID, Account],
        merchant: Merchant | None,
        spending: _SpendingFact | None,
    ) -> PeriodReportDrillDownItemV2:
        primary = next(
            (
                posting
                for posting in transaction.postings
                if posting.role in {PostingRole.ACCOUNT.value, PostingRole.SOURCE.value}
            ),
            transaction.postings[0] if transaction.postings else None,
        )
        destination = next(
            (
                posting
                for posting in transaction.postings
                if posting.role == PostingRole.DESTINATION.value
            ),
            None,
        )
        primary_account = accounts.get(primary.account_id) if primary is not None else None
        destination_account = (
            accounts.get(destination.account_id) if destination is not None else None
        )
        category = categories.get(transaction.category_id) if transaction.category_id else None
        external_cash = 0
        if transaction.kind != TransactionKind.TRANSFER.value:
            external_cash = checked_int64(
                sum(posting.amount_minor for posting in transaction.postings),
                label="period drill-down transaction amount",
            )
        amounts = cls._sum_spending([spending] if spending is not None else [])
        return PeriodReportDrillDownItemV2(
            transaction_id=transaction.id,
            occurred_at=transaction.occurred_at,
            business_date=cls._business_date(transaction.occurred_at),
            title=transaction.title,
            kind=TransactionKind(transaction.kind),
            source=TransactionSource(transaction.source),
            category_id=transaction.category_id,
            category_name=category.name if category is not None else None,
            merchant_id=merchant.id if merchant else None,
            merchant_name=merchant.name if merchant else None,
            account_id=primary_account.id if primary_account is not None else None,
            account_name=primary_account.name if primary_account is not None else None,
            destination_account_id=(
                destination_account.id if destination_account is not None else None
            ),
            destination_account_name=(
                destination_account.name if destination_account is not None else None
            ),
            external_cash_amount_minor=external_cash,
            **amounts.model_dump(),
            status="voided" if transaction.voided_at is not None else "active",
            voided_at=transaction.voided_at,
            account_archived=(
                primary_account.archived_at is not None if primary_account is not None else False
            ),
            category_archived=category.archived_at is not None if category is not None else False,
        )

    @staticmethod
    def _period_report_changed(
        expected_data_revision: int,
        current_data_revision: int,
        *,
        period_kind: ReportPeriodKind,
        period: str,
        drill_down: bool = False,
        version: int = 1,
    ) -> None:
        prefix = "/api/v1/reports/v2" if version == 2 else "/api/v1/reports"
        report_path = f"{prefix}/{period_kind.value}ly/{period}"
        reload_path = (
            f"{prefix}/period-drill-down?period_kind={period_kind.value}&period={period}"
            if drill_down
            else report_path
        )
        conflict(
            "period_report_changed",
            "The report data changed while it was being read; reload it before exporting",
            details={
                "reason": "data_revision_changed",
                "expected_data_revision": expected_data_revision,
                "current_data_revision": current_data_revision,
                "safe_to_reload": True,
                "reload_path": reload_path,
            },
        )

    @staticmethod
    def _encode_period_report_cursor(
        *,
        period_kind: ReportPeriodKind,
        period: str,
        expected_data_revision: int,
        category_id: UUID | None,
        account_id: UUID | None,
        merchant_id: UUID | None,
        source: TransactionSource | None,
        occurred_at: datetime,
        transaction_id: UUID,
    ) -> str:
        payload = {
            "v": 1,
            "period_kind": period_kind.value,
            "period": period,
            "revision": expected_data_revision,
            "category_id": str(category_id) if category_id else None,
            "account_id": str(account_id) if account_id else None,
            "merchant_id": str(merchant_id) if merchant_id else None,
            "source": source.value if source else None,
            "time": occurred_at.isoformat(),
            "id": str(transaction_id),
        }
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    @staticmethod
    def _decode_period_report_cursor(
        cursor: str | None,
        *,
        period_kind: ReportPeriodKind,
        period: str,
        expected_data_revision: int,
        category_id: UUID | None,
        account_id: UUID | None,
        merchant_id: UUID | None,
        source: TransactionSource | None,
    ) -> tuple[datetime | None, UUID | None]:
        if cursor is None:
            return None, None
        try:
            raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
            decoded = json.loads(raw)
            if not isinstance(decoded, dict):
                raise ValueError
            payload = cast(dict[str, object], decoded)
            if (
                type(payload.get("v")) is not int
                or payload["v"] != 1
                or type(payload.get("revision")) is not int
                or payload["revision"] != expected_data_revision
                or payload.get("period_kind") != period_kind.value
                or payload.get("period") != period
                or payload.get("category_id") != (str(category_id) if category_id else None)
                or payload.get("account_id") != (str(account_id) if account_id else None)
                or payload.get("merchant_id") != (str(merchant_id) if merchant_id else None)
                or payload.get("source") != (source.value if source else None)
                or not isinstance(payload.get("time"), str)
                or not isinstance(payload.get("id"), str)
            ):
                raise ValueError
            time_value = payload["time"]
            identifier = payload["id"]
            if not isinstance(time_value, str) or not isinstance(identifier, str):
                raise ValueError
            occurred_at = datetime.fromisoformat(time_value)
            if occurred_at.tzinfo is None or occurred_at.utcoffset() is None:
                raise ValueError
            return occurred_at, UUID(identifier)
        except (
            ValueError,
            TypeError,
            KeyError,
            UnicodeDecodeError,
            binascii.Error,
            json.JSONDecodeError,
        ) as error:
            invalid("invalid_period_report_cursor", "The period report cursor is invalid")
            raise AssertionError from error

    async def _spending_facts(
        self,
        start: date,
        end: date,
        *,
        excluded_category_ids: set[UUID],
    ) -> list[_SpendingFact]:
        occurred_from, occurred_to = self._bounds(start, end)
        transactions = await self.repository.transactions(
            occurred_from=occurred_from,
            occurred_to_exclusive=occurred_to,
            kinds=SPENDING_KINDS,
            excluded_category_ids=excluded_category_ids,
        )
        return await self._facts_for_transactions(transactions)

    async def _facts_for_transactions(
        self, transactions: list[LedgerTransaction]
    ) -> list[_SpendingFact]:
        ids = {item.id for item in transactions}
        refunds: dict[UUID, int] = defaultdict(int)
        for refund in await self.repository.refunds_for_sources(ids):
            refunds[refund.source_transaction_id] = checked_int64(
                refunds[refund.source_transaction_id] + refund.amount_minor,
                label="merchant refund",
            )
        reimbursements: dict[UUID, tuple[int, int]] = defaultdict(lambda: (0, 0))
        for fact in await self.repository.reimbursement_facts(ids):
            expected, received = reimbursements[fact.source_transaction_id]
            effective = self._effective_expected(fact)
            reimbursements[fact.source_transaction_id] = (
                checked_int64(expected + effective, label="expected reimbursement"),
                checked_int64(received + fact.received_minor, label="received reimbursement"),
            )
        result: list[_SpendingFact] = []
        for transaction in transactions:
            gross = self._canonical_spending(transaction)
            refund = refunds.get(transaction.id, 0)
            expected, received = reimbursements.get(transaction.id, (0, 0))
            if refund > gross or expected > gross - refund or received > gross - refund:
                invalid("invalid_reporting_projection", "Spending adjustments exceed consumption")
            result.append(
                _SpendingFact(
                    transaction=transaction,
                    account_id=transaction.postings[0].account_id,
                    gross=gross,
                    refund=refund,
                    expected=expected,
                    received=received,
                )
            )
        return result

    async def _cash_flow_actual(self, start: date, end: date) -> _CashFlowProjection:
        occurred_from, occurred_to = self._bounds(start, end)
        categories = await self.repository.categories()
        transactions = await self.repository.transactions(
            occurred_from=occurred_from,
            occurred_to_exclusive=occurred_to,
            excluded_category_ids=self._excluded_category_ids(categories),
        )
        accounts = await self.repository.accounts()
        external_in = external_out = transfer_in = transfer_out = 0
        account_values: dict[UUID, list[int]] = defaultdict(lambda: [0, 0, 0, 0])
        for account in accounts.values():
            if account.kind in {"cash", "debit"}:
                account_values[account.id]
        daily: dict[date, list[int]] = defaultdict(lambda: [0, 0])
        for transaction in transactions:
            business_day = self._business_date(transaction.occurred_at)
            for posting in transaction.postings:
                account = accounts.get(posting.account_id)
                if account is None or account.kind not in {"cash", "debit"}:
                    continue
                amount = posting.amount_minor
                if transaction.kind == "transfer":
                    if amount > 0:
                        transfer_in = checked_int64(transfer_in + amount, label="transfer inflow")
                        account_values[account.id][2] = checked_int64(
                            account_values[account.id][2] + amount, label="account transfer inflow"
                        )
                    else:
                        magnitude = self._magnitude(amount)
                        transfer_out = checked_int64(
                            transfer_out + magnitude, label="transfer outflow"
                        )
                        account_values[account.id][3] = checked_int64(
                            account_values[account.id][3] + magnitude,
                            label="account transfer outflow",
                        )
                    continue
                if amount > 0:
                    external_in = checked_int64(external_in + amount, label="cash inflow")
                    account_values[account.id][0] = checked_int64(
                        account_values[account.id][0] + amount, label="account cash inflow"
                    )
                    daily[business_day][0] = checked_int64(
                        daily[business_day][0] + amount, label="daily cash inflow"
                    )
                else:
                    magnitude = self._magnitude(amount)
                    external_out = checked_int64(external_out + magnitude, label="cash outflow")
                    account_values[account.id][1] = checked_int64(
                        account_values[account.id][1] + magnitude, label="account cash outflow"
                    )
                    daily[business_day][1] = checked_int64(
                        daily[business_day][1] + magnitude, label="daily cash outflow"
                    )
        account_rows: list[CashFlowAccountRow] = []
        for account_id, values in sorted(account_values.items(), key=lambda item: str(item[0])):
            account = accounts[account_id]
            account_rows.append(
                CashFlowAccountRow(
                    account_id=account_id,
                    account_name=account.name,
                    account_kind=AccountKind(account.kind),
                    inflow_minor=values[0],
                    outflow_minor=values[1],
                    net_minor=checked_int64(values[0] - values[1], label="account cash net"),
                    internal_transfer_inflow_minor=values[2],
                    internal_transfer_outflow_minor=values[3],
                )
            )
        trend: list[CashFlowTrendPoint] = []
        cursor = start
        while cursor <= end:
            values = daily.get(cursor, [0, 0])
            trend.append(
                CashFlowTrendPoint(
                    date=cursor,
                    inflow_minor=values[0],
                    outflow_minor=values[1],
                    net_minor=checked_int64(values[0] - values[1], label="daily cash net"),
                )
            )
            if cursor == end:
                break
            cursor += timedelta(days=1)
        return {
            "inflow_minor": external_in,
            "outflow_minor": external_out,
            "net_minor": checked_int64(external_in - external_out, label="cash flow net"),
            "internal_transfer_inflow_minor": transfer_in,
            "internal_transfer_outflow_minor": transfer_out,
            "accounts": account_rows,
            "trend": trend,
        }

    @classmethod
    def _excluded_category_ids(cls, categories: dict[UUID, Category]) -> set[UUID]:
        excluded = {item.id for item in categories.values() if item.is_balance_adjustment}
        while True:
            children = {
                item.id
                for item in categories.values()
                if item.parent_id is not None and item.parent_id in excluded
            }
            if children <= excluded:
                return excluded
            excluded.update(children)

    async def _forecast(self, today: date, days: int) -> ForecastSummary:
        date_to_exclusive = today + timedelta(days=days)
        accounts = await self.repository.accounts()
        cycles = await self.repository.credit_cycles()
        amounts = await self.repository.credit_cycle_amounts([item.id for item in cycles])
        events: list[ForecastEvent] = []
        exact_due = expected_receipt = undated = 0
        for cycle in cycles:
            account = accounts.get(cycle.account_id)
            if account is None:
                continue
            row = self._debt_cycle(cycle, account, amounts.get(cycle.id, (0, 0)), today)
            if row.remaining_minor <= 0 or not today <= row.due_date < date_to_exclusive:
                continue
            exact_due = checked_int64(exact_due + row.remaining_minor, label="forecast exact due")
            events.append(
                ForecastEvent(
                    source_id=cycle.id,
                    date=cycle.due_date,
                    direction=ForecastDirection.OUTFLOW,
                    amount_minor=row.remaining_minor,
                    basis=ForecastBasis.EXACT_DUE,
                    certainty=ForecastCertainty.EXACT,
                    title=f"{account.name} 账单应还",
                    account_id=account.id,
                    cycle_id=cycle.id,
                )
            )
        party_values: dict[UUID, tuple[ReimbursementFact, int]] = {}
        for fact in await self.repository.reimbursement_facts():
            if fact.claim_voided_at is not None or fact.cancelled_at is not None:
                continue
            if fact.submitted_at is None:
                continue
            current = party_values.get(fact.party_id)
            outstanding = checked_int64(
                fact.allocated_minor - fact.received_minor, label="reimbursement outstanding"
            )
            if outstanding <= 0:
                continue
            total = (
                outstanding
                if current is None
                else checked_int64(
                    current[1] + outstanding, label="party reimbursement outstanding"
                )
            )
            party_values[fact.party_id] = (fact, total)
        for fact, outstanding in party_values.values():
            if fact.expected_date is None:
                undated = checked_int64(undated + outstanding, label="undated reimbursement")
            elif today <= fact.expected_date < date_to_exclusive:
                expected_receipt = checked_int64(
                    expected_receipt + outstanding, label="forecast reimbursement"
                )
                events.append(
                    ForecastEvent(
                        source_id=fact.party_id,
                        date=fact.expected_date,
                        direction=ForecastDirection.INFLOW,
                        amount_minor=outstanding,
                        basis=ForecastBasis.EXPECTED_RECEIPT,
                        certainty=ForecastCertainty.EXPECTED,
                        title=f"{fact.party_name} 预计报销",
                        claim_id=fact.claim_id,
                        party_id=fact.party_id,
                    )
                )
        events.sort(key=lambda item: (item.date, item.direction.value, item.source_id))
        return ForecastSummary(
            today=today,
            date_to=date_to_exclusive - timedelta(days=1),
            exact_due_outflow_minor=exact_due,
            expected_receipt_inflow_minor=expected_receipt,
            undated_expected_receipt_minor=undated,
            events=events,
        )

    async def _installment_groups(
        self, as_of: date, cycles: list[DebtCycleRow]
    ) -> list[DebtInstallmentGroup]:
        cycle_map = {item.cycle_id: item for item in cycles}
        grouped: dict[str, list[tuple[InstallmentPeriod, InstallmentPlan]]] = defaultdict(list)
        plans: dict[UUID, InstallmentPlan] = {}
        for period, plan, cycle, _purchase in await self.repository.installment_periods():
            cycle_row = cycle_map.get(cycle.id)
            if cycle.statement_date < as_of or cycle_row is None or cycle_row.remaining_minor == 0:
                continue
            month = cycle.statement_date.strftime("%Y-%m")
            grouped[month].append((period, plan))
            plans[plan.id] = plan
        from fiscal_api.services.installments import InstallmentService

        service = InstallmentService(self.session)
        responses = {plan_id: await service.response(plan) for plan_id, plan in plans.items()}
        result: list[DebtInstallmentGroup] = []
        for month, values in sorted(grouped.items()):
            principal = self._checked_sum(period.principal_minor for period, _ in values)
            fee = self._checked_sum(period.fee_minor for period, _ in values)
            unique_ids = sorted({plan.id for _, plan in values}, key=str)
            result.append(
                DebtInstallmentGroup(
                    month=month,
                    principal_scheduled_gross_minor=principal,
                    fee_scheduled_gross_minor=fee,
                    total_scheduled_gross_minor=checked_int64(
                        principal + fee, label="installment scheduled gross"
                    ),
                    period_count=len(values),
                    plans=[service.teaser(responses[item]) for item in unique_ids],
                )
            )
        return result

    async def _reimbursement_outstanding(self) -> int:
        total = 0
        for fact in await self.repository.reimbursement_facts():
            effective = self._effective_expected(fact)
            total = checked_int64(
                total + effective - fact.received_minor,
                label="reimbursement outstanding",
            )
        return total

    @staticmethod
    def _debt_cycle(
        cycle: CreditCycle, account: Account, amounts: tuple[int, int], as_of: date
    ) -> DebtCycleRow:
        purchase = checked_int64(amounts[0], label="credit cycle purchases")
        repaid = checked_int64(amounts[1], label="credit cycle repayments")
        opening = account.opening_balance_minor if cycle.is_opening_cycle else 0
        due = checked_int64(opening + purchase, label="credit cycle amount due")
        remaining = checked_int64(due - repaid, label="credit cycle remaining")
        if remaining < 0:
            invalid("invalid_reporting_projection", "A credit cycle is overpaid")
        if remaining == 0:
            status = CreditCycleStatus.SETTLED
        elif cycle.due_date < as_of:
            status = CreditCycleStatus.OVERDUE
        elif cycle.statement_date >= as_of:
            status = CreditCycleStatus.OPEN
        elif repaid > 0:
            status = CreditCycleStatus.PARTIAL
        else:
            status = CreditCycleStatus.UNPAID
        return DebtCycleRow(
            cycle_id=cycle.id,
            account_id=account.id,
            account_name=account.name,
            period_start=cycle.period_start,
            period_end=cycle.period_end,
            statement_date=cycle.statement_date,
            due_date=cycle.due_date,
            amount_due_minor=due,
            repaid_minor=repaid,
            remaining_minor=remaining,
            status=status,
            is_overdue=status is CreditCycleStatus.OVERDUE,
        )

    @staticmethod
    def _effective_expected(fact: ReimbursementFact) -> int:
        if fact.claim_voided_at is not None:
            return 0
        if fact.cancelled_at is not None:
            return fact.received_minor
        return fact.allocated_minor

    @staticmethod
    def _canonical_spending(transaction: LedgerTransaction) -> int:
        total = 0
        for posting in transaction.postings:
            total = checked_int64(total + posting.amount_minor, label="spending posting sum")
        if total >= 0:
            invalid("invalid_reporting_projection", "A spending transaction has no outflow")
        return ReportingService._magnitude(total)

    @staticmethod
    def _magnitude(value: int) -> int:
        if value == INT64_MIN:
            checked_int64(-value, label="posting magnitude")
        return -value

    @staticmethod
    def _sum_spending(facts: list[_SpendingFact]) -> SpendingAmounts:
        gross = refund = expected = received = 0
        for fact in facts:
            gross = checked_int64(gross + fact.gross, label="gross consumption")
            refund = checked_int64(refund + fact.refund, label="merchant refund")
            expected = checked_int64(expected + fact.expected, label="expected reimbursement")
            received = checked_int64(received + fact.received, label="received reimbursement")
        net = checked_int64(gross - refund, label="net consumption")
        return SpendingAmounts(
            gross_consumption_minor=gross,
            merchant_refund_minor=refund,
            net_consumption_minor=net,
            expected_reimbursement_minor=expected,
            received_reimbursement_minor=received,
            personal_expected_minor=checked_int64(net - expected, label="personal expected"),
            personal_realized_minor=checked_int64(net - received, label="personal realized"),
        )

    def _bucket(
        self,
        facts: list[_SpendingFact],
        *,
        category_id: UUID | None,
        root_category_id: UUID | None,
        name: str,
        icon: str | None,
        color_hex: str | None,
    ) -> SpendingBucket:
        values = self._sum_spending(facts)
        return SpendingBucket(
            category_id=category_id,
            root_category_id=root_category_id,
            name=name,
            icon=icon,
            color_hex=color_hex,
            transaction_count=len(facts),
            **values.model_dump(),
        )

    def _category_rows(
        self, facts: list[_SpendingFact], categories: dict[UUID, Category]
    ) -> list[SpendingCategoryRoot]:
        facts_by_category: dict[UUID, list[_SpendingFact]] = defaultdict(list)
        for fact in facts:
            if fact.transaction.category_id is not None:
                facts_by_category[fact.transaction.category_id].append(fact)
        result: list[SpendingCategoryRoot] = []
        roots = [item for item in categories.values() if item.parent_id is None]
        for root in sorted(roots, key=lambda item: (item.sort_order, item.created_at, item.id)):
            direct_facts = facts_by_category.get(root.id, [])
            child_rows: list[SpendingBucket] = []
            rollup = list(direct_facts)
            children = [item for item in categories.values() if item.parent_id == root.id]
            for child in sorted(
                children, key=lambda item: (item.sort_order, item.created_at, item.id)
            ):
                child_facts = facts_by_category.get(child.id, [])
                rollup.extend(child_facts)
                if child_facts:
                    child_rows.append(
                        self._bucket(
                            child_facts,
                            category_id=child.id,
                            root_category_id=root.id,
                            name=child.name,
                            icon=child.icon,
                            color_hex=child.color_hex,
                        )
                    )
            child_rows.sort(key=lambda item: self._spending_bucket_sort_key(item, categories))
            if not rollup:
                continue
            direct = self._bucket(
                direct_facts,
                category_id=root.id,
                root_category_id=root.id,
                name=root.name,
                icon=root.icon,
                color_hex=root.color_hex,
            )
            values = self._sum_spending(rollup)
            result.append(
                SpendingCategoryRoot(
                    category_id=root.id,
                    root_category_id=root.id,
                    name=root.name,
                    icon=root.icon,
                    color_hex=root.color_hex,
                    transaction_count=len(rollup),
                    direct=direct,
                    children=child_rows,
                    **values.model_dump(),
                )
            )
        result.sort(key=lambda item: self._spending_bucket_sort_key(item, categories))
        return result

    @staticmethod
    def _category_stable_key(category: Category) -> tuple[int, datetime, UUID]:
        return (category.sort_order, category.created_at, category.id)

    def _spending_bucket_sort_key(
        self, item: SpendingBucket, categories: dict[UUID, Category]
    ) -> tuple[int, tuple[int, datetime, UUID]]:
        category_id = item.category_id
        assert category_id is not None
        return (-item.personal_realized_minor, self._category_stable_key(categories[category_id]))

    @staticmethod
    def _overview_credit_due_events(
        *, cycles: list[DebtCycleRow], today: date
    ) -> list[OverviewCreditDueEvent]:
        date_to_exclusive = today + timedelta(days=OVERVIEW_CREDIT_DUE_WINDOW_DAYS)
        grouped: dict[tuple[UUID, date], list[DebtCycleRow]] = defaultdict(list)
        for cycle in cycles:
            if cycle.remaining_minor <= 0 or not today <= cycle.due_date < date_to_exclusive:
                continue
            grouped[(cycle.account_id, cycle.due_date)].append(cycle)
        events: list[OverviewCreditDueEvent] = []
        for (account_id, due_date), members in grouped.items():
            ordered = sorted(members, key=lambda item: item.cycle_id)
            events.append(
                OverviewCreditDueEvent(
                    account_id=account_id,
                    account_name=ordered[0].account_name,
                    due_date=due_date,
                    remaining_minor=ReportingService._checked_sum(
                        item.remaining_minor for item in ordered
                    ),
                    cycle_ids=[item.cycle_id for item in ordered],
                )
            )
        return sorted(events, key=lambda item: (item.due_date, item.account_name, item.account_id))

    def _cash_line(
        self,
        posting: Posting,
        transaction: LedgerTransaction,
        account: Account,
        categories: dict[UUID, Category],
    ) -> ReportLineItem:
        category, root = self._category_pair(transaction.category_id, categories)
        return ReportLineItem(
            id=posting.id,
            transaction_id=transaction.id,
            lens=ReportLens.CASH_FLOW,
            occurred_at=transaction.occurred_at,
            business_date=self._business_date(transaction.occurred_at),
            title=transaction.title,
            kind=TransactionKind(transaction.kind),
            signed_amount_minor=posting.amount_minor,
            account_id=account.id,
            account_name=account.name,
            category_id=category.id if category else None,
            category_name=category.name if category else None,
            root_category_id=root.id if root else None,
            root_category_name=root.name if root else None,
            internal_transfer=transaction.kind == "transfer",
        )

    def _spending_line(
        self,
        fact: _SpendingFact,
        categories: dict[UUID, Category],
        accounts: dict[UUID, Account],
    ) -> ReportLineItem:
        transaction = fact.transaction
        category, root = self._category_pair(transaction.category_id, categories)
        account = accounts.get(fact.account_id)
        return ReportLineItem(
            id=transaction.id,
            transaction_id=transaction.id,
            lens=ReportLens.SPENDING,
            occurred_at=transaction.occurred_at,
            business_date=self._business_date(transaction.occurred_at),
            title=transaction.title,
            kind=TransactionKind(transaction.kind),
            signed_amount_minor=fact.personal_realized,
            account_id=fact.account_id,
            account_name=account.name if account else None,
            category_id=category.id if category else None,
            category_name=category.name if category else None,
            root_category_id=root.id if root else None,
            root_category_name=root.name if root else None,
            gross_consumption_minor=fact.gross,
            merchant_refund_minor=fact.refund,
            expected_reimbursement_minor=fact.expected,
            received_reimbursement_minor=fact.received,
        )

    @staticmethod
    def _category_pair(
        category_id: UUID | None, categories: dict[UUID, Category]
    ) -> tuple[Category | None, Category | None]:
        category = categories.get(category_id) if category_id else None
        if category is None:
            return None, None
        return category, categories.get(category.parent_id) if category.parent_id else category

    @staticmethod
    def _spending_values(report: SpendingReport) -> dict[str, int]:
        return {name: getattr(report, name) for name in SpendingAmounts.model_fields}

    @staticmethod
    def _checked_sum(values: Iterable[int]) -> int:
        total = 0
        for value in values:
            total = checked_int64(total + value)
        return total

    def _month_range(self, month: str | None) -> tuple[date, date]:
        if month is None:
            today = self._today()
            return date(today.year, today.month, 1), date(
                today.year, today.month, monthrange(today.year, today.month)[1]
            )
        return self._month_range_static(month)

    def _range(self, date_from: date | None, date_to: date | None) -> tuple[date, date]:
        if (date_from is None) != (date_to is None):
            invalid("incomplete_report_range", "date_from and date_to must be provided together")
        if date_from is None or date_to is None:
            return self._month_range(None)
        if date_from > date_to:
            invalid("invalid_report_range", "date_from must not be after date_to")
        return date_from, date_to

    @staticmethod
    def _bounds(start: date, end: date) -> tuple[datetime, datetime]:
        end_exclusive = (
            datetime.max.replace(tzinfo=UTC)
            if end == date.max
            else datetime.combine(end + timedelta(days=1), time.min, BUSINESS_TIMEZONE).astimezone(
                UTC
            )
        )
        return (
            datetime.combine(start, time.min, BUSINESS_TIMEZONE).astimezone(UTC),
            end_exclusive,
        )

    @staticmethod
    def _business_date(value: datetime) -> date:
        return value.astimezone(BUSINESS_TIMEZONE).date()

    @staticmethod
    def _today() -> date:
        return utc_now().astimezone(BUSINESS_TIMEZONE).date()

    @staticmethod
    def _meta(start: date, end: date) -> ReportMeta:
        return ReportMeta(date_from=start, date_to=end, as_of=utc_now())

    @staticmethod
    def _encode_cursor(value: datetime, item_id: UUID, lens: ReportLens) -> str:
        payload = json.dumps(
            {"v": 1, "lens": lens.value, "time": value.isoformat(), "id": str(item_id)},
            separators=(",", ":"),
        )
        return base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")

    @staticmethod
    def _decode_cursor(cursor: str | None, lens: ReportLens) -> tuple[datetime | None, UUID | None]:
        if cursor is None:
            return None, None
        try:
            payload = json.loads(
                base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
            )
            if payload["v"] != 1 or payload["lens"] != lens.value:
                raise ValueError
            value = datetime.fromisoformat(payload["time"])
            if value.utcoffset() is None:
                raise ValueError
            return value, UUID(payload["id"])
        except (ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
            invalid("invalid_report_cursor", "The report cursor is invalid")
            raise AssertionError from error
