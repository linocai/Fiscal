import pytest
from fastapi.testclient import TestClient

from fiscal_api.api.p7_schemas import FactsWindow
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
    auth = {"Authorization": "Bearer fiscal_ak_v1_test_access_key_0123456789abcdef"}
    invalid_queries = (
        "/api/v1/reports/overview?month=2026-13",
        "/api/v1/reports/spending?date_from=not-a-date",
        "/api/v1/reports/cash-flow?forecast_days=0",
        "/api/v1/reports/cash-flow?forecast_days=91",
        "/api/v1/reports/facts?window_days=0",
        "/api/v1/reports/facts?window_days=91",
        "/api/v1/reports/future-events?window_days=7&limit=0",
        "/api/v1/reports/future-events?window_days=7&limit=101",
        "/api/v1/reports/facts/drill-down?scope=cash_accounts",
        "/api/v1/reports/facts/drill-down?scope=unknown",
        "/api/v1/reports/facts/drill-down?scope=cash_accounts&limit=0",
        "/api/v1/reports/facts/drill-down?scope=cash_accounts&limit=101",
        "/api/v1/reports/facts/drill-down?scope=cash_accounts&expected_data_revision=-1",
        "/api/v1/reports/drill-down?lens=unknown&date_from=2026-07-01&date_to=2026-07-31",
        "/api/v1/reports/drill-down?lens=spending&date_from=2026-07-01&date_to=2026-07-31&limit=0",
        "/api/v1/reports/drill-down?lens=cash_flow&date_from=2026-07-01&date_to=2026-07-31&limit=101",
    )

    for path in invalid_queries:
        response = client.get(path, headers=auth)
        assert response.status_code == 422, (path, response.text)
        assert response.json()["error"]["code"] == "validation_error"

    unsupported_window = client.get("/api/v1/reports/future-events?window_days=8", headers=auth)
    assert unsupported_window.status_code == 422
    assert unsupported_window.json()["error"]["code"] == "invalid_future_events_window"


def test_report_routes_require_access_key(unauthenticated_client: TestClient) -> None:
    paths = (
        "/api/v1/reports/overview",
        "/api/v1/reports/spending",
        "/api/v1/reports/cash-flow",
        "/api/v1/reports/facts",
        "/api/v1/reports/facts/drill-down?scope=cash_accounts",
        "/api/v1/reports/debt",
        "/api/v1/reports/drill-down?lens=spending&date_from=2026-07-01&date_to=2026-07-31",
    )

    for path in paths:
        response = unauthenticated_client.get(path)
        assert response.status_code == 401, (path, response.text)
        assert response.json()["error"]["code"] == "authentication_required"


def test_facts_uses_server_business_today_only(client: TestClient) -> None:
    operation = client.app.openapi()["paths"]["/api/v1/reports/facts"]["get"]
    assert [item["name"] for item in operation["parameters"]] == ["window_days"]


def test_future_events_contract_is_windowed_and_server_clocked(client: TestClient) -> None:
    operation = client.app.openapi()["paths"]["/api/v1/reports/future-events"]["get"]
    assert [item["name"] for item in operation["parameters"]] == [
        "window_days",
        "account_id",
        "cursor",
        "limit",
    ]


def test_future_events_cursor_rejects_impossible_typed_key() -> None:
    window = FactsWindow(date_from="2026-07-15", date_to="2026-08-13")
    valid = ReportingService._encode_future_events_cursor(
        window=window,
        account_id=None,
        data_revision=7,
        key=("2026-07-15", "outflow", "credit_cycle", "00000000-0000-0000-0000-000000000001"),
    )
    assert ReportingService._decode_future_events_cursor(valid, window=window, account_id=None) == (
        7,
        ("2026-07-15", "outflow", "credit_cycle", "00000000-0000-0000-0000-000000000001"),
    )

    for date_value, direction, source_type, source_id in (
        ("2026-07-14", "outflow", "credit_cycle", "00000000-0000-0000-0000-000000000001"),
        ("2026-07-15", "inflow", "credit_cycle", "00000000-0000-0000-0000-000000000001"),
        ("2026-07-15", "outflow", "reimbursement_party", "00000000-0000-0000-0000-000000000001"),
        ("2026-07-15", "outflow", "credit_cycle", "not-a-uuid"),
    ):
        invalid_cursor = ReportingService._encode_future_events_cursor(
            window=window,
            account_id=None,
            data_revision=7,
            key=(date_value, direction, source_type, source_id),
        )
        with pytest.raises(APIError) as invalid_cursor_error:
            ReportingService._decode_future_events_cursor(
                invalid_cursor, window=window, account_id=None
            )
        assert invalid_cursor_error.value.code == "invalid_future_events_cursor"
