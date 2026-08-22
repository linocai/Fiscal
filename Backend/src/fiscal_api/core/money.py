from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Annotated, Any

from pydantic import BeforeValidator, PlainSerializer

CURRENCY = "CNY"
CNY_QUANTUM = Decimal("0.01")


def normalize_cny(value: Any) -> Decimal:
    if isinstance(value, (bool, float)):
        raise ValueError("CNY amount must be a decimal string or integer, never a float")
    try:
        amount = Decimal(value)
    except (InvalidOperation, TypeError, ValueError) as error:
        raise ValueError("invalid CNY amount") from error
    if not amount.is_finite():
        raise ValueError("CNY amount must be finite")
    return amount.quantize(CNY_QUANTUM, rounding=ROUND_HALF_UP)


CNYAmount = Annotated[
    Decimal,
    BeforeValidator(normalize_cny),
    PlainSerializer(lambda value: format(value, ".2f"), return_type=str),
]
