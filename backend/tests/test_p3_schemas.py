from datetime import datetime

import pytest
from pydantic import ValidationError

from fiscal_api.api.p3_schemas import MAX_MINOR_UNITS, TransactionDraft
from fiscal_api.db.models import TransactionKind


@pytest.mark.parametrize("amount", [0, -1, 1.5, True, MAX_MINOR_UNITS + 1])
def test_transaction_money_is_strict_positive_int64(amount: object) -> None:
    with pytest.raises(ValidationError):
        TransactionDraft(
            kind=TransactionKind.EXPENSE,
            amount_minor=amount,  # type: ignore[arg-type]
            occurred_at="2026-07-15T12:00:00Z",  # type: ignore[arg-type]
            title="午餐",
        )


def test_transaction_requires_aware_time_and_normalizes_text() -> None:
    with pytest.raises(ValidationError, match="timezone"):
        TransactionDraft(
            kind=TransactionKind.INCOME,
            amount_minor=100,
            occurred_at=datetime(2026, 7, 15, 12, 0),
            title="工资",
        )

    draft = TransactionDraft(
        kind=TransactionKind.INCOME,
        amount_minor=100,
        occurred_at="2026-07-15T12:00:00+08:00",  # type: ignore[arg-type]
        title="  工资  ",
        note="   ",
    )
    assert draft.title == "工资"
    assert draft.note is None
