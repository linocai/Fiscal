from datetime import date
from os import environ
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from fiscal_api.core.config import Settings
from fiscal_api.main import create_app
from fiscal_api.services.reporting import ReportingService

TEST_DATABASE_URL = environ.get("FISCAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(TEST_DATABASE_URL is None, reason="requires PostgreSQL")


def test_monthly_report_judges_in_progress_cycles_as_of_today(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert TEST_DATABASE_URL is not None

    async def ready() -> None:
        return None

    app = create_app(
        settings=Settings(environment="test", database_url=TEST_DATABASE_URL),
        readiness_check=ready,
    )
    auth = {
        "Authorization": "Bearer build52-token",
        "X-Fiscal-Report-Balance-Semantics": "as-of-v1",
    }
    suffix = uuid4().hex[:8]
    with TestClient(app) as client:
        credit = client.post(
            "/api/v1/accounts",
            headers=auth,
            json={
                "name": f"B52 车贷 {suffix}",
                "kind": "credit",
                "opening_balance_minor": 0,
                "credit_limit_minor": 100000,
                "statement_day": 20,
                "due_day": 22,
            },
        )
        assert credit.status_code == 201, credit.text
        purchase = client.post(
            "/api/v1/transactions",
            headers={**auth, "Idempotency-Key": str(uuid4())},
            json={
                "kind": "credit_purchase",
                "amount_minor": 3000,
                "occurred_at": "2025-03-05T12:00:00+08:00",
                "title": f"B52 账期消费 {suffix}",
                "account_id": credit.json()["id"],
            },
        )
        assert purchase.status_code == 201, purchase.text
        cycle_id = purchase.json()["credit_cycle_id"]

        def cycle_on(today: date) -> dict[str, object]:
            monkeypatch.setattr(ReportingService, "_today", staticmethod(lambda: today))
            report = client.get("/api/v1/reports/v2/monthly/2025-03", headers=auth)
            assert report.status_code == 200, report.text
            return next(row for row in report.json()["debt_cycles"] if row["cycle_id"] == cycle_id)

        before_due = cycle_on(date(2025, 3, 14))
        assert before_due["due_date"] == "2025-03-22"
        assert before_due["status"] == "open"
        assert before_due["is_overdue"] is False

        past_due_in_month = cycle_on(date(2025, 3, 28))
        assert past_due_in_month["is_overdue"] is True

        # A finished month keeps its period-end status.
        historical = cycle_on(date(2025, 6, 1))
        assert historical["status"] == "overdue"
        assert historical["is_overdue"] is True
