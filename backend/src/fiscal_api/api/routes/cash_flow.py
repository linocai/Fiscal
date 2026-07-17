from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header
from starlette import status as http_status

from fiscal_api.api.dependencies import CashFlowServiceDependency
from fiscal_api.api.p13_schemas import (
    CashFlowActiveResponse,
    CashFlowCreateResponse,
    CashFlowDraft,
    CashFlowHistoryResponse,
    CashFlowItemResponse,
    CashFlowReplace,
    CashFlowSettlementDraft,
    CashFlowVersionRequest,
)
from fiscal_api.core.security import require_device_token

router = APIRouter(tags=["cash-flow"], dependencies=[Depends(require_device_token)])


@router.get("/cash-flow-items", response_model=CashFlowActiveResponse)
async def active(
    service: CashFlowServiceDependency, account_id: UUID | None = None
) -> CashFlowActiveResponse:
    return await service.active(account_id=account_id)


@router.get("/cash-flow-items/history", response_model=CashFlowHistoryResponse)
async def history(
    service: CashFlowServiceDependency, month: str | None = None
) -> CashFlowHistoryResponse:
    return await service.history(month)


@router.post(
    "/cash-flow-items",
    response_model=CashFlowCreateResponse,
    status_code=http_status.HTTP_201_CREATED,
)
async def create(
    request: CashFlowDraft,
    service: CashFlowServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> CashFlowCreateResponse:
    return await service.create(request, idempotency_key)


@router.get("/cash-flow-items/{item_id}", response_model=CashFlowItemResponse)
async def get(item_id: UUID, service: CashFlowServiceDependency) -> CashFlowItemResponse:
    return await service.get(item_id)


@router.put("/cash-flow-items/{item_id}", response_model=CashFlowCreateResponse)
async def update(
    item_id: UUID, request: CashFlowReplace, service: CashFlowServiceDependency
) -> CashFlowCreateResponse:
    return await service.update(item_id, request)


@router.post("/cash-flow-items/{item_id}/confirm", response_model=CashFlowItemResponse)
async def confirm(
    item_id: UUID, request: CashFlowVersionRequest, service: CashFlowServiceDependency
) -> CashFlowItemResponse:
    return await service.confirm(item_id, request.expected_version)


@router.post("/cash-flow-items/{item_id}/cancel", response_model=CashFlowCreateResponse)
async def cancel(
    item_id: UUID, request: CashFlowVersionRequest, service: CashFlowServiceDependency
) -> CashFlowCreateResponse:
    return await service.cancel(item_id, request.expected_version, request.scope)


@router.post("/cash-flow-items/{item_id}/settle", response_model=CashFlowItemResponse)
async def settle(
    item_id: UUID,
    request: CashFlowSettlementDraft,
    service: CashFlowServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> CashFlowItemResponse:
    return await service.settle(item_id, request, idempotency_key)
