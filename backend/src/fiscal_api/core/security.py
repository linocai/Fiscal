from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette import status

from fiscal_api.api.dependencies import AccessServiceDependency, DeviceTokenServiceDependency
from fiscal_api.core.errors import APIError
from fiscal_api.core.rate_limit import RateLimiter
from fiscal_api.db.models.access import AccessCredential
from fiscal_api.services.access import AccessService
from fiscal_api.services.security import AuthenticatedDevice, DeviceTokenService

bearer_scheme = HTTPBearer(auto_error=False, scheme_name="AccessKey")


def client_source(request: Request) -> str:
    return request.client.host if request.client is not None else "unknown"


def rate_limiter(request: Request) -> RateLimiter:
    limiter: RateLimiter = request.app.state.rate_limiter
    return limiter


async def _authenticate_device(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None,
    service: DeviceTokenService,
) -> AuthenticatedDevice:
    if credentials is None or credentials.scheme.lower() != "bearer":
        if service.settings.uses_database_device_tokens:
            await rate_limiter(request).check_failed_auth(client_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="authentication_required",
            message="A Bearer access key is required",
        )
    device = await service.authenticate(credentials.credentials)
    if device is None:
        if service.settings.uses_database_device_tokens:
            await rate_limiter(request).check_failed_auth(client_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="invalid_device_token",
            message="The device token is invalid",
        )
    if service.settings.uses_database_device_tokens:
        await rate_limiter(request).check_authenticated(
            str(device.id), request.method, request.url.path
        )
    return device


async def _authenticate_access_key(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None,
    service: AccessService,
    credential: AccessCredential,
) -> AuthenticatedDevice:
    if credentials is None or credentials.scheme.lower() != "bearer":
        await rate_limiter(request).check_failed_auth(client_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="authentication_required",
            message="A Bearer access key is required",
        )
    principal = await service.authenticate_access_key(credentials.credentials, credential)
    if principal is None:
        await rate_limiter(request).check_failed_auth(client_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="invalid_access_key",
            message="The access key is invalid or has been revoked",
        )
    await rate_limiter(request).check_authenticated(
        str(principal.id), request.method, request.url.path
    )
    return principal


async def require_authenticated(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    access_service: AccessServiceDependency,
    device_service: DeviceTokenServiceDependency,
) -> AuthenticatedDevice:
    """Dual-channel authentication.

    Local/test runs stay on the static token path. Once deployed, the presence
    of a passphrase credential row is the switch: while it is absent, existing
    device tokens still authenticate (transition); once it exists, only access
    keys at the current generation are accepted and device tokens are dead.
    """
    if not device_service.settings.uses_database_device_tokens:
        return await _authenticate_device(request, credentials, device_service)
    credential = await access_service.get_credential()
    if credential is not None:
        return await _authenticate_access_key(request, credentials, access_service, credential)
    return await _authenticate_device(request, credentials, device_service)


AuthenticatedDependency = Annotated[AuthenticatedDevice, Depends(require_authenticated)]
