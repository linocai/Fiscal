import json
from datetime import UTC, date, datetime

from fastapi.testclient import TestClient

from fiscal_api.api.p7_schemas import DebtInstallmentGroup
from fiscal_api.api.p34_schemas import (
    SUPPORTED_REPORT_YEAR_RANGE,
    PeriodReportV2,
    ReportCompleteness,
    ReportMetaV2,
    ReportPeriodKind,
    ReportSummary,
)
from fiscal_api.services.report_exports import report_csv


def test_p34_report_paths_validate_periods_and_require_auth(
    client: TestClient, unauthenticated_client: TestClient
) -> None:
    for path in (
        "/api/v1/reports/v2/monthly/2024-02",
        "/api/v1/reports/v2/yearly/2024",
        "/api/v1/reports/v2/monthly/2024-02/export.csv",
        "/api/v1/reports/v2/period-drill-down?period_kind=month&period=2024-02"
        "&expected_data_revision=0",
    ):
        response = unauthenticated_client.get(path)
        assert response.status_code == 401, response.text

    assert client.get("/api/v1/reports/v2/monthly/2024-13").status_code == 422
    assert client.get("/api/v1/reports/v2/yearly/year").status_code == 422
    assert (
        client.get(
            "/api/v1/reports/v2/period-drill-down?period_kind=year&period=2024"
            "&expected_data_revision=0&cursor=not-a-cursor"
        ).status_code
        == 422
    )


def test_p34_openapi_distinguishes_report_exports_from_ledger_export(client: TestClient) -> None:
    paths = client.get("/openapi.json").json()["paths"]
    assert "/api/v1/transactions/export.csv" in paths
    assert "/api/v1/reports/v2/monthly/{period}/export.csv" in paths
    assert "/api/v1/reports/v2/monthly/{period}/export.pdf" not in paths
    assert "/api/v1/reports/v2/period-drill-down" in paths
    monthly_parameter = paths["/api/v1/reports/v2/monthly/{period}"]["get"]["parameters"][0]
    assert (
        monthly_parameter["description"] == f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}"
    )
    drill_parameters = {
        parameter["name"]: parameter
        for parameter in paths["/api/v1/reports/v2/period-drill-down"]["get"]["parameters"]
    }
    assert drill_parameters["period"]["description"] == ("month uses YYYY-MM; year uses YYYY")
    assert drill_parameters["period_kind"]["description"] == (
        "Selects period format: month uses YYYY-MM; year uses YYYY."
    )
    for path in (
        "/api/v1/reports/v2/monthly/{period}/export.csv",
        "/api/v1/reports/v2/yearly/{period}/export.csv",
    ):
        parameters = {
            parameter["name"]: parameter for parameter in paths[path]["get"]["parameters"]
        }
        expected = parameters["expected_data_revision"]
        assert expected["required"] is False
        assert expected["schema"]["anyOf"] == [
            {"type": "integer", "minimum": 0},
            {"type": "null"},
        ]


def test_p34_openapi_hides_retired_reconciliation_contract(client: TestClient) -> None:
    document = client.get("/openapi.json").json()
    public_contract = json.dumps(document, sort_keys=True)
    assert "open_reconciliation_difference_count" not in public_contract
    assert "last_reconciled_at" not in public_contract
    assert "reconciliation" not in public_contract


def test_p34_v2_exports_include_every_installment_aggregate() -> None:
    now = datetime(2026, 8, 30, tzinfo=UTC)
    report = PeriodReportV2(
        meta=ReportMetaV2(
            period_kind=ReportPeriodKind.MONTH,
            period="2026-08",
            date_from=date(2026, 8, 1),
            date_to=date(2026, 8, 31),
            as_of=now,
            data_revision=33,
            generated_at=now,
        ),
        summary=ReportSummary(
            income_minor=0,
            gross_consumption_minor=0,
            merchant_refund_minor=0,
            net_consumption_minor=0,
            expected_reimbursement_minor=0,
            received_reimbursement_minor=0,
            personal_expected_minor=0,
            personal_realized_minor=0,
            net_income_expense_minor=0,
            cash_inflow_minor=0,
            cash_outflow_minor=0,
            cash_net_minor=0,
            internal_transfer_inflow_minor=0,
            internal_transfer_outflow_minor=0,
            credit_debt_at_period_end_minor=0,
            reimbursement_outstanding_at_period_end_minor=0,
        ),
        accounts=[],
        categories=[],
        merchants=[],
        sources=[],
        completeness=ReportCompleteness(
            uncategorized_transaction_count=0,
        ),
        daily=[],
        known_future_events=[],
        debt_cycles=[],
        installments=[
            DebtInstallmentGroup(
                month="2026-09",
                principal_scheduled_gross_minor=120_000,
                fee_scheduled_gross_minor=9_600,
                total_scheduled_gross_minor=129_600,
                period_count=4,
            )
        ],
        drill_down_path="/api/v1/reports/period-drill-down",
    )

    csv_text = report_csv(report).decode("utf-8-sig")
    assert "分期计划,计划本金,2026-09,1200.00,," in csv_text
    assert "分期计划,计划费用,2026-09,96.00,," in csv_text
    assert "分期计划,计划合计,2026-09,1296.00,," in csv_text
    assert "分期计划,期数,2026-09,,4," in csv_text
    for internal in ("data_revision", "report_schema_version", "stable_id", "value_minor"):
        assert internal not in csv_text
