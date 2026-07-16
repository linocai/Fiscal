from datetime import UTC, datetime
from uuid import uuid4

import pytest

from fiscal_api.db.models import AIProposal, AISettings
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
