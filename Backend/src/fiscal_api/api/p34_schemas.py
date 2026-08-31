from __future__ import annotations

from datetime import date, datetime
from enum import StrEnum
from typing import Literal
from uuid import UUID

from pydantic import Field

from fiscal_api.api.p3_schemas import APIModel
from fiscal_api.api.p7_schemas import DebtCycleRow, DebtInstallmentGroup, KnownFutureEvent
from fiscal_api.db.models import AccountKind, TransactionKind, TransactionSource

MIN_REPORT_YEAR = 2
MAX_REPORT_YEAR = 9998
SUPPORTED_REPORT_YEAR_RANGE = f"{MIN_REPORT_YEAR:04d}-{MAX_REPORT_YEAR:04d}"


class ReportPeriodKind(StrEnum):
    MONTH = "month"
    YEAR = "year"


class ReportDrillDownDimension(StrEnum):
    LEDGER = "ledger"


class ReportMeta(APIModel):
    """Identity for one deterministic, server-generated report read."""

    period_kind: ReportPeriodKind
    period: str
    date_from: date
    date_to: date
    timezone: Literal["Asia/Shanghai"] = "Asia/Shanghai"
    currency: Literal["CNY"] = "CNY"
    as_of: datetime
    data_revision: int = Field(ge=0)
    report_schema_version: Literal["1"] = "1"
    generated_at: datetime


class ReportSummary(APIModel):
    income_minor: int
    gross_consumption_minor: int
    merchant_refund_minor: int
    net_consumption_minor: int
    expected_reimbursement_minor: int
    received_reimbursement_minor: int
    personal_expected_minor: int
    personal_realized_minor: int
    net_income_expense_minor: int
    cash_inflow_minor: int
    cash_outflow_minor: int
    cash_net_minor: int
    internal_transfer_inflow_minor: int
    internal_transfer_outflow_minor: int
    credit_debt_at_period_end_minor: int
    reimbursement_outstanding_at_period_end_minor: int


class ReportAccountBalance(APIModel):
    account_id: UUID
    account_name: str
    account_kind: AccountKind
    opening_balance_minor: int
    closing_balance_minor: int
    period_inflow_minor: int
    period_outflow_minor: int
    internal_transfer_inflow_minor: int
    internal_transfer_outflow_minor: int


class ReportCategoryTotal(APIModel):
    category_id: UUID | None
    category_name: str
    gross_consumption_minor: int
    merchant_refund_minor: int
    net_consumption_minor: int
    transaction_count: int = Field(ge=0)


class ReportMerchantTotal(APIModel):
    merchant_id: UUID | None
    merchant_name: str
    net_consumption_minor: int
    transaction_count: int = Field(ge=0)


class ReportSourceTotal(APIModel):
    source: TransactionSource
    transaction_count: int = Field(ge=0)


class ReportCompleteness(APIModel):
    unresolved_import_count: int = Field(ge=0)
    failed_import_count: int = Field(ge=0)
    uncategorized_transaction_count: int = Field(ge=0)
    open_reconciliation_difference_count: int = Field(ge=0)


class PeriodReport(APIModel):
    meta: ReportMeta
    summary: ReportSummary
    accounts: list[ReportAccountBalance]
    categories: list[ReportCategoryTotal]
    merchants: list[ReportMerchantTotal]
    sources: list[ReportSourceTotal]
    completeness: ReportCompleteness
    drill_down_path: str


class PeriodReportDrillDownItem(APIModel):
    transaction_id: UUID
    occurred_at: datetime
    business_date: date
    kind: TransactionKind
    source: TransactionSource
    category_id: UUID | None
    category_name: str | None
    merchant_id: UUID | None
    merchant_name: str | None
    # This is an accounting amount, not a client-calculated display amount.
    external_cash_amount_minor: int
    gross_consumption_minor: int
    merchant_refund_minor: int
    net_consumption_minor: int


class PeriodReportDrillDownPage(APIModel):
    meta: ReportMeta
    dimension: Literal[ReportDrillDownDimension.LEDGER] = ReportDrillDownDimension.LEDGER
    category_id: UUID | None
    account_id: UUID | None
    merchant_id: UUID | None
    source: TransactionSource | None
    items: list[PeriodReportDrillDownItem]
    next_cursor: str | None


class ReportMetaV2(APIModel):
    period_kind: ReportPeriodKind
    period: str
    date_from: date
    date_to: date
    timezone: Literal["Asia/Shanghai"] = "Asia/Shanghai"
    currency: Literal["CNY"] = "CNY"
    as_of: datetime
    data_revision: int = Field(ge=0)
    report_schema_version: Literal["2"] = "2"
    generated_at: datetime


class ReportCategoryTotalV2(APIModel):
    category_id: UUID | None
    category_name: str
    gross_consumption_minor: int
    merchant_refund_minor: int
    net_consumption_minor: int
    expected_reimbursement_minor: int
    received_reimbursement_minor: int
    personal_expected_minor: int
    personal_realized_minor: int
    transaction_count: int = Field(ge=0)


class ReportDailyPointV2(APIModel):
    date: date
    gross_consumption_minor: int
    merchant_refund_minor: int
    net_consumption_minor: int
    expected_reimbursement_minor: int
    received_reimbursement_minor: int
    personal_expected_minor: int
    personal_realized_minor: int


class PeriodReportV2(APIModel):
    meta: ReportMetaV2
    summary: ReportSummary
    accounts: list[ReportAccountBalance]
    categories: list[ReportCategoryTotalV2]
    merchants: list[ReportMerchantTotal]
    sources: list[ReportSourceTotal]
    completeness: ReportCompleteness
    daily: list[ReportDailyPointV2]
    known_future_events: list[KnownFutureEvent]
    debt_cycles: list[DebtCycleRow]
    installments: list[DebtInstallmentGroup]
    drill_down_path: str


class PeriodReportDrillDownItemV2(APIModel):
    transaction_id: UUID
    occurred_at: datetime
    business_date: date
    title: str
    kind: TransactionKind
    source: TransactionSource
    category_id: UUID | None
    category_name: str | None
    merchant_id: UUID | None
    merchant_name: str | None
    account_id: UUID | None
    account_name: str | None
    destination_account_id: UUID | None
    destination_account_name: str | None
    external_cash_amount_minor: int
    gross_consumption_minor: int
    merchant_refund_minor: int
    net_consumption_minor: int
    expected_reimbursement_minor: int
    received_reimbursement_minor: int
    personal_expected_minor: int
    personal_realized_minor: int
    status: Literal["active", "voided"]
    voided_at: datetime | None
    account_archived: bool
    category_archived: bool


class PeriodReportDrillDownPageV2(APIModel):
    meta: ReportMetaV2
    dimension: Literal[ReportDrillDownDimension.LEDGER] = ReportDrillDownDimension.LEDGER
    category_id: UUID | None
    account_id: UUID | None
    merchant_id: UUID | None
    source: TransactionSource | None
    items: list[PeriodReportDrillDownItemV2]
    next_cursor: str | None
