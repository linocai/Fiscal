from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query
from starlette import status

from fiscal_api.api.dependencies import TransactionServiceDependency
from fiscal_api.api.p3_schemas import (
    TransactionDraft,
    TransactionPage,
    TransactionReplace,
    TransactionResponse,
    TransactionSummary,
    TransactionVersionRequest,
)
from fiscal_api.core.security import require_device_token
from fiscal_api.db.models import TransactionKind

router = APIRouter(
    prefix="/transactions",
    tags=["transactions"],
    dependencies=[Depends(require_device_token)],
)


@router.get("", response_model=TransactionPage)
async def list_transactions(
    service: TransactionServiceDependency,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    kind: TransactionKind | None = None,
    account_id: UUID | None = None,
    category_id: UUID | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    query: str | None = None,
    include_voided: bool = False,
) -> TransactionPage:
    return await service.list(
        cursor=cursor,
        limit=limit,
        kind=kind,
        account_id=account_id,
        category_id=category_id,
        date_from=date_from,
        date_to=date_to,
        query=query,
        include_voided=include_voided,
    )


@router.post("", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED)
async def create_transaction(
    draft: TransactionDraft,
    service: TransactionServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> TransactionResponse:
    return await service.create(draft, idempotency_key)


@router.get("/summary", response_model=TransactionSummary)
async def transaction_summary(
    service: TransactionServiceDependency,
    date_from: date | None = None,
    date_to: date | None = None,
) -> TransactionSummary:
    return await service.summary(date_from=date_from, date_to=date_to)


@router.get("/{transaction_id}", response_model=TransactionResponse)
async def get_transaction(
    transaction_id: UUID,
    service: TransactionServiceDependency,
) -> TransactionResponse:
    return await service.get(transaction_id)


@router.put("/{transaction_id}", response_model=TransactionResponse)
async def update_transaction(
    transaction_id: UUID,
    replacement: TransactionReplace,
    service: TransactionServiceDependency,
) -> TransactionResponse:
    draft = TransactionDraft.model_validate(replacement.model_dump(exclude={"expected_version"}))
    return await service.update(
        transaction_id,
        draft,
        replacement.expected_version,
    )


@router.post("/{transaction_id}/void", response_model=TransactionResponse)
async def void_transaction(
    transaction_id: UUID,
    request: TransactionVersionRequest,
    service: TransactionServiceDependency,
) -> TransactionResponse:
    return await service.void(transaction_id, request.expected_version)


@router.post("/{transaction_id}/restore", response_model=TransactionResponse)
async def restore_transaction(
    transaction_id: UUID,
    request: TransactionVersionRequest,
    service: TransactionServiceDependency,
) -> TransactionResponse:
    return await service.restore(transaction_id, request.expected_version)
