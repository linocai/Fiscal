from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query
from starlette import status as http_status

from fiscal_api.api.dependencies import InstallmentServiceDependency
from fiscal_api.api.p5_schemas import (
    InstallmentActionRequest,
    InstallmentCancellationPreview,
    InstallmentCancellationResult,
    InstallmentCreate,
    InstallmentCycleOption,
    InstallmentEligibility,
    InstallmentLiabilities,
    InstallmentPlanChangePreview,
    InstallmentPlanPage,
    InstallmentPlanResponse,
    InstallmentPlanStatus,
    InstallmentReplacement,
    InstallmentReverseSettlementPreview,
    InstallmentReverseSettlementResult,
    InstallmentSettlementPreview,
    InstallmentSettlementRequest,
    InstallmentSettlementResult,
)
from fiscal_api.core.security import require_device_token

router = APIRouter(tags=["installments"], dependencies=[Depends(require_device_token)])


@router.get("/installment-plans", response_model=InstallmentPlanPage)
async def list_installment_plans(
    service: InstallmentServiceDependency,
    account_id: UUID | None = None,
    status: InstallmentPlanStatus | None = None,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
) -> InstallmentPlanPage:
    return await service.list(account_id=account_id, status=status, cursor=cursor, limit=limit)


@router.post(
    "/installment-plans",
    response_model=InstallmentPlanResponse,
    status_code=http_status.HTTP_201_CREATED,
)
async def create_installment_plan(
    request: InstallmentCreate,
    service: InstallmentServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> InstallmentPlanResponse:
    return await service.create(request, idempotency_key)


@router.get("/installment-plans/{plan_id}", response_model=InstallmentPlanResponse)
async def get_installment_plan(
    plan_id: UUID, service: InstallmentServiceDependency
) -> InstallmentPlanResponse:
    return await service.get(plan_id)


@router.post(
    "/installment-plans/{plan_id}/preview",
    response_model=InstallmentPlanChangePreview,
)
async def preview_installment_plan(
    plan_id: UUID,
    request: InstallmentReplacement,
    service: InstallmentServiceDependency,
) -> InstallmentPlanChangePreview:
    return await service.preview_update(plan_id, request)


@router.put("/installment-plans/{plan_id}", response_model=InstallmentPlanResponse)
async def update_installment_plan(
    plan_id: UUID,
    request: InstallmentReplacement,
    service: InstallmentServiceDependency,
) -> InstallmentPlanResponse:
    return await service.update(plan_id, request)


@router.post(
    "/installment-plans/{plan_id}/settlement-preview",
    response_model=InstallmentSettlementPreview,
)
async def preview_installment_settlement(
    plan_id: UUID,
    request: InstallmentSettlementRequest,
    service: InstallmentServiceDependency,
) -> InstallmentSettlementPreview:
    return await service.settlement_preview(plan_id, request)


@router.post(
    "/installment-plans/{plan_id}/reverse-settlement-preview",
    response_model=InstallmentReverseSettlementPreview,
)
async def preview_reverse_installment_settlement(
    plan_id: UUID,
    request: InstallmentActionRequest,
    service: InstallmentServiceDependency,
) -> InstallmentReverseSettlementPreview:
    return await service.reverse_settlement_preview(plan_id, request)


@router.post(
    "/installment-plans/{plan_id}/cancel-preview",
    response_model=InstallmentCancellationPreview,
)
async def preview_cancel_installment_future(
    plan_id: UUID,
    request: InstallmentActionRequest,
    service: InstallmentServiceDependency,
) -> InstallmentCancellationPreview:
    return await service.cancellation_preview(plan_id, request)


@router.post(
    "/installment-plans/{plan_id}/settle-early",
    response_model=InstallmentSettlementResult,
)
async def settle_installment_plan(
    plan_id: UUID,
    request: InstallmentSettlementRequest,
    service: InstallmentServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> InstallmentSettlementResult:
    return await service.settle_early(plan_id, request, idempotency_key)


@router.post(
    "/installment-plans/{plan_id}/cancel-future",
    response_model=InstallmentCancellationResult,
)
async def cancel_installment_future(
    plan_id: UUID,
    request: InstallmentActionRequest,
    service: InstallmentServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> InstallmentCancellationResult:
    return await service.cancel_future(plan_id, request, idempotency_key)


@router.post(
    "/installment-plans/{plan_id}/reverse-settlement",
    response_model=InstallmentReverseSettlementResult,
)
async def reverse_installment_settlement(
    plan_id: UUID,
    request: InstallmentActionRequest,
    service: InstallmentServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> InstallmentReverseSettlementResult:
    return await service.reverse_settlement(plan_id, request, idempotency_key)


@router.get(
    "/transactions/{transaction_id}/installment-eligibility",
    response_model=InstallmentEligibility,
)
async def installment_eligibility(
    transaction_id: UUID, service: InstallmentServiceDependency
) -> InstallmentEligibility:
    return await service.eligibility(transaction_id)


@router.get("/installment-cycle-options", response_model=list[InstallmentCycleOption])
async def installment_cycle_options(
    service: InstallmentServiceDependency,
    purchase_transaction_id: UUID,
    months: Annotated[int, Query(ge=1, le=60)] = 60,
) -> list[InstallmentCycleOption]:
    return await service.options(purchase_transaction_id, months)


@router.get("/installment-liabilities", response_model=InstallmentLiabilities)
async def installment_liabilities(
    account_id: UUID, service: InstallmentServiceDependency
) -> InstallmentLiabilities:
    return await service.liabilities(account_id)
