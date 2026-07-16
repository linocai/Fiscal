from datetime import datetime
from decimal import Decimal

import pytest
from pydantic import BaseModel, SecretStr, ValidationError

from fiscal_api.core.config import DEFAULT_DEVELOPMENT_TOKEN, Settings
from fiscal_api.core.money import CNYAmount, normalize_cny
from fiscal_api.core.time import BUSINESS_TIMEZONE, UTC, ensure_utc, to_business_time


class AmountModel(BaseModel):
    amount: CNYAmount


def test_cny_amount_quantizes_and_serializes_as_decimal_string() -> None:
    amount = AmountModel(amount="12.345")

    assert amount.amount == Decimal("12.35")
    assert amount.model_dump(mode="json") == {"amount": "12.35"}


@pytest.mark.parametrize("value", [1.1, True, "NaN", "Infinity"])
def test_cny_amount_rejects_unsafe_values(value: object) -> None:
    with pytest.raises((ValueError, ValidationError)):
        normalize_cny(value)


def test_time_helpers_require_aware_values_and_use_shanghai() -> None:
    utc_value = datetime(2026, 7, 14, 0, 0, tzinfo=UTC)

    assert to_business_time(utc_value).hour == 8
    assert to_business_time(utc_value).tzinfo == BUSINESS_TIMEZONE
    with pytest.raises(ValueError, match="timezone"):
        ensure_utc(datetime(2026, 7, 14))


def test_production_rejects_legacy_tokens_and_requires_strong_pepper() -> None:
    with pytest.raises(ValidationError, match="forbidden"):
        Settings(environment="production", device_token=SecretStr(DEFAULT_DEVELOPMENT_TOKEN))
    with pytest.raises(ValidationError, match="at least 32"):
        Settings(environment="production", token_pepper=SecretStr("short"))
