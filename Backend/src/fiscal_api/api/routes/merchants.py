from uuid import UUID

from fastapi import APIRouter, Depends, Query, status

from fiscal_api.api.dependencies import MerchantServiceDependency, formal_mutation
from fiscal_api.api.p31_schemas import (
    MerchantDraft,
    MerchantPage,
    MerchantPatch,
    MerchantResponse,
)
from fiscal_api.core.security import require_authenticated

router = APIRouter(
    prefix="/merchants",
    tags=["merchants"],
    dependencies=[Depends(require_authenticated)],
)


@router.get("", response_model=MerchantPage)
async def list_merchants(
    service: MerchantServiceDependency,
    include_archived: bool = False,
    query: str | None = Query(default=None, max_length=120),
    limit: int = Query(default=30, ge=1, le=100),
    cursor: str | None = Query(default=None, max_length=2048),
) -> MerchantPage:
    return await service.list(
        include_archived=include_archived, query=query, limit=limit, cursor=cursor
    )


@router.post(
    "",
    response_model=MerchantResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[formal_mutation("reports", "attention")],
)
async def create_merchant(
    draft: MerchantDraft, service: MerchantServiceDependency
) -> MerchantResponse:
    return await service.create(draft)


@router.get("/{merchant_id}", response_model=MerchantResponse)
async def get_merchant(merchant_id: UUID, service: MerchantServiceDependency) -> MerchantResponse:
    return await service.get(merchant_id)


@router.patch(
    "/{merchant_id}",
    response_model=MerchantResponse,
    dependencies=[formal_mutation("reports", "attention")],
)
async def update_merchant(
    merchant_id: UUID,
    patch: MerchantPatch,
    service: MerchantServiceDependency,
) -> MerchantResponse:
    return await service.update(merchant_id, patch)
