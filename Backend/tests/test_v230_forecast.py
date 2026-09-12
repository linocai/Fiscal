from datetime import UTC, date, datetime
from uuid import uuid4

import pytest
from pydantic import ValidationError

from fiscal_api.api.p7_schemas import DisposableFacts
from fiscal_api.api.p13_schemas import CashFlowExistingSettlementDraft, CashFlowSettlementDraft
from fiscal_api.db.models import LedgerTransaction, Posting
from fiscal_api.services.reporting import ReportingService


def test_old_settlement_closes_remainder_and_partial_is_explicit() -> None:
    values = dict(
        expected_version=1,
        actual_amount_minor=1,
        occurred_at=datetime(2026, 9, 12, tzinfo=UTC),
        account_id=uuid4(),
    )
    assert CashFlowSettlementDraft(**values).complete_remaining is True
    assert CashFlowSettlementDraft(**values, complete_remaining=False).complete_remaining is False
    with pytest.raises(ValidationError):
        CashFlowExistingSettlementDraft(
            expected_version=1, transaction_id=uuid4(), transaction_expected_version=0
        )


def test_disposable_requires_complete_server_facts() -> None:
    with pytest.raises(ValidationError):
        DisposableFacts(date_from=date(2026, 9, 12), date_to=date(2026, 10, 11))


def test_bank_fee_refund_has_negative_consumption_and_no_fake_income() -> None:
    transaction = LedgerTransaction(
        kind="credit_fee_refund",
        postings=[Posting(account_id=uuid4(), amount_minor=123, position=0, role="account")],
    )
    assert ReportingService._canonical_spending(transaction) == -123
    transaction.kind = "credit_settlement_fee"
    transaction.postings[0].amount_minor = -123
    assert ReportingService._canonical_spending(transaction) == 123


async def test_fee_refund_report_reduces_net_consumption_without_gross_income() -> None:
    from unittest.mock import AsyncMock

    from sqlalchemy.ext.asyncio import AsyncSession

    service = ReportingService(AsyncSession())
    service.repository.refunds_for_sources = AsyncMock(return_value=[])
    service.repository.reimbursement_facts = AsyncMock(return_value=[])
    transaction = LedgerTransaction(
        id=uuid4(),
        kind="credit_fee_refund",
        postings=[Posting(account_id=uuid4(), amount_minor=123, position=0, role="account")],
    )
    facts = await service._facts_for_transactions([transaction])
    total = service._sum_spending(facts)
    assert total.gross_consumption_minor == 0
    assert total.merchant_refund_minor == 123
    assert total.net_consumption_minor == -123
    assert total.personal_realized_minor == -123
