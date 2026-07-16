from __future__ import annotations

from datetime import date, datetime, time
from decimal import Decimal

from fiscal_api.core.time import BUSINESS_TIMEZONE, UTC
from fiscal_api.services.common import INT64_MAX, INT64_MIN


class LegacyTransformError(ValueError):
    """A legacy value cannot be represented by Fiscal without guessing."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def yuan_to_minor(value: Decimal, *, field: str = "amount") -> int:
    """Convert an exact yuan Decimal to signed 64-bit fen without rounding."""
    if not value.is_finite():
        raise LegacyTransformError(
            "invalid_money",
            f"{field} must be a finite decimal amount",
        )
    scaled = value * 100
    integral = scaled.to_integral_value()
    if scaled != integral:
        raise LegacyTransformError(
            "money_has_fractional_fen",
            f"{field} cannot be represented as an exact number of fen",
        )
    minor = int(integral)
    if minor < INT64_MIN or minor > INT64_MAX:
        raise LegacyTransformError(
            "money_out_of_range",
            f"{field} is outside the signed 64-bit integer range",
        )
    return minor


def legacy_date_to_occurred_at(value: date) -> datetime:
    """Map a legacy business date to approved Shanghai noon, stored as UTC."""
    if isinstance(value, datetime):
        raise LegacyTransformError(
            "legacy_date_expected",
            "legacy occurrence value must be a date without a time component",
        )
    local_noon = datetime.combine(value, time(hour=12), tzinfo=BUSINESS_TIMEZONE)
    return local_noon.astimezone(UTC)


def inferred_opening_balance_minor(*, current_minor: int, movement_net_minor: int) -> int:
    """Infer opening asset balance from current = opening + included movements."""
    opening = current_minor - movement_net_minor
    if opening < INT64_MIN or opening > INT64_MAX:
        raise LegacyTransformError(
            "opening_balance_out_of_range",
            "inferred opening balance is outside the signed 64-bit integer range",
        )
    return opening


def normalize_reimbursement_party(value: str) -> str:
    """Apply the user-approved legacy aliases while preserving unknown names."""
    normalized = value.strip()
    if not normalized:
        raise LegacyTransformError(
            "empty_reimbursement_party",
            "reimbursement party cannot be empty",
        )
    if normalized.casefold() == "company" or normalized in {"公司", "111"}:
        return "公司"
    return normalized


CATEGORY_MAP: dict[tuple[str, str], str] = {
    ("expense", "吃饭"): "餐饮",
    ("expense", "超市"): "日用",
    ("expense", "生活用品"): "日用",
    ("expense", "买衣服"): "服饰",
    ("expense", "猫猫"): "宠物",
    ("expense", "社交"): "社交",
    ("expense", "游戏"): "娱乐",
    ("expense", "电子产品"): "数码",
    ("expense", "健身专项"): "健康",
    ("expense", "月付"): "固定支出",
    ("expense", "AI专项"): "AI工具",
    ("expense", "公司自费"): "工作垫付",
    ("expense", "报销"): "工作垫付",
    ("expense", "其他支出"): "其他支出",
    ("expense", "意外"): "其他支出",
    ("expense", "平账"): "平账",
    ("expense", "理财"): "理财",
    ("income", "工资"): "工资",
    ("income", "房租"): "房租",
    ("income", "意外"): "其他收入",
    ("income", "报销"): "历史报销",
}


def mapped_category(direction: str, legacy_name: str) -> str | None:
    """Return an approved target category, leaving unresolved rows explicit."""
    return CATEGORY_MAP.get((direction.strip().casefold(), legacy_name.strip()))
