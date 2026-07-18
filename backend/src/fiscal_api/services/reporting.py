from __future__ import annotations

import base64
import json
import re
from calendar import monthrange
from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import TypedDict
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p7_schemas import (
    CashFlowAccountRow,
    CashFlowReport,
    CashFlowTrendPoint,
    DebtAccountRow,
    DebtCycleRow,
    DebtInstallmentGroup,
    DebtReport,
    ForecastBasis,
    ForecastCertainty,
    ForecastDirection,
    ForecastEvent,
    ForecastSummary,
    OverviewCashFlowSummary,
    OverviewCreditDueEvent,
    OverviewReport,
    OverviewSpendingSummary,
    ReportDrillDownPage,
    ReportLens,
    ReportLineItem,
    ReportMeta,
    SpendingAmounts,
    SpendingBucket,
    SpendingCategoryRoot,
    SpendingReport,
    SpendingTrendPoint,
)
from fiscal_api.core.time import BUSINESS_TIMEZONE, UTC, utc_now
from fiscal_api.db.models import (
    Account,
    AccountKind,
    Category,
    CreditCycle,
    CreditCycleStatus,
    InstallmentPeriod,
    InstallmentPlan,
    LedgerTransaction,
    Posting,
    TransactionKind,
)
from fiscal_api.repositories.reporting import ReimbursementFact, ReportingRepository
from fiscal_api.services.common import INT64_MIN, checked_int64, invalid

SPENDING_KINDS = {"expense", "credit_purchase", "installment_fee"}
MONTH_PATTERN = re.compile(r"^(\d{4})-(\d{2})$")
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


class ReportingService:
    EXCLUDED_CATEGORY_NAMES = frozenset({"平账"})

    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = ReportingRepository(session)

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

    async def overview(self, *, month: str | None) -> OverviewReport:
        start, end = self._month_range(month)
        spending = await self.spending(date_from=start, date_to=end)
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

        recent = [
            TransactionService.snapshot_response(item, list(item.postings))
            for item in transactions[:OVERVIEW_RECENT_TRANSACTION_LIMIT]
        ]
        return OverviewReport(
            meta=self._meta(start, end),
            account_value_minor=account_value,
            current_credit_debt_minor=debt.current_credit_debt_minor,
            reimbursement_outstanding_minor=reimbursement_outstanding,
            spending=OverviewSpendingSummary(**self._spending_values(spending)),
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
        excluded = {
            item.id for item in categories.values() if item.name in cls.EXCLUDED_CATEGORY_NAMES
        }
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
        purchase, repaid = amounts
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
        match = MONTH_PATTERN.fullmatch(month)
        if match is None:
            invalid("invalid_report_month", "month must use YYYY-MM")
        year, number = int(match.group(1)), int(match.group(2))
        if not 1 <= number <= 12:
            invalid("invalid_report_month", "month must use YYYY-MM")
        return date(year, number, 1), date(year, number, monthrange(year, number)[1])

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
        return (
            datetime.combine(start, time.min, BUSINESS_TIMEZONE).astimezone(UTC),
            datetime.combine(end + timedelta(days=1), time.min, BUSINESS_TIMEZONE).astimezone(UTC),
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
