from datetime import datetime
from typing import Literal

from pydantic import Field

from fiscal_api.api.p11_schemas import RateLimitPolicy
from fiscal_api.api.schemas import APIModel
from fiscal_api.core.access_keys import PASSPHRASE_MAX_LENGTH, PASSPHRASE_MIN_LENGTH

_Passphrase = Field(min_length=PASSPHRASE_MIN_LENGTH, max_length=PASSPHRASE_MAX_LENGTH)


class SessionRequest(APIModel):
    passphrase: str = _Passphrase


class InitializePassphraseRequest(APIModel):
    passphrase: str = _Passphrase


class ChangePassphraseRequest(APIModel):
    old_passphrase: str = _Passphrase
    new_passphrase: str = _Passphrase


class AccessKeyResponse(APIModel):
    access_key: str
    credential_generation: int


class AccessStatusResponse(APIModel):
    authentication_mode: Literal["passphrase", "transition_device_token"]
    passphrase_set: bool
    credential_generation: int | None
    last_rotated_at: datetime | None
    active_access_key_count: int
    server_time: datetime
    rate_limits: RateLimitPolicy
