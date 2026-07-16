from uuid import UUID

from fastapi import APIRouter
from starlette import status

from fiscal_api.api.dependencies import DeviceTokenServiceDependency
from fiscal_api.api.p11_schemas import (
    DeviceTokenActivationResponse,
    DeviceTokenIssuedResponse,
    DeviceTokenIssueRequest,
    DeviceTokenListResponse,
    DeviceTokenMutationResponse,
    DeviceTokenSummary,
    ExpectedVersionRequest,
)
from fiscal_api.core.security import AuthenticatedDeviceDependency, PendingDeviceDependency
from fiscal_api.db.models.security import DeviceToken

router = APIRouter(prefix="/device-tokens", tags=["device-tokens"])


def device_token_summary(row: DeviceToken) -> DeviceTokenSummary:
    return DeviceTokenSummary(
        id=row.id,
        label=row.label,
        role=row.role,  # type: ignore[arg-type]
        status=row.status,  # type: ignore[arg-type]
        fingerprint=row.fingerprint,
        version=row.version,
        created_at=row.created_at,
        activated_at=row.activated_at,
        last_used_at=row.last_used_at,
        expires_at=row.expires_at,
        pending_expires_at=row.pending_expires_at,
        revoked_at=row.revoked_at,
        replaces_id=row.replaces_id,
    )


@router.get("", response_model=DeviceTokenListResponse)
async def list_device_tokens(
    actor: AuthenticatedDeviceDependency, service: DeviceTokenServiceDependency
) -> DeviceTokenListResponse:
    rows = await service.list_visible(actor)
    return DeviceTokenListResponse(items=[device_token_summary(row) for row in rows])


@router.post("", response_model=DeviceTokenIssuedResponse, status_code=status.HTTP_201_CREATED)
async def issue_device_token(
    payload: DeviceTokenIssueRequest,
    actor: AuthenticatedDeviceDependency,
    service: DeviceTokenServiceDependency,
) -> DeviceTokenIssuedResponse:
    issued = await service.issue_device(actor, payload.label)
    return DeviceTokenIssuedResponse(
        device_token=issued.raw_token, token=device_token_summary(issued.token)
    )


@router.post(
    "/current/rotate",
    response_model=DeviceTokenIssuedResponse,
    status_code=status.HTTP_201_CREATED,
)
async def rotate_current_device_token(
    payload: ExpectedVersionRequest,
    actor: AuthenticatedDeviceDependency,
    service: DeviceTokenServiceDependency,
) -> DeviceTokenIssuedResponse:
    issued = await service.prepare_rotation(actor, payload.expected_version)
    return DeviceTokenIssuedResponse(
        device_token=issued.raw_token, token=device_token_summary(issued.token)
    )


@router.post("/activate", response_model=DeviceTokenActivationResponse)
async def activate_device_token(
    payload: ExpectedVersionRequest,
    actor: PendingDeviceDependency,
    service: DeviceTokenServiceDependency,
) -> DeviceTokenActivationResponse:
    token, predecessor_id = await service.activate(actor, payload.expected_version)
    return DeviceTokenActivationResponse(
        token=device_token_summary(token), revoked_predecessor_id=predecessor_id
    )


@router.post("/{token_id}/revoke", response_model=DeviceTokenMutationResponse)
async def revoke_device_token(
    token_id: UUID,
    payload: ExpectedVersionRequest,
    actor: AuthenticatedDeviceDependency,
    service: DeviceTokenServiceDependency,
) -> DeviceTokenMutationResponse:
    return DeviceTokenMutationResponse(
        token=device_token_summary(await service.revoke(actor, token_id, payload.expected_version))
    )
