from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response
from starlette import status as http_status

from fiscal_api.api.dependencies import ImportBatchServiceDependency, formal_mutation
from fiscal_api.api.import_batch_schemas import (
    ImportBatchCommitRequest,
    ImportBatchCreate,
    ImportBatchIgnoreRequest,
    ImportBatchPage,
    ImportBatchResponse,
    ImportBatchVersionRequest,
)
from fiscal_api.core.security import require_authenticated
from fiscal_api.db.models import ImportBatchStatus

router = APIRouter(
    prefix="/import-batches",
    tags=["import-batches"],
    dependencies=[Depends(require_authenticated)],
)


@router.post(
    "",
    response_model=ImportBatchResponse,
    status_code=http_status.HTTP_201_CREATED,
    dependencies=[formal_mutation("ai", "ledger", "accounts", "reports")],
)
async def create_import_batch(
    request: ImportBatchCreate,
    response: Response,
    service: ImportBatchServiceDependency,
) -> ImportBatchResponse:
    batch, replay = await service.create(request)
    if replay:
        response.status_code = http_status.HTTP_200_OK
    return batch


@router.get("", response_model=ImportBatchPage)
async def list_import_batches(
    service: ImportBatchServiceDependency,
    status: ImportBatchStatus | None = None,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> ImportBatchPage:
    return await service.list(status=status, cursor=cursor, limit=limit)


@router.get("/{batch_id}", response_model=ImportBatchResponse)
async def get_import_batch(
    batch_id: UUID, service: ImportBatchServiceDependency
) -> ImportBatchResponse:
    return await service.get(batch_id)


@router.post(
    "/{batch_id}/validate",
    response_model=ImportBatchResponse,
    dependencies=[formal_mutation("ai", "ledger", "accounts", "reports")],
)
async def validate_import_batch(
    batch_id: UUID,
    request: ImportBatchVersionRequest,
    service: ImportBatchServiceDependency,
) -> ImportBatchResponse:
    return await service.validate(batch_id, request)


@router.post(
    "/{batch_id}/commit",
    response_model=ImportBatchResponse,
    dependencies=[formal_mutation("ai", "ledger", "accounts", "reports")],
)
async def commit_import_batch(
    batch_id: UUID,
    request: ImportBatchCommitRequest,
    service: ImportBatchServiceDependency,
) -> ImportBatchResponse:
    return await service.commit(batch_id, request)


@router.post(
    "/{batch_id}/ignore",
    response_model=ImportBatchResponse,
    dependencies=[formal_mutation("ai")],
)
async def ignore_import_batch(
    batch_id: UUID,
    request: ImportBatchIgnoreRequest,
    service: ImportBatchServiceDependency,
) -> ImportBatchResponse:
    return await service.ignore(batch_id, request)
