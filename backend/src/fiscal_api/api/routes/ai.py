from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response
from starlette import status as http_status

from fiscal_api.api.dependencies import AIServiceDependency
from fiscal_api.api.p8_schemas import (
    AIProposalCreate,
    AIProposalMutationResponse,
    AIProposalPage,
    AIProposalReplace,
    AIProposalResponse,
    AIProposalRetryRequest,
    AIProposalVersionRequest,
    AISettingsReplace,
    AISettingsResponse,
    ProposalStatus,
)
from fiscal_api.core.security import require_device_token

router = APIRouter(
    prefix="/ai",
    tags=["ai"],
    dependencies=[Depends(require_device_token)],
)


@router.get("/settings", response_model=AISettingsResponse)
async def get_ai_settings(service: AIServiceDependency) -> AISettingsResponse:
    return await service.get_settings()


@router.put("/settings", response_model=AISettingsResponse)
async def update_ai_settings(
    replacement: AISettingsReplace, service: AIServiceDependency
) -> AISettingsResponse:
    return await service.update_settings(replacement)


@router.post(
    "/proposals",
    response_model=AIProposalResponse,
    status_code=http_status.HTTP_201_CREATED,
)
async def create_ai_proposal(
    request: AIProposalCreate,
    response: Response,
    service: AIServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> AIProposalResponse:
    proposal, replay = await service.create(request, idempotency_key)
    if replay:
        response.status_code = http_status.HTTP_200_OK
    return proposal


@router.get("/proposals", response_model=AIProposalPage)
async def list_ai_proposals(
    service: AIServiceDependency,
    status: ProposalStatus | None = None,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> AIProposalPage:
    return await service.list(status=status, cursor=cursor, limit=limit)


@router.get("/proposals/{proposal_id}", response_model=AIProposalResponse)
async def get_ai_proposal(proposal_id: UUID, service: AIServiceDependency) -> AIProposalResponse:
    return await service.get(proposal_id)


@router.put("/proposals/{proposal_id}", response_model=AIProposalResponse)
async def update_ai_proposal(
    proposal_id: UUID,
    replacement: AIProposalReplace,
    service: AIServiceDependency,
) -> AIProposalResponse:
    return await service.edit(proposal_id, replacement.draft, replacement.expected_version)


@router.post("/proposals/{proposal_id}/execute", response_model=AIProposalMutationResponse)
async def execute_ai_proposal(
    proposal_id: UUID,
    request: AIProposalVersionRequest,
    service: AIServiceDependency,
) -> AIProposalMutationResponse:
    return await service.execute(proposal_id, request.expected_version)


@router.post("/proposals/{proposal_id}/ignore", response_model=AIProposalResponse)
async def ignore_ai_proposal(
    proposal_id: UUID,
    request: AIProposalVersionRequest,
    service: AIServiceDependency,
) -> AIProposalResponse:
    return await service.ignore(proposal_id, request.expected_version)


@router.post("/proposals/{proposal_id}/retry", response_model=AIProposalResponse)
async def retry_ai_proposal(
    proposal_id: UUID,
    request: AIProposalRetryRequest,
    service: AIServiceDependency,
) -> AIProposalResponse:
    return await service.retry(proposal_id, request.expected_version)


@router.post("/proposals/{proposal_id}/undo", response_model=AIProposalMutationResponse)
async def undo_ai_proposal(
    proposal_id: UUID,
    request: AIProposalVersionRequest,
    service: AIServiceDependency,
) -> AIProposalMutationResponse:
    return await service.undo(proposal_id, request.expected_version)
