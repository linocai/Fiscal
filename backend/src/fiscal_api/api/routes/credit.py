from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query

from fiscal_api.api.dependencies import CreditServiceDependency, TransactionServiceDependency
from fiscal_api.api.p3_schemas import TransactionPage
from fiscal_api.api.p4_schemas import (
    CreditAccountSummary,
    CreditCyclePage,
    CreditCycleResponse,
    CreditScheduleChangeRequest,
    CreditScheduleChangeResult,
)
from fiscal_api.core.security import require_authenticated

router = APIRouter(
    tags=["credit"],
    dependencies=[Depends(require_authenticated)],
)


@router.get("/credit-accounts", response_model=list[CreditAccountSummary])
async def list_credit_accounts(service: CreditServiceDependency) -> list[CreditAccountSummary]:
    return await service.list_accounts()


@router.get("/credit-accounts/{account_id}", response_model=CreditAccountSummary)
async def get_credit_account(
    account_id: UUID, service: CreditServiceDependency
) -> CreditAccountSummary:
    return await service.get_account(account_id)


@router.post(
    "/credit-accounts/{account_id}/schedule-change-preview",
    response_model=CreditScheduleChangeResult,
)
async def preview_credit_schedule_change(
    account_id: UUID,
    request: CreditScheduleChangeRequest,
    service: CreditServiceDependency,
) -> CreditScheduleChangeResult:
    return await service.preview_schedule_change(account_id, request)


@router.post(
    "/credit-accounts/{account_id}/schedule-change",
    response_model=CreditScheduleChangeResult,
)
async def apply_credit_schedule_change(
    account_id: UUID,
    request: CreditScheduleChangeRequest,
    service: CreditServiceDependency,
) -> CreditScheduleChangeResult:
    return await service.apply_schedule_change(account_id, request)


@router.get("/credit-accounts/{account_id}/cycles", response_model=CreditCyclePage)
async def list_credit_cycles(
    account_id: UUID,
    service: CreditServiceDependency,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
) -> CreditCyclePage:
    return await service.list_cycles(account_id, cursor=cursor, limit=limit)


@router.get("/credit-cycles/{cycle_id}", response_model=CreditCycleResponse)
async def get_credit_cycle(cycle_id: UUID, service: CreditServiceDependency) -> CreditCycleResponse:
    return await service.get_cycle(cycle_id)


@router.get("/credit-cycles/{cycle_id}/transactions", response_model=TransactionPage)
async def list_credit_cycle_transactions(
    cycle_id: UUID,
    credit_service: CreditServiceDependency,
    transaction_service: TransactionServiceDependency,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> TransactionPage:
    await credit_service.get_cycle(cycle_id)
    return await transaction_service.list_cycle(cycle_id, cursor=cursor, limit=limit)
