from datetime import date
from decimal import Decimal
from uuid import uuid4

import pytest

from fiscal_api.legacy_migration.cash_flow_recovery import parse_rows, select_recoverable


def audited_rows() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for month in range(7, 13):
        rows.append(
            {
                "id": uuid4(),
                "title": "工资",
                "direction": "inflow",
                "cash_flow_type": "salary",
                "amount": Decimal("5000.00"),
                "expected_date": date(2026, month, 21),
                "status": "expected",
                "account_name": "农业4873",
                "category_name": "工资",
                "recurrence_rule": "FREQ=MONTHLY;UNTIL=2026-12-21",
                "note": None,
            }
        )
    rows.append(
        {
            "id": uuid4(),
            "title": "9月房租",
            "direction": "inflow",
            "cash_flow_type": "rent_income",
            "amount": Decimal("6300.00"),
            "expected_date": date(2026, 9, 30),
            "status": "expected",
            "account_name": "工商3495",
            "category_name": None,
            "recurrence_rule": None,
            "note": None,
        }
    )
    for index in range(17):
        rows.append(
            {
                "id": uuid4(),
                "title": f"旧信用还款 {index}",
                "direction": "transfer",
                "cash_flow_type": "credit_repayment",
                "amount": Decimal("100.00"),
                "expected_date": date(2026, 8, 1),
                "status": "confirmed",
                "account_name": "旧信用账户",
                "category_name": None,
                "recurrence_rule": None,
                "note": None,
            }
        )
    return rows


def test_recovery_selects_only_the_audited_seven_manual_plans() -> None:
    salaries, rent, repayments = select_recoverable(parse_rows(audited_rows()))
    assert len(salaries) == 6
    assert rent.amount_minor == 630_000
    assert len(repayments) == 17
    assert sum(item.amount_minor for item in salaries) + rent.amount_minor == 3_630_000


def test_recovery_fails_closed_when_an_audited_value_changes() -> None:
    rows = audited_rows()
    rows[0]["amount"] = Decimal("5000.01")
    with pytest.raises(RuntimeError, match="salary series differs"):
        select_recoverable(parse_rows(rows))
