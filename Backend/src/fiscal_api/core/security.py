from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette import status

from fiscal_api.api.dependencies import AccessServiceDependency
from fiscal_api.core.access_keys import is_well_formed_access_key
from fiscal_api.core.errors import APIError
from fiscal_api.core.principal import AuthenticatedPrincipal
from fiscal_api.core.rate_limit import RateLimiter
from fiscal_api.db.models.access import AccessCredential
from fiscal_api.services.access import AccessService

bearer_scheme = HTTPBearer(auto_error=False, scheme_name="AccessKey")


def client_source(request: Request) -> str:
    return request.client.host if request.client is not None else "unknown"


def rate_limiter(request: Request) -> RateLimiter:
    limiter: RateLimiter = request.app.state.rate_limiter
    return limiter


async def _authenticate_access_key(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None,
    service: AccessService,
    credential: AccessCredential,
) -> AuthenticatedPrincipal:
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
        generation_changed = await service.access_key_generation_changed(
            credentials.credentials, credential
        )
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code=("credential_generation_changed" if generation_changed else "invalid_access_key"),
            message=(
                "The access passphrase changed; unlock this client again"
                if generation_changed
                else "The access key is invalid"
            ),
        )
    await rate_limiter(request).check_authenticated(
        str(principal.id), request.method, request.url.path
    )
    return AuthenticatedPrincipal(
        id=principal.id,
        label=principal.label,
        credential_generation=principal.credential_generation,
    )


async def require_authenticated(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    access_service: AccessServiceDependency,
) -> AuthenticatedPrincipal:
    """Require a current-generation personal access key on every protected route."""
    if credentials is None or credentials.scheme.lower() != "bearer":
        await rate_limiter(request).check_failed_auth(client_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="authentication_required",
            message="A Bearer access key is required",
        )
    if not is_well_formed_access_key(credentials.credentials):
        await rate_limiter(request).check_failed_auth(client_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="invalid_access_key",
            message="The access key is invalid or has been revoked",
        )
    credential = await access_service.get_credential()
    if credential is None:
        await rate_limiter(request).check_failed_auth(client_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="authentication_required",
            message="The personal access passphrase must be initialized before use",
        )
    return await _authenticate_access_key(request, credentials, access_service, credential)


AuthenticatedDependency = Annotated[AuthenticatedPrincipal, Depends(require_authenticated)]
