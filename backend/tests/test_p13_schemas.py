from datetime import date
from uuid import uuid4

import pytest
from pydantic import ValidationError

from fiscal_api.api.p13_schemas import CashFlowDraft
from fiscal_api.db.models import CashFlowDirection, CashFlowRecurrence


def test_monthly_cash_flow_requires_end_date() -> None:
    with pytest.raises(ValidationError, match="requires an end date"):
        CashFlowDraft(
            title="工资",
            direction=CashFlowDirection.INFLOW,
            planned_amount_minor=500_000,
            expected_date=date(2026, 7, 21),
            account_id=uuid4(),
            recurrence=CashFlowRecurrence.MONTHLY,
        )


def test_transfer_requires_distinct_accounts_and_no_category() -> None:
    account_id = uuid4()
    with pytest.raises(ValidationError, match="must differ"):
        CashFlowDraft(
            title="调拨",
            direction=CashFlowDirection.TRANSFER,
            planned_amount_minor=100,
            expected_date=date(2026, 7, 21),
            account_id=account_id,
            destination_account_id=account_id,
        )


def test_valid_monthly_cash_flow() -> None:
    draft = CashFlowDraft(
        title=" 工资 ",
        direction=CashFlowDirection.INFLOW,
        planned_amount_minor=500_000,
        expected_date=date(2026, 7, 21),
        account_id=uuid4(),
        recurrence=CashFlowRecurrence.MONTHLY,
        recurrence_end_date=date(2026, 12, 21),
    )
    assert draft.title == "工资"
