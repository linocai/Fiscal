from datetime import UTC, datetime
from uuid import uuid4

from fiscal_api.core.config import Settings
from fiscal_api.core.errors import APIError
from fiscal_api.core.provider_credentials import ProviderCredentialCipher
from fiscal_api.db.models import (
    Account,
    AIExecutionPolicy,
    AIProposal,
    AISettings,
    Category,
    TransactionKind,
)
from fiscal_api.services.ai import AIService
from fiscal_api.services.ai_provider import DisabledAIProvider

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


def settings(*, enabled: bool = True, limit: int = 100_000, confidence: int = 9_000) -> AISettings:
    return AISettings(
        id=1,
        auto_execute_enabled=enabled,
        ocr_source_enabled=False,
        shortcut_text_source_enabled=False,
        auto_execute_limit_minor=limit,
        minimum_confidence_bps=confidence,
        version=1,
        created_at=datetime(2026, 7, 16, tzinfo=UTC),
        updated_at=datetime(2026, 7, 16, tzinfo=UTC),
    )


def test_d3_retired_policy_rejects_enable_and_every_relaxation_with_stable_code() -> None:
    for values in (
        dict(enabled=True, limit=100_000, confidence=9_000, minimum_sample_size=30),
        dict(enabled=False, limit=100_000, confidence=9_500, minimum_sample_size=30),
        dict(enabled=False, limit=50_000, confidence=9_000, minimum_sample_size=30),
        dict(enabled=False, limit=50_000, confidence=9_500, minimum_sample_size=1),
    ):
        try:
            AIService._reject_retired_auto_execute(
                **values,
                current_limit=50_000,
                current_confidence=9_500,
                current_minimum_sample_size=30,
            )
        except APIError as error:
            assert error.code == "ai_auto_execute_retired"
        else:
            raise AssertionError("retired automatic execution relaxation was accepted")

    AIService._reject_retired_auto_execute(
        enabled=False,
        limit=40_000,
        confidence=9_600,
        minimum_sample_size=40,
        current_limit=50_000,
        current_confidence=9_500,
        current_minimum_sample_size=30,
    )


def test_d3_settings_response_is_false_even_for_legacy_true_configured_row() -> None:
    value = settings(enabled=True)
    value.provider_kind = "openai_compatible"
    value.provider_base_url = "https://provider.example/v1"
    value.provider_model = "legacy-model"
    value.provider_api_key_ciphertext = "legacy-ciphertext"
    value.provider_key_version = 1
    response = AIService(
        None,  # type: ignore[arg-type]
        provider=DisabledAIProvider(),
        runtime_settings=Settings(environment="test"),
        credential_cipher=ProviderCredentialCipher("p35-provider-root-secret-at-least-32-bytes"),
    )._settings_response(value)
    assert response.provider_configured is True
    assert response.auto_execute_enabled is False
    assert response.effective_auto_execute is False


def test_d3_strategy_response_is_false_for_legacy_true_row() -> None:
    policy = AIExecutionPolicy(
        id=uuid4(),
        version=9,
        effective_at=datetime(2026, 7, 16, tzinfo=UTC),
        source=None,
        transaction_kind=None,
        auto_execute_enabled=True,
        auto_execute_limit_minor=100_000,
        minimum_confidence_bps=9_000,
        minimum_sample_size=30,
        change_reason="legacy true",
        changed_automatically=False,
        created_at=datetime(2026, 7, 16, tzinfo=UTC),
    )
    assert AIService._policy_response(policy).auto_execute_enabled is False


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
