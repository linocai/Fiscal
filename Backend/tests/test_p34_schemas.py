from datetime import UTC, date, datetime
from uuid import uuid4

from fastapi.testclient import TestClient

from fiscal_api.api.p34_schemas import (
    SUPPORTED_REPORT_YEAR_RANGE,
    PeriodReport,
    ReportCategoryTotal,
    ReportCompleteness,
    ReportMeta,
    ReportPeriodKind,
    ReportSummary,
)
from fiscal_api.services.report_exports import report_pdf


def test_p34_report_paths_validate_periods_and_require_auth(
    client: TestClient, unauthenticated_client: TestClient
) -> None:
    for path in (
        "/api/v1/reports/monthly/2024-02",
        "/api/v1/reports/yearly/2024",
        "/api/v1/reports/monthly/2024-02/export.csv",
        "/api/v1/reports/monthly/2024-02/export.pdf",
        "/api/v1/reports/period-drill-down?period_kind=month&period=2024-02"
        "&expected_data_revision=0",
    ):
        response = unauthenticated_client.get(path)
        assert response.status_code == 401, response.text

    assert client.get("/api/v1/reports/monthly/2024-13").status_code == 422
    assert client.get("/api/v1/reports/yearly/year").status_code == 422
    assert (
        client.get(
            "/api/v1/reports/period-drill-down?period_kind=year&period=2024"
            "&expected_data_revision=0&cursor=not-a-cursor"
        ).status_code
        == 422
    )


def test_p34_openapi_distinguishes_report_exports_from_ledger_export(client: TestClient) -> None:
    paths = client.get("/openapi.json").json()["paths"]
    assert "/api/v1/transactions/export.csv" in paths
    assert "/api/v1/reports/monthly/{period}/export.csv" in paths
    assert "/api/v1/reports/monthly/{period}/export.pdf" in paths
    assert "/api/v1/reports/period-drill-down" in paths
    monthly_parameter = paths["/api/v1/reports/monthly/{period}"]["get"]["parameters"][0]
    assert (
        monthly_parameter["description"] == f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}"
    )
    drill_parameters = {
        parameter["name"]: parameter
        for parameter in paths["/api/v1/reports/period-drill-down"]["get"]["parameters"]
    }
    assert drill_parameters["period"]["description"] == (
        f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}; "
        "month uses YYYY-MM; year uses YYYY."
    )
    assert drill_parameters["period_kind"]["description"] == (
        "Selects period format: month uses YYYY-MM; year uses YYYY."
    )
    for path in (
        "/api/v1/reports/monthly/{period}/export.csv",
        "/api/v1/reports/monthly/{period}/export.pdf",
        "/api/v1/reports/yearly/{period}/export.csv",
        "/api/v1/reports/yearly/{period}/export.pdf",
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


def test_p34_pdf_paginates_every_canonical_category_row() -> None:
    now = datetime(2026, 8, 14, tzinfo=UTC)
    report = PeriodReport(
        meta=ReportMeta(
            period_kind=ReportPeriodKind.MONTH,
            period="2026-08",
            date_from=date(2026, 8, 1),
            date_to=date(2026, 8, 31),
            as_of=now,
            data_revision=9,
            generated_at=now,
        ),
        summary=ReportSummary(
            income_minor=0,
            gross_consumption_minor=121,
            merchant_refund_minor=0,
            net_consumption_minor=121,
            expected_reimbursement_minor=0,
            received_reimbursement_minor=0,
            personal_expected_minor=121,
            personal_realized_minor=121,
            net_income_expense_minor=-121,
            cash_inflow_minor=0,
            cash_outflow_minor=121,
            cash_net_minor=-121,
            internal_transfer_inflow_minor=0,
            internal_transfer_outflow_minor=0,
            credit_debt_at_period_end_minor=0,
            reimbursement_outstanding_at_period_end_minor=0,
        ),
        accounts=[],
        categories=[
            ReportCategoryTotal(
                category_id=uuid4(),
                category_name=f"P34 category {index:03d}",
                gross_consumption_minor=1,
                merchant_refund_minor=0,
                net_consumption_minor=1,
                transaction_count=1,
            )
            for index in range(121)
        ],
        merchants=[],
        sources=[],
        completeness=ReportCompleteness(
            unresolved_import_count=0,
            failed_import_count=0,
            uncategorized_transaction_count=0,
            open_reconciliation_difference_count=0,
        ),
        drill_down_path="/api/v1/reports/period-drill-down",
    )
    pdf = report_pdf(report)
    assert pdf.count(b"/Type /Page /Parent") >= 4
    assert "P34 category 000".encode("utf-16-be").hex().upper().encode() in pdf
    assert "P34 category 120".encode("utf-16-be").hex().upper().encode() in pdf
    assert "net_consumption_minor: 121".encode("utf-16-be").hex().upper().encode() in pdf
