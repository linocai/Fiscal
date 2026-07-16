from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from enum import StrEnum

from fiscal_api.services.common import INT64_MAX, INT64_MIN


class ReconciliationStatus(StrEnum):
    MATCH = "match"
    MISMATCH = "mismatch"
    MISSING_EXPECTED = "missing_expected"
    MISSING_ACTUAL = "missing_actual"


@dataclass(frozen=True)
class Aggregate:
    count: int
    amount_minor: int


@dataclass(frozen=True)
class ReimbursementSummary:
    claim_count: int
    expected_minor: int
    received_minor: int
    outstanding_minor: int


@dataclass(frozen=True)
class MonthlySummary:
    income_minor: int
    spending_minor: int
    cash_inflow_minor: int
    cash_outflow_minor: int
    reimbursement_received_minor: int


@dataclass(frozen=True)
class ReconciliationCheck:
    area: str
    entity: str
    metric: str
    expected: int | None
    actual: int | None
    difference: int | None
    unit: str
    status: ReconciliationStatus
    explanation: str


@dataclass(frozen=True)
class ReconciliationReport:
    checks: tuple[ReconciliationCheck, ...]

    @property
    def passed(self) -> bool:
        return all(item.status is ReconciliationStatus.MATCH for item in self.checks)

    @property
    def mismatch_count(self) -> int:
        return sum(item.status is not ReconciliationStatus.MATCH for item in self.checks)


def reconcile_account_balances(
    expected: Mapping[str, int], actual: Mapping[str, int]
) -> ReconciliationReport:
    return _reconcile_scalar_map("account", "balance", "fen", expected, actual)


def reconcile_credit_liabilities(
    expected: Mapping[str, int], actual: Mapping[str, int]
) -> ReconciliationReport:
    return _reconcile_scalar_map("credit", "liability", "fen", expected, actual)


def reconcile_transaction_aggregates(
    expected: Mapping[str, Aggregate], actual: Mapping[str, Aggregate]
) -> ReconciliationReport:
    checks: list[ReconciliationCheck] = []
    for entity in sorted(expected.keys() | actual.keys()):
        expected_value = expected.get(entity)
        actual_value = actual.get(entity)
        checks.extend(
            _compare_object(
                area="transaction",
                entity=entity,
                expected=expected_value,
                actual=actual_value,
                metrics=(
                    ("count", "rows"),
                    ("amount_minor", "fen"),
                ),
            )
        )
    return ReconciliationReport(tuple(checks))


def reconcile_reimbursements(
    expected: ReimbursementSummary, actual: ReimbursementSummary
) -> ReconciliationReport:
    return ReconciliationReport(
        tuple(
            _compare_object(
                area="reimbursement",
                entity="all",
                expected=expected,
                actual=actual,
                metrics=(
                    ("claim_count", "rows"),
                    ("expected_minor", "fen"),
                    ("received_minor", "fen"),
                    ("outstanding_minor", "fen"),
                ),
            )
        )
    )


def reconcile_monthly_reports(
    expected: Mapping[str, MonthlySummary], actual: Mapping[str, MonthlySummary]
) -> ReconciliationReport:
    checks: list[ReconciliationCheck] = []
    for month in sorted(expected.keys() | actual.keys()):
        checks.extend(
            _compare_object(
                area="monthly_report",
                entity=month,
                expected=expected.get(month),
                actual=actual.get(month),
                metrics=(
                    ("income_minor", "fen"),
                    ("spending_minor", "fen"),
                    ("cash_inflow_minor", "fen"),
                    ("cash_outflow_minor", "fen"),
                    ("reimbursement_received_minor", "fen"),
                ),
            )
        )
    return ReconciliationReport(tuple(checks))


def combine_reports(*reports: ReconciliationReport) -> ReconciliationReport:
    return ReconciliationReport(tuple(check for report in reports for check in report.checks))


def _reconcile_scalar_map(
    area: str,
    metric: str,
    unit: str,
    expected: Mapping[str, int],
    actual: Mapping[str, int],
) -> ReconciliationReport:
    checks = [
        _compare_metric(
            area=area,
            entity=entity,
            metric=metric,
            expected=expected.get(entity),
            actual=actual.get(entity),
            unit=unit,
            expected_present=entity in expected,
            actual_present=entity in actual,
        )
        for entity in sorted(expected.keys() | actual.keys())
    ]
    return ReconciliationReport(tuple(checks))


def _compare_object(
    *,
    area: str,
    entity: str,
    expected: object | None,
    actual: object | None,
    metrics: Sequence[tuple[str, str]],
) -> list[ReconciliationCheck]:
    return [
        _compare_metric(
            area=area,
            entity=entity,
            metric=metric,
            expected=getattr(expected, metric) if expected is not None else None,
            actual=getattr(actual, metric) if actual is not None else None,
            unit=unit,
            expected_present=expected is not None,
            actual_present=actual is not None,
        )
        for metric, unit in metrics
    ]


def _compare_metric(
    *,
    area: str,
    entity: str,
    metric: str,
    expected: int | None,
    actual: int | None,
    unit: str,
    expected_present: bool,
    actual_present: bool,
) -> ReconciliationCheck:
    if not expected_present:
        return ReconciliationCheck(
            area=area,
            entity=entity,
            metric=metric,
            expected=None,
            actual=actual,
            difference=None,
            unit=unit,
            status=ReconciliationStatus.MISSING_EXPECTED,
            explanation=f"{entity} exists only in Fiscal output",
        )
    if not actual_present:
        return ReconciliationCheck(
            area=area,
            entity=entity,
            metric=metric,
            expected=expected,
            actual=None,
            difference=None,
            unit=unit,
            status=ReconciliationStatus.MISSING_ACTUAL,
            explanation=f"{entity} is expected but missing from Fiscal output",
        )
    if expected is None or actual is None:
        raise ValueError("present reconciliation metrics must be integers")
    _require_int64(expected, label=f"expected {area}.{metric}")
    _require_int64(actual, label=f"actual {area}.{metric}")
    difference = actual - expected
    _require_int64(difference, label=f"difference {area}.{metric}")
    if difference == 0:
        status = ReconciliationStatus.MATCH
        explanation = f"{metric} matches exactly"
    else:
        status = ReconciliationStatus.MISMATCH
        explanation = f"{metric} differs by {difference} {unit} (actual - expected)"
    return ReconciliationCheck(
        area=area,
        entity=entity,
        metric=metric,
        expected=expected,
        actual=actual,
        difference=difference,
        unit=unit,
        status=status,
        explanation=explanation,
    )


def _require_int64(value: int, *, label: str) -> None:
    if isinstance(value, bool):
        raise TypeError(f"{label} must be an integer")
    if value < INT64_MIN or value > INT64_MAX:
        raise OverflowError(f"{label} is outside the signed 64-bit integer range")
