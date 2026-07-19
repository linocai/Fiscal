from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response
from starlette import status

from fiscal_api.api.dependencies import AccountServiceDependency
from fiscal_api.api.p2_schemas import (
    AccountDraft,
    AccountOrderRequest,
    AccountPatch,
    AccountResponse,
    VersionRequest,
)
from fiscal_api.core.security import require_authenticated

router = APIRouter(
    prefix="/accounts",
    tags=["accounts"],
    dependencies=[Depends(require_authenticated)],
)


@router.get("", response_model=list[AccountResponse])
async def list_accounts(
    service: AccountServiceDependency,
    include_archived: bool = False,
) -> list[AccountResponse]:
    return await service.list(include_archived=include_archived)


@router.post("", response_model=AccountResponse, status_code=status.HTTP_201_CREATED)
async def create_account(
    draft: AccountDraft,
    service: AccountServiceDependency,
) -> AccountResponse:
    return await service.create(draft)


@router.put("/order", response_model=list[AccountResponse])
async def order_accounts(
    request: AccountOrderRequest,
    service: AccountServiceDependency,
) -> list[AccountResponse]:
    return await service.reorder(request.ordered_ids)


@router.get("/{account_id}", response_model=AccountResponse)
async def get_account(
    account_id: UUID,
    service: AccountServiceDependency,
) -> AccountResponse:
    return await service.get(account_id)


@router.patch("/{account_id}", response_model=AccountResponse)
async def update_account(
    account_id: UUID,
    patch: AccountPatch,
    service: AccountServiceDependency,
) -> AccountResponse:
    return await service.update(account_id, patch)


@router.delete("/{account_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_account(
    account_id: UUID,
    service: AccountServiceDependency,
    expected_version: Annotated[int, Query(ge=1)],
) -> Response:
    await service.delete(account_id, expected_version)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{account_id}/archive", response_model=AccountResponse)
async def archive_account(
    account_id: UUID,
    request: VersionRequest,
    service: AccountServiceDependency,
) -> AccountResponse:
    return await service.archive(account_id, request.expected_version)


@router.post("/{account_id}/restore", response_model=AccountResponse)
async def restore_account(
    account_id: UUID,
    request: VersionRequest,
    service: AccountServiceDependency,
) -> AccountResponse:
    return await service.restore(account_id, request.expected_version)
