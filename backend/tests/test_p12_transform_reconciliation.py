from datetime import date, datetime
from decimal import Decimal

import pytest

from fiscal_api.core.time import BUSINESS_TIMEZONE, UTC
from fiscal_api.legacy_migration.reconciliation import (
    Aggregate,
    MonthlySummary,
    ReconciliationStatus,
    ReimbursementSummary,
    combine_reports,
    reconcile_account_balances,
    reconcile_credit_liabilities,
    reconcile_monthly_reports,
    reconcile_reimbursements,
    reconcile_transaction_aggregates,
)
from fiscal_api.legacy_migration.transform import (
    LegacyTransformError,
    inferred_opening_balance_minor,
    legacy_date_to_occurred_at,
    mapped_category,
    normalize_reimbursement_party,
    yuan_to_minor,
)
from fiscal_api.services.common import INT64_MAX


def test_yuan_to_minor_is_exact_and_never_rounds() -> None:
    assert yuan_to_minor(Decimal("26249.49")) == 2_624_949
    assert yuan_to_minor(Decimal("-0.01")) == -1
    assert yuan_to_minor(Decimal("0.000")) == 0

    with pytest.raises(LegacyTransformError) as fractional:
        yuan_to_minor(Decimal("1.001"), field="legacy amount")
    assert fractional.value.code == "money_has_fractional_fen"

    with pytest.raises(LegacyTransformError) as non_finite:
        yuan_to_minor(Decimal("NaN"))
    assert non_finite.value.code == "invalid_money"

    with pytest.raises(LegacyTransformError) as overflow:
        yuan_to_minor(Decimal(INT64_MAX + 1) / 100)
    assert overflow.value.code == "money_out_of_range"


def test_legacy_date_maps_to_shanghai_noon_and_utc_storage() -> None:
    occurred_at = legacy_date_to_occurred_at(date(2026, 5, 16))

    assert occurred_at == datetime(2026, 5, 16, 4, tzinfo=UTC)
    assert occurred_at.astimezone(BUSINESS_TIMEZONE).hour == 12
    assert occurred_at.astimezone(BUSINESS_TIMEZONE).date() == date(2026, 5, 16)

    with pytest.raises(LegacyTransformError) as error:
        legacy_date_to_occurred_at(datetime(2026, 5, 16, 12))
    assert error.value.code == "legacy_date_expected"


def test_approved_opening_party_and_category_transforms() -> None:
    assert (
        inferred_opening_balance_minor(current_minor=281_512, movement_net_minor=-2_343_437)
        == 2_624_949
    )
    assert normalize_reimbursement_party(" company ") == "公司"
    assert normalize_reimbursement_party("111") == "公司"
    assert normalize_reimbursement_party("个人甲") == "个人甲"
    assert mapped_category("expense", "平账") == "平账"
    assert mapped_category("expense", "理财") == "理财"
    assert mapped_category("income", "报销") == "历史报销"


def test_account_and_credit_reconciliation_explains_differences_and_missing_rows() -> None:
    accounts = reconcile_account_balances(
        {"农业4873": 0, "工商3495": 281_512},
        {"农业4873": 0, "工商3495": 281_500, "杭联0519": 2_000_000},
    )
    credit = reconcile_credit_liabilities(
        {"白条": 409_134, "花呗": 109_047},
        {"白条": 409_134},
    )

    assert not accounts.passed
    assert accounts.mismatch_count == 2
    balance_mismatch = next(item for item in accounts.checks if item.entity == "工商3495")
    extra_account = next(item for item in accounts.checks if item.entity == "杭联0519")
    assert balance_mismatch.status is ReconciliationStatus.MISMATCH
    assert balance_mismatch.difference == -12
    assert "actual - expected" in balance_mismatch.explanation
    assert extra_account.status is ReconciliationStatus.MISSING_EXPECTED
    assert credit.checks[1].status is ReconciliationStatus.MISSING_ACTUAL


def test_transaction_reconciliation_compares_count_and_amount_by_kind() -> None:
    report = reconcile_transaction_aggregates(
        {
            "expense": Aggregate(count=10, amount_minor=123_400),
            "transfer": Aggregate(count=4, amount_minor=2_778_117),
        },
        {
            "expense": Aggregate(count=10, amount_minor=123_400),
            "transfer": Aggregate(count=3, amount_minor=2_778_117),
        },
    )

    assert len(report.checks) == 4
    assert report.mismatch_count == 1
    count = next(
        item for item in report.checks if item.entity == "transfer" and item.metric == "count"
    )
    assert count.difference == -1
    assert count.unit == "rows"


def test_reimbursement_and_monthly_report_reconciliation_can_be_combined() -> None:
    reimbursements = reconcile_reimbursements(
        ReimbursementSummary(
            claim_count=6,
            expected_minor=648_737,
            received_minor=648_737,
            outstanding_minor=0,
        ),
        ReimbursementSummary(
            claim_count=6,
            expected_minor=648_737,
            received_minor=648_737,
            outstanding_minor=0,
        ),
    )
    monthly = reconcile_monthly_reports(
        {
            "2026-06": MonthlySummary(
                income_minor=1_577_537,
                spending_minor=2_000_000,
                cash_inflow_minor=2_226_274,
                cash_outflow_minor=2_500_000,
                reimbursement_received_minor=648_737,
            )
        },
        {
            "2026-06": MonthlySummary(
                income_minor=1_577_537,
                spending_minor=2_000_000,
                cash_inflow_minor=2_226_274,
                cash_outflow_minor=2_500_000,
                reimbursement_received_minor=648_737,
            )
        },
    )

    combined = combine_reports(reimbursements, monthly)
    assert reimbursements.passed
    assert monthly.passed
    assert combined.passed
    assert len(combined.checks) == 9


def test_reconciliation_rejects_difference_overflow() -> None:
    with pytest.raises(OverflowError, match=r"difference account\.balance"):
        reconcile_account_balances({"极值账户": -1}, {"极值账户": INT64_MAX})
