from datetime import UTC, datetime
from uuid import uuid4

import pytest

from fiscal_api.db.models import Account, AIProposal, AISettings, Category, TransactionKind
from fiscal_api.services.ai import REQUIRED_CONFIDENCE_FIELDS, AIService


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
        field_confidences={field: confidence for field in REQUIRED_CONFIDENCE_FIELDS},
        overall_confidence_bps=confidence,
        missing_fields=[],
        reason_codes=[],
        status="pending",
    )


def settings(*, enabled: bool = True, limit: int = 100_000, confidence: int = 9_000) -> AISettings:
    return AISettings(
        id=1,
        auto_execute_enabled=enabled,
        auto_execute_limit_minor=limit,
        minimum_confidence_bps=confidence,
    )


@pytest.mark.parametrize(
    ("amount", "confidence", "eligible"),
    [
        (99_999, 8_999, False),
        (99_999, 9_000, True),
        (100_000, 9_001, True),
        (100_001, 10_000, False),
    ],
)
def test_hard_amount_and_confidence_boundaries(
    amount: int, confidence: int, eligible: bool
) -> None:
    assert (
        AIService._auto_eligible(proposal(amount=amount, confidence=confidence), settings())
        is eligible
    )


@pytest.mark.parametrize("field", REQUIRED_CONFIDENCE_FIELDS)
def test_each_required_field_confidence_blocks_automatic_execution(field: str) -> None:
    value = proposal(confidence=9_500)
    value.field_confidences[field] = 8_999
    assert not AIService._auto_eligible(value, settings())


def test_user_settings_only_tighten_and_forbidden_shapes_stay_pending() -> None:
    assert not AIService._auto_eligible(proposal(amount=50_001), settings(limit=50_000))
    assert not AIService._auto_eligible(proposal(confidence=9_499), settings(confidence=9_500))
    assert not AIService._auto_eligible(proposal(), settings(enabled=False))
    for kind in ("transfer", "credit_purchase", "repayment"):
        assert not AIService._auto_eligible(proposal(kind=kind), settings())
    value = proposal()
    value.destination_account_id = uuid4()
    assert not AIService._auto_eligible(value, settings())
    value.destination_account_id = None
    value.reason_codes = ["unknown_category"]
    assert not AIService._auto_eligible(value, settings())


def test_p9_source_switch_is_rechecked_before_automatic_execution() -> None:
    value = proposal()
    value.source = "ocr"
    current = settings()
    current.ocr_source_enabled = False
    assert not AIService._auto_eligible(value, current)
    current.ocr_source_enabled = True
    assert AIService._auto_eligible(value, current)

    value.source = "shortcut_text"
    current.shortcut_text_source_enabled = False
    assert not AIService._auto_eligible(value, current)
    current.shortcut_text_source_enabled = True
    assert AIService._auto_eligible(value, current)


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
