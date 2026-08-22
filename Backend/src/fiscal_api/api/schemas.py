from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict


class APIModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class LiveResponse(APIModel):
    status: Literal["live"] = "live"


class ReadyResponse(APIModel):
    status: Literal["ready"] = "ready"
    database: Literal["ready"] = "ready"


class SystemStatusResponse(APIModel):
    service: str
    version: str
    environment: str
    status: Literal["operational"] = "operational"
    database: Literal["ready"] = "ready"
    currency: Literal["CNY"] = "CNY"
    business_timezone: Literal["Asia/Shanghai"] = "Asia/Shanghai"
    timestamp: datetime
