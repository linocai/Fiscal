from datetime import UTC, date, datetime
from os import environ
from uuid import uuid4

import pytest

from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p5_schemas import (
    InstallmentActionRequest,
    InstallmentCreate,
    InstallmentPurchaseReplacement,
    InstallmentReplacement,
    InstallmentSettlementRequest,
)
from fiscal_api.core.errors import APIError
from fiscal_api.db.models import TransactionKind
from fiscal_api.services.credit import CreditService
from fiscal_api.services.installments import InstallmentService
from fiscal_api.services.transactions import TransactionService
from test_p5_postgres import seeded_plan
from test_p5_postgres import session as session

pytestmark = pytest.mark.skipif(
    environ.get("FISCAL_TEST_DATABASE_URL") is None, reason="requires disposable PostgreSQL"
)


async def repurchase(session):
    from fiscal_api.api.p2_schemas import AccountDraft
    from fiscal_api.db.models import AccountKind
    from fiscal_api.services.accounts import AccountService

    account, old_purchase, old_plan = await seeded_plan(session)
    cash = await AccountService(session).create(
        AccountDraft(name="Synthetic cash", kind=AccountKind.DEBIT, opening_balance_minor=2_000_000)
    )
    service = InstallmentService(session)
    settled = await service.settle_early(
        old_plan.id,
        InstallmentSettlementRequest(
            expected_version=old_plan.version,
            payment_account_id=cash.id,
            target_statement_date=date(2026, 8, 10),
            occurred_at=datetime(2026, 7, 15, 2, tzinfo=UTC),
        ),
        uuid4(),
    )
    purchase = await TransactionService(session).create(
        TransactionDraft(
            kind=TransactionKind.CREDIT_PURCHASE,
            amount_minor=500_400,
            occurred_at=datetime(2026, 7, 15, 3, tzinfo=UTC),
            title="Synthetic new device",
            account_id=account.id,
            category_id=old_purchase.category_id,
        ),
        uuid4(),
    )
    return account, cash, purchase, settled


def request(purchase, *, start=date(2026, 8, 10)):
    return InstallmentCreate(
        purchase_transaction_id=purchase.id,
        installment_count=12,
        total_fee_minor=0,
        start_statement_date=start,
    )


@pytest.mark.parametrize("start", [date(2026, 8, 10), date(2026, 9, 10)])
async def test_new_purchase_after_settlement_can_convert_without_changing_old_ledger(
    session, start
):
    account, cash, purchase, settled = await repurchase(session)
    service = InstallmentService(session)
    eligibility = await service.eligibility(purchase.id)
    assert eligibility.eligible and eligibility.start_options
    plan = await service.create(request(purchase, start=start), uuid4())
    assert [p.principal_minor for p in plan.periods] == [41_700] * 12
    assert plan.locked_count == 0
    prior = await service.get(settled.plan.id)
    assert prior.version == settled.plan.version
    assert prior.status == settled.plan.status
    assert [(p.id, p.principal_minor, p.fee_minor, p.settled_early_at) for p in prior.periods] == [
        (p.id, p.principal_minor, p.fee_minor, p.settled_early_at) for p in settled.plan.periods
    ]
    assert (
        await TransactionService(session).get(settled.repayment_transaction.id)
        == settled.repayment_transaction
    )
    summary = await CreditService(session).get_account(account.id)
    assert summary.current_debt_minor == 500_400

    # Current-cycle creation must remain editable; an old repayment must not
    # falsely lock the newly created first period or its replacement suffix.
    replacement = InstallmentReplacement(
        expected_version=plan.version,
        purchase=InstallmentPurchaseReplacement(
            occurred_at=purchase.occurred_at,
            title=purchase.title,
            amount_minor=purchase.amount_minor,
            account_id=account.id,
            category_id=purchase.category_id,
        ),
        installment_count=10,
        total_fee_minor=0,
        start_statement_date=start,
    )
    preview = await service.preview_update(plan.id, replacement)
    assert not preview.locked_periods
    replacement.preview_fingerprint = preview.preview_fingerprint
    updated = await service.update(plan.id, replacement)
    assert sum(p.principal_minor for p in updated.periods) == 500_400
    paid = await service.settle_early(
        plan.id,
        InstallmentSettlementRequest(
            expected_version=updated.version,
            payment_account_id=cash.id,
            target_statement_date=start,
            occurred_at=datetime(2026, 7, 15, 4, tzinfo=UTC),
        ),
        uuid4(),
    )
    assert paid.repayment_transaction.amount_minor == 500_400
    assert (await CreditService(session).get_account(account.id)).current_debt_minor == 0
    reversed_result = await service.reverse_settlement(
        plan.id,
        InstallmentActionRequest(
            expected_version=paid.plan.version,
            occurred_at=datetime(2026, 7, 15, 5, tzinfo=UTC),
        ),
        uuid4(),
    )
    assert reversed_result.plan.locked_count == 0
    assert (await CreditService(session).get_account(account.id)).current_debt_minor == 500_400


@pytest.mark.parametrize("amount,hour", [(1, 4), (500_400, 4), (1, 3)])
async def test_repayment_at_or_after_new_purchase_still_blocks_whole_conversion(
    session, amount, hour
):
    account, cash, purchase, _settled = await repurchase(session)
    ledger = TransactionService(session)
    repayment = await ledger.create(
        TransactionDraft(
            kind=TransactionKind.REPAYMENT,
            amount_minor=amount,
            occurred_at=datetime(2026, 7, 15, hour, tzinfo=UTC),
            title="Synthetic new repayment",
            account_id=cash.id,
            destination_account_id=account.id,
            credit_cycle_id=purchase.credit_cycle_id,
        ),
        uuid4(),
    )
    service = InstallmentService(session)
    eligibility = await service.eligibility(purchase.id)
    assert not eligibility.eligible
    assert eligibility.reason_code == "purchase_cycle_repaid_after_purchase"
    with pytest.raises(APIError) as error:
        await service.create(request(purchase), uuid4())
    assert error.value.code == eligibility.reason_code
    await session.rollback()
    await ledger.void(repayment.id, repayment.version)
    assert (await service.eligibility(purchase.id)).eligible
