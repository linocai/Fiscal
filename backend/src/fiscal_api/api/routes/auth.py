from typing import Annotated

from fastapi import APIRouter, Depends, Request
from starlette import status

from fiscal_api.api.auth_schemas import (
    AccessKeyResponse,
    AccessStatusResponse,
    ChangePassphraseRequest,
    InitializePassphraseRequest,
    SessionRequest,
)
from fiscal_api.api.dependencies import AccessServiceDependency
from fiscal_api.api.p11_schemas import RateLimitPolicy
from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.errors import APIError
from fiscal_api.core.security import (
    AuthenticatedDependency,
    client_source,
    rate_limiter,
    require_authenticated,
)
from fiscal_api.core.time import utc_now

router = APIRouter(prefix="/auth", tags=["auth"])


def _rate_limits(settings: Settings) -> RateLimitPolicy:
    return RateLimitPolicy(
        read_per_minute=settings.rate_limit_read_per_minute,
        write_per_minute=settings.rate_limit_write_per_minute,
        ai_per_minute=settings.rate_limit_ai_per_minute,
        failed_auth_per_minute=settings.rate_limit_failed_auth_per_minute,
    )


@router.post("/session", response_model=AccessKeyResponse)
async def create_session(
    request: Request,
    payload: SessionRequest,
    service: AccessServiceDependency,
) -> AccessKeyResponse:
    credential = await service.get_credential()
    if credential is None:
        raise APIError(
            status_code=status.HTTP_409_CONFLICT,
            code="passphrase_not_set",
            message="The access passphrase has not been set",
        )
    if not service.verify_passphrase(credential, payload.passphrase):
        await rate_limiter(request).check_failed_auth(client_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="invalid_passphrase",
            message="The access passphrase is invalid",
        )
    minted = await service.login(credential)
    return AccessKeyResponse(
        access_key=minted.raw_key, credential_generation=minted.credential_generation
    )


@router.post("/passphrase/initialize", response_model=AccessKeyResponse)
async def initialize_passphrase(
    payload: InitializePassphraseRequest,
    _principal: AuthenticatedDependency,
    service: AccessServiceDependency,
) -> AccessKeyResponse:
    minted = await service.initialize(payload.passphrase)
    return AccessKeyResponse(
        access_key=minted.raw_key, credential_generation=minted.credential_generation
    )


@router.post("/passphrase/change", response_model=AccessKeyResponse)
async def change_passphrase(
    request: Request,
    payload: ChangePassphraseRequest,
    _principal: AuthenticatedDependency,
    service: AccessServiceDependency,
) -> AccessKeyResponse:
    credential = await service.get_credential()
    if credential is None:
        raise APIError(
            status_code=status.HTTP_409_CONFLICT,
            code="passphrase_not_set",
            message="The access passphrase has not been set",
        )
    if not service.verify_passphrase(credential, payload.old_passphrase):
        await rate_limiter(request).check_failed_auth(client_source(request))
        raise APIError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            code="invalid_passphrase",
            message="The access passphrase is invalid",
        )
    minted = await service.change(payload.new_passphrase)
    return AccessKeyResponse(
        access_key=minted.raw_key, credential_generation=minted.credential_generation
    )


@router.get(
    "/status",
    response_model=AccessStatusResponse,
    dependencies=[Depends(require_authenticated)],
)
async def auth_status(
    service: AccessServiceDependency,
    settings: Annotated[Settings, Depends(get_settings)],
) -> AccessStatusResponse:
    credential = await service.get_credential()
    if credential is not None:
        return AccessStatusResponse(
            authentication_mode="passphrase",
            passphrase_set=True,
            credential_generation=credential.credential_generation,
            last_rotated_at=credential.last_rotated_at,
            active_access_key_count=await service.active_access_key_count(
                credential.credential_generation
            ),
            server_time=utc_now(),
            rate_limits=_rate_limits(settings),
        )
    return AccessStatusResponse(
        authentication_mode="transition_device_token",
        passphrase_set=False,
        credential_generation=None,
        last_rotated_at=None,
        active_access_key_count=0,
        server_time=utc_now(),
        rate_limits=_rate_limits(settings),
    )
