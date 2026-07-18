from datetime import date

import pytest
from pydantic import ValidationError

from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p5_schemas import InstallmentPurchaseCreate
from fiscal_api.db.models import CreditCycleMode, TransactionKind
from fiscal_api.services.credit import credit_schedule


def test_previous_calendar_month_schedule_including_year_boundary() -> None:
    july = credit_schedule(date(2026, 7, 1), 1, 8, CreditCycleMode.PREVIOUS_CALENDAR_MONTH)
    assert (july.period_start, july.period_end, july.statement_date, july.due_date) == (
        date(2026, 7, 1),
        date(2026, 7, 31),
        date(2026, 8, 1),
        date(2026, 8, 8),
    )
    december = credit_schedule(date(2026, 12, 31), 1, 8, CreditCycleMode.PREVIOUS_CALENDAR_MONTH)
    assert (december.statement_date, december.due_date) == (
        date(2027, 1, 1),
        date(2027, 1, 8),
    )


def test_cutoff_schedule_remains_backward_compatible() -> None:
    value = credit_schedule(date(2026, 7, 1), 1, 8, CreditCycleMode.STATEMENT_DAY_CUTOFF)
    assert (value.period_start, value.period_end, value.statement_date, value.due_date) == (
        date(2026, 6, 2),
        date(2026, 7, 1),
        date(2026, 7, 1),
        date(2026, 7, 8),
    )


def test_atomic_installment_request_defaults_to_three_periods() -> None:
    request = InstallmentPurchaseCreate(
        purchase=TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=90_000,
            occurred_at="2026-07-18T12:00:00+08:00",  # type: ignore[arg-type]
            title="淘宝商品",
            account_id="00000000-0000-0000-0000-000000000001",  # type: ignore[arg-type]
            category_id="00000000-0000-0000-0000-000000000002",  # type: ignore[arg-type]
        )
    )
    assert request.installment_count == 3
    assert request.total_fee_minor == 0


def test_atomic_installment_request_rejects_non_credit_purchase() -> None:
    with pytest.raises(ValidationError, match="must be a credit purchase"):
        InstallmentPurchaseCreate(
            purchase=TransactionDraft(
                kind=TransactionKind.EXPENSE,
                amount_minor=90_000,
                occurred_at="2026-07-18T12:00:00+08:00",  # type: ignore[arg-type]
                title="普通消费",
                account_id="00000000-0000-0000-0000-000000000001",  # type: ignore[arg-type]
                category_id="00000000-0000-0000-0000-000000000002",  # type: ignore[arg-type]
            )
        )
