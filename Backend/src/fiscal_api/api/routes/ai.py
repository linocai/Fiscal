from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response
from starlette import status as http_status

from fiscal_api.api.dependencies import AIServiceDependency, formal_mutation
from fiscal_api.api.p8_schemas import (
    AIExecutionPolicyReplace,
    AIExecutionPolicyResponse,
    AILearningRuleResponse,
    AIProposalCreate,
    AIProposalMutationResponse,
    AIProposalPage,
    AIProposalReplace,
    AIProposalResponse,
    AIProposalRetryRequest,
    AIProposalUndoRequest,
    AIProposalVersionRequest,
    AIProviderSettingsReplace,
    AIProviderSettingsResponse,
    AIQualityEventResponse,
    AIQualityMetricsResponse,
    AISettingsReplace,
    AISettingsResponse,
    AIShadowEvaluationCreate,
    AIShadowEvaluationResponse,
    ProposalStatus,
)
from fiscal_api.core.security import AuthenticatedDependency, require_authenticated

router = APIRouter(
    prefix="/ai",
    tags=["ai"],
    dependencies=[Depends(require_authenticated)],
)


@router.get("/settings", response_model=AISettingsResponse)
async def get_ai_settings(service: AIServiceDependency) -> AISettingsResponse:
    return await service.get_settings()


@router.put(
    "/settings",
    response_model=AISettingsResponse,
    dependencies=[formal_mutation("ai", "attention")],
)
async def update_ai_settings(
    replacement: AISettingsReplace, service: AIServiceDependency
) -> AISettingsResponse:
    return await service.update_settings(replacement)


@router.get("/quality/metrics", response_model=AIQualityMetricsResponse)
async def get_ai_quality_metrics(service: AIServiceDependency) -> AIQualityMetricsResponse:
    return await service.quality_metrics()


@router.get("/strategy", response_model=list[AIExecutionPolicyResponse])
async def list_ai_strategy(service: AIServiceDependency) -> list[AIExecutionPolicyResponse]:
    return await service.policies()


@router.post(
    "/strategy",
    response_model=AIExecutionPolicyResponse,
    dependencies=[formal_mutation("ai", "attention")],
)
async def replace_ai_strategy(
    replacement: AIExecutionPolicyReplace, service: AIServiceDependency
) -> AIExecutionPolicyResponse:
    return await service.replace_policy(replacement)


@router.post(
    "/shadow-evaluations",
    response_model=AIShadowEvaluationResponse,
    dependencies=[formal_mutation("ai", "attention")],
)
async def record_ai_shadow_evaluation(
    record: AIShadowEvaluationCreate, service: AIServiceDependency
) -> AIShadowEvaluationResponse:
    return await service.record_shadow_evaluation(record)


@router.get("/learning-rules", response_model=list[AILearningRuleResponse])
async def list_ai_learning_rules(service: AIServiceDependency) -> list[AILearningRuleResponse]:
    return await service.rules()


@router.post(
    "/learning-rules/{rule_id}/revoke",
    response_model=AILearningRuleResponse,
    dependencies=[formal_mutation("ai", "attention")],
)
async def revoke_ai_learning_rule(
    rule_id: UUID, service: AIServiceDependency
) -> AILearningRuleResponse:
    return await service.revoke_rule(rule_id)


@router.get("/provider-settings", response_model=AIProviderSettingsResponse)
async def get_ai_provider_settings(service: AIServiceDependency) -> AIProviderSettingsResponse:
    return await service.get_provider_settings()


@router.put(
    "/provider-settings",
    response_model=AIProviderSettingsResponse,
    dependencies=[formal_mutation("ai", "attention")],
)
async def update_ai_provider_settings(
    replacement: AIProviderSettingsReplace,
    actor: AuthenticatedDependency,
    service: AIServiceDependency,
) -> AIProviderSettingsResponse:
    return await service.update_provider_settings(replacement, actor)


@router.post(
    "/proposals",
    response_model=AIProposalResponse,
    status_code=http_status.HTTP_201_CREATED,
    dependencies=[formal_mutation("ai", "ledger", "accounts", "cash_flow", "reports", "attention")],
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


@router.delete(
    "/proposals/{proposal_id}",
    status_code=http_status.HTTP_204_NO_CONTENT,
    dependencies=[formal_mutation("ai", "attention")],
)
async def delete_ai_proposal(
    proposal_id: UUID,
    service: AIServiceDependency,
    expected_version: Annotated[int, Query(ge=1)],
) -> Response:
    await service.delete(proposal_id, expected_version)
    return Response(status_code=http_status.HTTP_204_NO_CONTENT)


@router.get("/proposals/{proposal_id}/quality-events", response_model=list[AIQualityEventResponse])
async def get_ai_quality_events(
    proposal_id: UUID, service: AIServiceDependency
) -> list[AIQualityEventResponse]:
    return await service.quality_events(proposal_id)


@router.put(
    "/proposals/{proposal_id}",
    response_model=AIProposalResponse,
    dependencies=[formal_mutation("ai", "ledger", "accounts", "cash_flow", "reports", "attention")],
)
async def update_ai_proposal(
    proposal_id: UUID,
    replacement: AIProposalReplace,
    service: AIServiceDependency,
) -> AIProposalResponse:
    return await service.edit(proposal_id, replacement.draft, replacement.expected_version)


@router.post(
    "/proposals/{proposal_id}/execute",
    response_model=AIProposalMutationResponse,
    dependencies=[formal_mutation("ai", "ledger", "accounts", "cash_flow", "reports", "attention")],
)
async def execute_ai_proposal(
    proposal_id: UUID,
    request: AIProposalVersionRequest,
    service: AIServiceDependency,
) -> AIProposalMutationResponse:
    return await service.execute(proposal_id, request.expected_version)


@router.post(
    "/proposals/{proposal_id}/ignore",
    response_model=AIProposalResponse,
    dependencies=[formal_mutation("ai", "attention")],
)
async def ignore_ai_proposal(
    proposal_id: UUID,
    request: AIProposalVersionRequest,
    service: AIServiceDependency,
) -> AIProposalResponse:
    return await service.ignore(proposal_id, request.expected_version)


@router.post(
    "/proposals/{proposal_id}/retry",
    response_model=AIProposalResponse,
    dependencies=[formal_mutation("ai", "attention")],
)
async def retry_ai_proposal(
    proposal_id: UUID,
    request: AIProposalRetryRequest,
    service: AIServiceDependency,
) -> AIProposalResponse:
    return await service.retry(proposal_id, request.expected_version)


@router.post(
    "/proposals/{proposal_id}/undo",
    response_model=AIProposalMutationResponse,
    dependencies=[formal_mutation("ai", "ledger", "accounts", "cash_flow", "reports", "attention")],
)
async def undo_ai_proposal(
    proposal_id: UUID,
    request: AIProposalUndoRequest,
    service: AIServiceDependency,
) -> AIProposalMutationResponse:
    return await service.undo(
        proposal_id,
        request.expected_version,
        request.expected_transaction_version,
    )
