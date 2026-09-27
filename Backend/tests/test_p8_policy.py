from datetime import UTC, datetime
from uuid import uuid4

from fiscal_api.db.models import (
    Account,
    AIProposal,
    Category,
    TransactionKind,
)
from fiscal_api.services.ai import AIService

CONFIDENCE_FIELDS = (
    "kind",
    "amount_minor",
    "occurred_at",
    "title",
    "account_id",
    "category_id",
)


def proposal(
    *,
    amount: int = 100_000,
    confidence: int = 9_000,
    kind: str = "expense",
) -> AIProposal:
    return AIProposal(
        source="text",
        raw_input="policy",
        content_fingerprint="f" * 64,
        create_idempotency_key=uuid4(),
        create_request_hash="h" * 64,
        kind=kind,
        amount_minor=amount,
        currency="CNY",
        occurred_at=datetime(2026, 7, 16, tzinfo=UTC),
        title="午餐",
        account_id=uuid4(),
        category_id=uuid4(),
        field_confidences={field: confidence for field in CONFIDENCE_FIELDS},
        overall_confidence_bps=confidence,
        missing_fields=[],
        reason_codes=[],
        status="pending",
    )


def _parse_result(**overrides):  # type: ignore[no-untyped-def]
    from fiscal_api.api.p8_schemas import AIFieldConfidences, AIProviderResult

    values = {
        "kind": TransactionKind.CREDIT_PURCHASE,
        "amount_minor": 500,
        "occurred_at": datetime(2026, 7, 19, tzinfo=UTC),
        "title": "农夫山泉安吉智能生活",
        "confidences": AIFieldConfidences(),
        "overall_confidence_bps": 9_200,
    }
    values.update(overrides)
    return AIProviderResult(**values)


def _apply(result, accounts=(), categories=()):  # type: ignore[no-untyped-def]
    value = proposal()
    service = AIService(None, provider=None)  # type: ignore[arg-type]
    service._apply_provider_result(value, result, list(accounts), list(categories))
    return value


def test_parse_blanks_non_credit_account_for_credit_purchase() -> None:
    wallet = Account(id=uuid4(), kind="cash")
    result = _parse_result(account_id=wallet.id)
    value = _apply(result, accounts=[wallet])
    assert value.account_id is None
    assert "account_kind_mismatch" in value.reason_codes


def test_parse_keeps_credit_account_for_credit_purchase() -> None:
    huabei = Account(id=uuid4(), kind="credit")
    result = _parse_result(account_id=huabei.id)
    value = _apply(result, accounts=[huabei])
    assert value.account_id == huabei.id
    assert "account_kind_mismatch" not in value.reason_codes


def test_parse_blanks_wrong_direction_category_for_credit_purchase() -> None:
    huabei = Account(id=uuid4(), kind="credit")
    salary = Category(id=uuid4(), direction="income")
    result = _parse_result(account_id=huabei.id, category_id=salary.id)
    value = _apply(result, accounts=[huabei], categories=[salary])
    assert value.category_id is None
    assert "category_direction_mismatch" in value.reason_codes


def test_parse_checks_transfer_and_repayment_account_kinds() -> None:
    huabei = Account(id=uuid4(), kind="credit")
    wallet = Account(id=uuid4(), kind="cash")
    transfer = _parse_result(
        kind=TransactionKind.TRANSFER, account_id=huabei.id, destination_account_id=huabei.id
    )
    value = _apply(transfer, accounts=[huabei, wallet])
    assert value.account_id is None
    assert value.destination_account_id is None
    assert "account_kind_mismatch" in value.reason_codes
    assert "destination_kind_mismatch" in value.reason_codes

    repayment = _parse_result(
        kind=TransactionKind.REPAYMENT, account_id=wallet.id, destination_account_id=huabei.id
    )
    value = _apply(repayment, accounts=[huabei, wallet])
    assert value.account_id == wallet.id
    assert value.destination_account_id == huabei.id
    assert "account_kind_mismatch" not in value.reason_codes


def test_parse_reclassifies_credit_account_expense_as_credit_purchase() -> None:
    huabei = Account(id=uuid4(), kind="credit")
    groceries = Category(id=uuid4(), direction="expense")
    result = _parse_result(
        kind=TransactionKind.EXPENSE, account_id=huabei.id, category_id=groceries.id
    )
    value = _apply(result, accounts=[huabei], categories=[groceries])
    assert value.kind == "credit_purchase"
    assert value.account_id == huabei.id
    assert value.category_id == groceries.id
    assert "credit_purchase_reclassified" in value.reason_codes
    assert "account_kind_mismatch" not in value.reason_codes


def test_parse_reclassified_proposal_keeps_explicit_review_reason() -> None:
    from fiscal_api.api.p8_schemas import AIFieldConfidences

    huabei = Account(id=uuid4(), kind="credit")
    groceries = Category(id=uuid4(), direction="expense")
    confident = AIFieldConfidences(**{field: 9_900 for field in CONFIDENCE_FIELDS})
    result = _parse_result(
        kind=TransactionKind.EXPENSE,
        account_id=huabei.id,
        category_id=groceries.id,
        confidences=confident,
        overall_confidence_bps=9_900,
    )
    value = _apply(result, accounts=[huabei], categories=[groceries])
    assert "credit_purchase_reclassified" in value.reason_codes


def test_parse_keeps_cash_expense_and_credit_income_behavior() -> None:
    wallet = Account(id=uuid4(), kind="cash")
    huabei = Account(id=uuid4(), kind="credit")
    expense = _parse_result(kind=TransactionKind.EXPENSE, account_id=wallet.id)
    value = _apply(expense, accounts=[wallet, huabei])
    assert value.kind == "expense"
    assert value.account_id == wallet.id
    assert "credit_purchase_reclassified" not in value.reason_codes

    income = _parse_result(kind=TransactionKind.INCOME, account_id=huabei.id)
    value = _apply(income, accounts=[wallet, huabei])
    assert value.kind == "income"
    assert value.account_id is None
    assert "account_kind_mismatch" in value.reason_codes
