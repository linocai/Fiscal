from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Response
from starlette import status

from fiscal_api.api.dependencies import ReconciliationServiceDependency
from fiscal_api.api.p21_schemas import (
    AttentionIgnore,
    AttentionPage,
    BalanceDiagnosis,
    CheckpointCreate,
    CheckpointResponse,
    ReconciliationTargetKind,
)
from fiscal_api.core.security import require_authenticated

router = APIRouter(
    prefix="/reconciliation",
    tags=["reconciliation"],
    dependencies=[Depends(require_authenticated)],
)


@router.post("/checkpoints", response_model=CheckpointResponse, status_code=status.HTTP_201_CREATED)
async def create_checkpoint(
    request: CheckpointCreate, service: ReconciliationServiceDependency
) -> CheckpointResponse:
    return await service.create(request)


@router.get("/checkpoints", response_model=list[CheckpointResponse])
async def checkpoints(
    service: ReconciliationServiceDependency,
    account_id: UUID | None = None,
    credit_cycle_id: UUID | None = None,
) -> list[CheckpointResponse]:
    return await service.list(account_id=account_id, credit_cycle_id=credit_cycle_id)


@router.get("/diagnosis", response_model=BalanceDiagnosis)
async def diagnosis(
    service: ReconciliationServiceDependency,
    target_kind: ReconciliationTargetKind,
    as_of: datetime,
    account_id: UUID | None = None,
    credit_cycle_id: UUID | None = None,
) -> BalanceDiagnosis:
    return await service.diagnosis(
        target_kind=target_kind,
        account_id=account_id,
        credit_cycle_id=credit_cycle_id,
        as_of=as_of,
    )


@router.get("/attention", response_model=AttentionPage)
async def attention(service: ReconciliationServiceDependency) -> AttentionPage:
    return await service.attention()


@router.post("/attention/{source_type}/{source_id}/ignore", status_code=status.HTTP_204_NO_CONTENT)
async def ignore_attention(
    source_type: str,
    source_id: UUID,
    request: AttentionIgnore,
    service: ReconciliationServiceDependency,
) -> Response:
    await service.ignore_attention(source_type, source_id, request)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
