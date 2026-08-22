from datetime import datetime
from zoneinfo import ZoneInfo

UTC = ZoneInfo("UTC")
BUSINESS_TIMEZONE = ZoneInfo("Asia/Shanghai")


def utc_now() -> datetime:
    return datetime.now(tz=UTC)


def ensure_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("datetime must include a timezone")
    return value.astimezone(UTC)


def to_business_time(value: datetime) -> datetime:
    return ensure_utc(value).astimezone(BUSINESS_TIMEZONE)
