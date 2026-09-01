from __future__ import annotations

from datetime import date, datetime
from enum import StrEnum
from typing import Literal
from uuid import UUID

from pydantic import Field

from fiscal_api.api.p3_schemas import APIModel, TransactionResponse
from fiscal_api.api.p5_schemas import InstallmentTeaser
from fiscal_api.db.models import AccountKind, CreditCycleStatus, TransactionKind


class ReportLens(StrEnum):
    SPENDING = "spending"
    CASH_FLOW = "cash_flow"


class ForecastDirection(StrEnum):
    INFLOW = "inflow"
    OUTFLOW = "outflow"


class ForecastBasis(StrEnum):
    EXACT_DUE = "exact_due"
    EXPECTED_RECEIPT = "expected_receipt"


class ForecastCertainty(StrEnum):
    EXACT = "exact"
    EXPECTED = "expected"


class KnownFutureCertainty(StrEnum):
    EXACT_DUE = "exact_due"
    CONFIRMED = "confirmed"
    EXPECTED = "expected"
    SCHEDULED = "scheduled"


class KnownFutureDirection(StrEnum):
    INFLOW = "inflow"
    OUTFLOW = "outflow"


class KnownFutureSourceType(StrEnum):
    CREDIT_CYCLE = "credit_cycle"
    REIMBURSEMENT_PARTY = "reimbursement_party"
    CASH_FLOW_ITEM = "cash_flow_item"


class FactsDrillDownScopeType(StrEnum):
    """The four additive, versioned read scopes behind the current facts cards."""

    CASH_ACCOUNTS = "cash_accounts"
    CREDIT_CYCLES = "credit_cycles"
    REIMBURSEMENT_OUTSTANDING = "reimbursement_outstanding"
    COMPLETENESS_ISSUES = "completeness_issues"


class CompletenessIssueType(StrEnum):
    UNRESOLVED_IMPORTS = "unresolved_imports"
    FAILED_IMPORTS = "failed_imports"
    UNCATEGORIZED_TRANSACTIONS = "uncategorized_transactions"


class ReportMeta(APIModel):
    timezone: Literal["Asia/Shanghai"] = "Asia/Shanghai"
    currency: Literal["CNY"] = "CNY"
    date_from: date
    date_to: date
    as_of: datetime


class SpendingAmounts(APIModel):
    gross_consumption_minor: int
    merchant_refund_minor: int
    net_consumption_minor: int
    expected_reimbursement_minor: int
    received_reimbursement_minor: int
    personal_expected_minor: int
    personal_realized_minor: int


class SpendingBucket(SpendingAmounts):
    category_id: UUID | None
    root_category_id: UUID | None
    name: str
    icon: str | None
    color_hex: str | None
    transaction_count: int


class SpendingCategoryRoot(SpendingBucket):
    direct: SpendingBucket
    children: list[SpendingBucket] = Field(default_factory=lambda: list[SpendingBucket]())


class SpendingTrendPoint(SpendingAmounts):
    date: date


class SpendingReport(SpendingAmounts):
    meta: ReportMeta
    uncategorized: SpendingBucket
    categories: list[SpendingCategoryRoot] = Field(
        default_factory=lambda: list[SpendingCategoryRoot]()
    )
    trend: list[SpendingTrendPoint] = Field(default_factory=lambda: list[SpendingTrendPoint]())


class CashFlowAmounts(APIModel):
    inflow_minor: int
    outflow_minor: int
    net_minor: int


class CashFlowAccountRow(CashFlowAmounts):
    account_id: UUID
    account_name: str
    account_kind: AccountKind
    internal_transfer_inflow_minor: int
    internal_transfer_outflow_minor: int


class CashFlowTrendPoint(CashFlowAmounts):
    date: date


class ForecastEvent(APIModel):
    source_id: UUID
    date: date
    direction: ForecastDirection
    amount_minor: int
    basis: ForecastBasis
    certainty: ForecastCertainty
    title: str
    account_id: UUID | None = None
    cycle_id: UUID | None = None
    claim_id: UUID | None = None
    party_id: UUID | None = None


class ForecastSummary(APIModel):
    today: date
    date_to: date
    exact_due_outflow_minor: int
    expected_receipt_inflow_minor: int
    undated_expected_receipt_minor: int
    events: list[ForecastEvent] = Field(default_factory=lambda: list[ForecastEvent]())


class CashFlowReport(CashFlowAmounts):
    meta: ReportMeta
    internal_transfer_inflow_minor: int
    internal_transfer_outflow_minor: int
    accounts: list[CashFlowAccountRow] = Field(default_factory=lambda: list[CashFlowAccountRow]())
    trend: list[CashFlowTrendPoint] = Field(default_factory=lambda: list[CashFlowTrendPoint]())
    forecast: ForecastSummary


class DebtCycleRow(APIModel):
    cycle_id: UUID
    account_id: UUID
    account_name: str
    period_start: date
    period_end: date
    statement_date: date
    due_date: date
    amount_due_minor: int
    repaid_minor: int
    remaining_minor: int
    status: CreditCycleStatus
    is_overdue: bool


class DebtAccountRow(APIModel):
    account_id: UUID
    account_name: str
    institution: str | None
    last_four: str | None
    credit_limit_minor: int
    current_debt_minor: int
    available_credit_minor: int
    over_limit_minor: int
    overdue_minor: int
    opening_configuration_required: bool
    has_overdue_cycle: bool
    next_due_cycle: DebtCycleRow | None


class DebtInstallmentGroup(APIModel):
    month: str
    principal_scheduled_gross_minor: int
    fee_scheduled_gross_minor: int
    total_scheduled_gross_minor: int
    period_count: int
    plans: list[InstallmentTeaser] = Field(default_factory=lambda: list[InstallmentTeaser]())


class DebtReport(APIModel):
    timezone: Literal["Asia/Shanghai"] = "Asia/Shanghai"
    currency: Literal["CNY"] = "CNY"
    as_of: date
    current_credit_debt_minor: int
    total_available_credit_minor: int
    overdue_minor: int
    accounts: list[DebtAccountRow] = Field(default_factory=lambda: list[DebtAccountRow]())
    cycles: list[DebtCycleRow] = Field(default_factory=lambda: list[DebtCycleRow]())
    installments: list[DebtInstallmentGroup] = Field(
        default_factory=lambda: list[DebtInstallmentGroup]()
    )


class OverviewSpendingSummary(SpendingAmounts):
    pass


class OverviewCashFlowSummary(CashFlowAmounts):
    pass


class OverviewCreditDueEvent(APIModel):
    account_id: UUID
    account_name: str
    due_date: date
    remaining_minor: int
    cycle_ids: list[UUID] = Field(default_factory=lambda: list[UUID]())


class OverviewReport(APIModel):
    meta: ReportMeta
    account_value_minor: int
    current_credit_debt_minor: int
    monthly_income_minor: int
    reimbursement_outstanding_minor: int
    spending: OverviewSpendingSummary
    top_spending_categories: list[SpendingCategoryRoot] = Field(
        default_factory=lambda: list[SpendingCategoryRoot]()
    )
    cash_flow: OverviewCashFlowSummary
    uncategorized_count: int
    uncategorized_amount_minor: int
    recent_transactions: list[TransactionResponse] = Field(
        default_factory=lambda: list[TransactionResponse]()
    )
    forecast: ForecastSummary
    credit_due_events: list[OverviewCreditDueEvent] = Field(
        default_factory=lambda: list[OverviewCreditDueEvent]()
    )


class ReportLineItem(APIModel):
    id: UUID
    transaction_id: UUID
    lens: ReportLens
    occurred_at: datetime
    business_date: date
    title: str
    kind: TransactionKind
    signed_amount_minor: int
    account_id: UUID | None
    account_name: str | None
    category_id: UUID | None
    category_name: str | None
    root_category_id: UUID | None
    root_category_name: str | None
    internal_transfer: bool = False
    gross_consumption_minor: int = 0
    merchant_refund_minor: int = 0
    expected_reimbursement_minor: int = 0
    received_reimbursement_minor: int = 0


class ReportDrillDownPage(APIModel):
    items: list[ReportLineItem] = Field(default_factory=lambda: list[ReportLineItem]())
    next_cursor: str | None


class FactsMeta(APIModel):
    timezone: Literal["Asia/Shanghai"] = "Asia/Shanghai"
    currency: Literal["CNY"] = "CNY"
    as_of: datetime
    data_revision: int = Field(ge=0)
    schema_version: Literal["1"] = "1"


class FactsWindow(APIModel):
    date_from: date
    date_to: date


class FactsDrillDownScope(APIModel):
    """An opaque, reload-safe link from one summary card to its source facts.

    `expected_data_revision` is deliberately part of the scope instead of a
    client freshness heuristic.  A drill-down either describes the same facts
    snapshot or returns a stable conflict telling the client to reload it.
    """

    scope_type: FactsDrillDownScopeType
    schema_version: Literal["1"] = "1"
    expected_data_revision: int = Field(ge=0)
    read_path: str
    deep_link: str


class CashFacts(APIModel):
    current_balance_minor: int
    scope: FactsDrillDownScope | None = None


class CreditFacts(APIModel):
    current_debt_minor: int
    scope: FactsDrillDownScope | None = None


class ReimbursementFacts(APIModel):
    outstanding_minor: int
    scope: FactsDrillDownScope | None = None


class CompletenessFacts(APIModel):
    unresolved_import_count: int = Field(
        ge=0,
        description="Statement imports that have not reached a terminal result.",
    )
    failed_import_count: int = Field(
        ge=0,
        description="Statement imports whose processing failed and require attention.",
    )
    uncategorized_transaction_count: int = Field(ge=0)
    uncategorized_transaction_amount_minor: int = Field(ge=0, default=0)
    scope: FactsDrillDownScope | None = None


class CashAccountFact(APIModel):
    item_type: Literal["cash_account"] = "cash_account"
    account_id: UUID
    name: str
    current_balance_minor: int
    read_path: str
    deep_link: str


class CreditCycleFact(APIModel):
    item_type: Literal["credit_cycle"] = "credit_cycle"
    cycle_id: UUID
    account_id: UUID
    account_name: str
    due_date: date
    amount_due_minor: int
    repaid_minor: int
    remaining_minor: int = Field(ge=0)
    read_path: str
    deep_link: str


class ReimbursementOutstandingFact(APIModel):
    item_type: Literal["reimbursement_outstanding"] = "reimbursement_outstanding"
    claim_id: UUID
    party_id: UUID
    party_name: str
    expected_date: date | None
    expected_minor: int = Field(ge=0)
    received_minor: int = Field(ge=0)
    outstanding_minor: int = Field(ge=0)
    read_path: str
    deep_link: str


class CompletenessIssueFact(APIModel):
    item_type: Literal["completeness_issue"] = "completeness_issue"
    issue_type: CompletenessIssueType
    count: int = Field(ge=0)
    amount_minor: int | None = Field(default=None, ge=0)
    read_path: str
    deep_link: str


FactsDrillDownItem = (
    CashAccountFact | CreditCycleFact | ReimbursementOutstandingFact | CompletenessIssueFact
)


class FactsDrillDownPage(APIModel):
    meta: FactsMeta
    scope: FactsDrillDownScope
    items: list[FactsDrillDownItem] = Field(default_factory=lambda: list[FactsDrillDownItem]())
    next_cursor: str | None


class KnownFutureEvent(APIModel):
    source_type: KnownFutureSourceType
    source_id: UUID
    date: date
    direction: KnownFutureDirection
    amount_minor: int = Field(gt=0)
    certainty: KnownFutureCertainty
    title: str
    deep_link: str
    account_id: UUID | None = None
    claim_id: UUID | None = None
    party_id: UUID | None = None
    cycle_id: UUID | None = None


class KnownFutureTotals(APIModel):
    exact_due_outflow_minor: int
    confirmed_outflow_minor: int
    expected_outflow_minor: int
    scheduled_outflow_minor: int
    confirmed_inflow_minor: int
    expected_inflow_minor: int
    scheduled_inflow_minor: int
    after_confirmed_outflow_minor: int


class KnownFutureEventPage(APIModel):
    """A revision-bound, keyset-paginated view of known future facts.

    This is deliberately separate from ``ReportFacts``.  The latter remains a
    compact current snapshot for the home screen; a timeline must not have to
    fetch an unbounded array and paginate it in a client.
    """

    meta: FactsMeta
    window: FactsWindow
    account_id: UUID | None
    items: list[KnownFutureEvent] = Field(default_factory=lambda: list[KnownFutureEvent]())
    next_cursor: str | None


class ReportFacts(APIModel):
    meta: FactsMeta
    window: FactsWindow
    cash: CashFacts
    credit: CreditFacts
    reimbursements: ReimbursementFacts
    completeness: CompletenessFacts
    future: KnownFutureTotals
    known_future_events: list[KnownFutureEvent] = Field(
        default_factory=lambda: list[KnownFutureEvent]()
    )
