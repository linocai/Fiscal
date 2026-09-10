from datetime import UTC, date, datetime
from uuid import uuid4

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.core.errors import APIError
from fiscal_api.db.models import Account, LedgerTransaction, Posting
from fiscal_api.services.report_exports import _yuan_number, _yuan_text
from fiscal_api.services.reporting import ReportingService


def _account(kind="debit", opening=0, as_of=None):
    return Account(
        id=uuid4(),
        name=kind,
        kind=kind,
        opening_balance_minor=opening,
        opening_balance_as_of_date=as_of,
        sort_order=0,
    )


def test_balance_basis_distinguishes_each_boundary_and_legacy_failure():
    credit = _account("credit", 10000, date(2026, 9, 10))
    accounts = {credit.id: credit}
    rows = ReportingService._period_account_rows(
        accounts, [], {}, {}, start=date(2026, 9, 1), end=date(2026, 9, 30)
    )
    row = rows[0]
    assert row.opening_balance_minor is None
    assert row.opening_balance_status == "unknown"
    assert row.closing_balance_minor == 10000
    assert row.closing_balance_status == "known"
    assert row.balance_unavailable_reason == "before_opening_as_of"
    assert ReportingService._balance_reason(credit, date(2026, 9, 10)) is None
    assert (
        ReportingService._balance_reason(_account("credit", 100), date(2026, 9, 10))
        == "opening_as_of_missing"
    )
    assert ReportingService._balance_reason(_account("credit"), date(1900, 1, 1)) is None
    # Only the balance contract changes; the service keeps known period metrics.
    service = ReportingService(AsyncSession())

    class Report:
        accounts = rows

    with pytest.raises(APIError) as caught:
        service._require_available_legacy_balances(Report())
    assert caught.value.code == "historical_balance_unavailable"
    service.balance_as_of_semantics = True
    service._require_available_legacy_balances(Report())


@pytest.mark.parametrize(
    "kind,legs,expected",
    [
        ("income", [("debit", 1200)], 1200),
        ("repayment", [("debit", -1200), ("credit", 1200)], -1200),
        ("credit_purchase", [("credit", -1200)], 0),
        ("installment_refund", [("debit", 1200)], 1200),
        ("reimbursement_receipt", [("debit", 1200)], 1200),
        ("transfer", [("debit", -1200), ("cash", 1200)], 0),
    ],
)
def test_drill_cash_is_only_effective_cash_legs(kind, legs, expected):
    accounts = [_account(kind) for kind, _ in legs]
    transaction = LedgerTransaction(
        id=uuid4(),
        kind=kind,
        title="fixture",
        source="manual",
        occurred_at=datetime(2026, 9, 10, tzinfo=UTC),
        postings=[
            Posting(
                account_id=account.id,
                amount_minor=amount,
                role="account" if i == 0 else "destination",
                position=i,
            )
            for i, (account, (_, amount)) in enumerate(zip(accounts, legs, strict=True))
        ],
    )
    kwargs = dict(categories={}, accounts={a.id: a for a in accounts}, merchant=None, spending=None)
    for build in (
        ReportingService._period_drill_down_item,
        ReportingService._period_drill_down_item_v2,
    ):
        assert build(transaction, **kwargs).external_cash_amount_minor == expected
        transaction.voided_at = datetime(2026, 9, 11, tzinfo=UTC)
        assert build(transaction, **kwargs).external_cash_amount_minor == 0
        transaction.voided_at = None
        assert (
            build(transaction, selected_account_id=uuid4(), **kwargs).external_cash_amount_minor
            == 0
        )


def test_exports_preserve_negative_and_unknown_values():
    assert _yuan_number(-1) == "-0.01"
    assert _yuan_text(-(2**63)).startswith("-¥92,233,720,368,547,758.08")
    assert _yuan_number(None) == ""
    assert _yuan_text(None) == "未知"


def test_complete_exports_keep_unknown_reasons_and_all_summary_metrics():
    import csv
    from io import StringIO

    from fiscal_api.api.p34_schemas import PeriodReport, ReportSummary
    from fiscal_api.services.report_exports import SUMMARY_LABELS, report_csv, report_pdf

    credit = _account("credit", 10000, date(2026, 9, 10))
    accounts = ReportingService._period_account_rows(
        {credit.id: credit}, [], {}, {}, start=date(2026, 8, 1), end=date(2026, 8, 31)
    )
    summary = {key: 0 for key in SUMMARY_LABELS}
    summary.update(
        credit_debt_at_period_end_minor=None,
        credit_debt_at_period_end_status="unknown",
        unknown_balance_account_ids=[credit.id],
        balance_unavailable_reason="historical_basis_unavailable",
    )
    report = PeriodReport(
        meta=ReportingService._period_report_meta(
            "month", "2026-08", date(2026, 8, 1), date(2026, 8, 31), data_revision=0
        ),
        summary=ReportSummary.model_validate(summary),
        accounts=accounts,
        categories=[],
        merchants=[],
        sources=[],
        completeness=dict(
            unresolved_import_count=0, failed_import_count=0, uncategorized_transaction_count=0
        ),
        drill_down_path="/fixture",
    )
    rows = list(csv.reader(StringIO(report_csv(report).decode("utf-8-sig"))))
    totals = [row for row in rows if row[0] == "汇总"]
    assert len(totals) == len(SUMMARY_LABELS)
    unknown = next(
        row for row in totals if row[1] == SUMMARY_LABELS["credit_debt_at_period_end_minor"]
    )
    assert unknown[3] == ""
    assert unknown[5] == "historical_basis_unavailable"
    assert any(
        row[3] == "" and row[5] == "before_opening_as_of" for row in rows if row[0] == "账户"
    )
    pdf = report_pdf(report)
    assert "未知".encode("utf-16-be").hex().upper().encode() in pdf
    assert "historical_basis_unavailable".encode("utf-16-be").hex().upper().encode() in pdf
