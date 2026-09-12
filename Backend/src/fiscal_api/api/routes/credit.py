from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query

from fiscal_api.api.dependencies import (
    CreditPayoffServiceDependency,
    CreditServiceDependency,
    TransactionServiceDependency,
    formal_mutation,
)
from fiscal_api.api.p3_schemas import TransactionPage
from fiscal_api.api.p4_schemas import (
    CreditAccountSummary,
    CreditCyclePage,
    CreditCycleResponse,
    CreditScheduleChangeCommitRequest,
    CreditScheduleChangeRequest,
    CreditScheduleChangeResult,
)
from fiscal_api.api.p40_schemas import (
    CreditPayoffCommitRequest,
    CreditPayoffPreview,
    CreditPayoffReceipt,
    CreditPayoffRequest,
    CreditPayoffReversePreview,
    CreditPayoffReverseRequest,
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
    dependencies=[formal_mutation("accounts", "credit", "cash_flow", "reports")],
)
async def apply_credit_schedule_change(
    account_id: UUID,
    request: CreditScheduleChangeCommitRequest,
    service: CreditServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> CreditScheduleChangeResult:
    return await service.commit_schedule_change(account_id, request, idempotency_key)


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


@router.post("/credit-accounts/{account_id}/payoff-preview", response_model=CreditPayoffPreview)
async def payoff_preview(
    account_id: UUID, request: CreditPayoffRequest, service: CreditPayoffServiceDependency
) -> CreditPayoffPreview:
    return await service.preview(account_id, request)


@router.post(
    "/credit-accounts/{account_id}/payoff",
    response_model=CreditPayoffReceipt,
    dependencies=[formal_mutation("ledger", "credit")],
)
async def payoff_commit(
    account_id: UUID,
    request: CreditPayoffCommitRequest,
    service: CreditPayoffServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> CreditPayoffReceipt:
    return await service.commit(account_id, request, idempotency_key)


@router.get("/credit-payoffs/{operation_id}", response_model=CreditPayoffReceipt)
async def payoff_receipt(
    operation_id: UUID, service: CreditPayoffServiceDependency
) -> CreditPayoffReceipt:
    return await service.get(operation_id)


@router.post(
    "/credit-payoffs/{operation_id}/reverse-preview", response_model=CreditPayoffReversePreview
)
async def payoff_reverse_preview(
    operation_id: UUID, service: CreditPayoffServiceDependency
) -> CreditPayoffReversePreview:
    return await service.reverse_preview(operation_id)


@router.post(
    "/credit-payoffs/{operation_id}/reverse",
    response_model=CreditPayoffReceipt,
    dependencies=[formal_mutation("ledger", "credit")],
)
async def payoff_reverse(
    operation_id: UUID,
    request: CreditPayoffReverseRequest,
    service: CreditPayoffServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> CreditPayoffReceipt:
    return await service.reverse(operation_id, request, idempotency_key)


@router.get("/credit-accounts/{account_id}/payoffs", response_model=list[CreditPayoffReceipt])
async def list_payoffs(
    account_id: UUID, service: CreditPayoffServiceDependency
) -> list[CreditPayoffReceipt]:
    return await service.list(account_id)
