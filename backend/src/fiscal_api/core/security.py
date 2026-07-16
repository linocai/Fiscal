from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette import status

from fiscal_api.api.dependencies import DeviceTokenServiceDependency
from fiscal_api.core.errors import APIError
from fiscal_api.core.rate_limit import RateLimiter
from fiscal_api.services.security import AuthenticatedDevice

bearer_scheme = HTTPBearer(auto_error=False, scheme_name="DeviceToken")


def _source(request: Request) -> str:
    return request.client.host if request.client is not None else "unknown"


def _limiter(request: Request) -> RateLimiter:
    limiter: RateLimiter = request.app.state.rate_limiter
    return limiter


async def _authenticate(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None,
    service: DeviceTokenServiceDependency,
    *,
    allow_pending: bool,
) -> AuthenticatedDevice:
    if credentials is None or credentials.scheme.lower() != "bearer":
        if service.settings.uses_database_device_tokens:
            await _limiter(request).check_failed_auth(_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="authentication_required",
            message="A Bearer device token is required",
        )
    device = await service.authenticate(credentials.credentials, allow_pending=allow_pending)
    if device is None:
        if service.settings.uses_database_device_tokens:
            await _limiter(request).check_failed_auth(_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="invalid_device_token",
            message="The device token is invalid",
        )
    if service.settings.uses_database_device_tokens:
        await _limiter(request).check_authenticated(
            str(device.id), request.method, request.url.path
        )
    return device


async def require_device_token(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    service: DeviceTokenServiceDependency,
) -> AuthenticatedDevice:
    return await _authenticate(request, credentials, service, allow_pending=False)


async def require_pending_device_token(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    service: DeviceTokenServiceDependency,
) -> AuthenticatedDevice:
    device = await _authenticate(request, credentials, service, allow_pending=True)
    if device.status != "pending":
        raise APIError(
            status_code=status.HTTP_403_FORBIDDEN,
            code="device_token_permission_denied",
            message="Activation requires a pending device token",
        )
    return device


AuthenticatedDeviceDependency = Annotated[AuthenticatedDevice, Depends(require_device_token)]
PendingDeviceDependency = Annotated[AuthenticatedDevice, Depends(require_pending_device_token)]
