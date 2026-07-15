import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.errors import APIError
from fiscal_api.services.common import INT64_MAX, INT64_MIN
from fiscal_api.services.reporting import ReportingService


def test_reporting_derived_amounts_reject_int64_overflow() -> None:
    with pytest.raises(APIError) as total:
        ReportingService._checked_sum([INT64_MAX, 1])
    assert total.value.code == "derived_amount_out_of_range"

    with pytest.raises(APIError) as magnitude:
        ReportingService._magnitude(INT64_MIN)
    assert magnitude.value.code == "derived_amount_out_of_range"


def test_report_query_contract_rejects_invalid_values(client: TestClient) -> None:
    auth = {"Authorization": "Bearer test-device-token"}
    invalid_queries = (
        "/api/v1/reports/overview?month=2026-13",
        "/api/v1/reports/spending?date_from=not-a-date",
        "/api/v1/reports/cash-flow?forecast_days=0",
        "/api/v1/reports/cash-flow?forecast_days=91",
        "/api/v1/reports/drill-down?lens=unknown&date_from=2026-07-01&date_to=2026-07-31",
        "/api/v1/reports/drill-down?lens=spending&date_from=2026-07-01&date_to=2026-07-31&limit=0",
        "/api/v1/reports/drill-down?lens=cash_flow&date_from=2026-07-01&date_to=2026-07-31&limit=101",
    )

    for path in invalid_queries:
        response = client.get(path, headers=auth)
        assert response.status_code == 422, (path, response.text)
        assert response.json()["error"]["code"] == "validation_error"


def test_report_routes_require_device_authentication(client: TestClient) -> None:
    paths = (
        "/api/v1/reports/overview",
        "/api/v1/reports/spending",
        "/api/v1/reports/cash-flow",
        "/api/v1/reports/debt",
        "/api/v1/reports/drill-down?lens=spending&date_from=2026-07-01&date_to=2026-07-31",
    )

    for path in paths:
        response = client.get(path)
        assert response.status_code == 401, (path, response.text)
        assert response.json()["error"]["code"] == "authentication_required"
