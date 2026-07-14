import hmac
from typing import Annotated

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette import status

from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.errors import APIError

bearer_scheme = HTTPBearer(auto_error=False, scheme_name="DeviceToken")


async def require_device_token(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> None:
    expected = settings.device_token.get_secret_value()
    supplied = credentials.credentials if credentials is not None else ""
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="authentication_required",
            message="A Bearer device token is required",
        )
    if not hmac.compare_digest(supplied.encode(), expected.encode()):
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="invalid_device_token",
            message="The device token is invalid",
        )
