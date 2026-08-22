from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response
from starlette import status

from fiscal_api.api.dependencies import CategoryServiceDependency, formal_mutation
from fiscal_api.api.p2_schemas import (
    CategoryDraft,
    CategoryMergeRequest,
    CategoryOrderRequest,
    CategoryOrderState,
    CategoryPatch,
    CategoryResponse,
    CategorySplitRequest,
    VersionRequest,
)
from fiscal_api.api.p31_schemas import (
    CategoryMergeCommitRequest,
    CategoryMergePreview,
    CategoryMergePreviewRequest,
    CategorySplitCommitRequest,
    CategorySplitPreview,
    CategorySplitPreviewRequest,
    CategoryTransformReceipt,
)
from fiscal_api.core.security import require_authenticated
from fiscal_api.db.models import CategoryDirection

router = APIRouter(
    prefix="/categories",
    tags=["categories"],
    dependencies=[Depends(require_authenticated)],
)


@router.get("", response_model=list[CategoryResponse])
async def list_categories(
    service: CategoryServiceDependency,
    direction: CategoryDirection | None = None,
    include_archived: bool = False,
) -> list[CategoryResponse]:
    return await service.list(direction=direction, include_archived=include_archived)


@router.post(
    "",
    response_model=CategoryResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[formal_mutation("ledger", "reports", "attention", "ai")],
)
async def create_category(
    draft: CategoryDraft,
    service: CategoryServiceDependency,
) -> CategoryResponse:
    return await service.create(draft)


@router.put(
    "/order",
    response_model=list[CategoryResponse],
    dependencies=[formal_mutation("ledger", "reports", "attention", "ai")],
)
async def order_categories(
    request: CategoryOrderRequest,
    service: CategoryServiceDependency,
) -> list[CategoryResponse]:
    return await service.reorder(
        parent_id=request.parent_id,
        ordered_ids=request.ordered_ids,
        expected_list_revision=request.expected_list_revision,
    )


@router.get("/order-state", response_model=CategoryOrderState)
async def category_order_state(
    service: CategoryServiceDependency,
    direction: CategoryDirection,
    parent_id: UUID | None = None,
) -> CategoryOrderState:
    return await service.order_state(parent_id=parent_id, direction=direction)


@router.get("/{category_id}", response_model=CategoryResponse)
async def get_category(
    category_id: UUID,
    service: CategoryServiceDependency,
) -> CategoryResponse:
    return await service.get(category_id)


@router.patch(
    "/{category_id}",
    response_model=CategoryResponse,
    dependencies=[formal_mutation("ledger", "reports", "attention", "ai")],
)
async def update_category(
    category_id: UUID,
    patch: CategoryPatch,
    service: CategoryServiceDependency,
) -> CategoryResponse:
    return await service.update(category_id, patch)


@router.delete(
    "/{category_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[formal_mutation("ledger", "reports", "attention", "ai")],
)
async def delete_category(
    category_id: UUID,
    service: CategoryServiceDependency,
    expected_version: Annotated[int, Query(ge=1)],
) -> Response:
    await service.delete(category_id, expected_version)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/{category_id}/archive",
    response_model=CategoryResponse,
    dependencies=[formal_mutation("ledger", "reports", "attention", "ai")],
)
async def archive_category(
    category_id: UUID,
    request: VersionRequest,
    service: CategoryServiceDependency,
) -> CategoryResponse:
    return await service.archive(category_id, request.expected_version)


@router.post(
    "/{category_id}/restore",
    response_model=CategoryResponse,
    dependencies=[formal_mutation("ledger", "reports", "attention", "ai")],
)
async def restore_category(
    category_id: UUID,
    request: VersionRequest,
    service: CategoryServiceDependency,
) -> CategoryResponse:
    return await service.restore(category_id, request.expected_version)


@router.post(
    "/{source_id}/merge",
    response_model=CategoryResponse,
    dependencies=[formal_mutation("ledger", "reports", "attention", "ai")],
)
async def merge_category(
    source_id: UUID,
    request: CategoryMergeRequest,
    service: CategoryServiceDependency,
) -> CategoryResponse:
    return await service.merge(
        source_id=source_id,
        target_id=request.target_id,
        source_expected_version=request.source_expected_version,
        target_expected_version=request.target_expected_version,
    )


@router.post(
    "/{root_id}/split",
    response_model=list[CategoryResponse],
    dependencies=[formal_mutation("ledger", "reports", "attention", "ai")],
)
async def split_category(
    root_id: UUID,
    request: CategorySplitRequest,
    service: CategoryServiceDependency,
) -> list[CategoryResponse]:
    return await service.split(
        root_id=root_id,
        root_expected_version=request.root_expected_version,
        drafts=request.children,
    )


@router.post("/{source_id}/merge-preview", response_model=CategoryMergePreview)
async def preview_category_merge(
    source_id: UUID,
    request: CategoryMergePreviewRequest,
    service: CategoryServiceDependency,
) -> CategoryMergePreview:
    return await service.merge_preview(source_id, request)


@router.post(
    "/{source_id}/merge-commit",
    response_model=CategoryTransformReceipt,
    dependencies=[formal_mutation("ledger", "reports", "attention", "ai")],
)
async def commit_category_merge(
    source_id: UUID,
    request: CategoryMergeCommitRequest,
    service: CategoryServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> CategoryTransformReceipt:
    return await service.merge_commit(source_id, request, idempotency_key)


@router.post("/{root_id}/split-preview", response_model=CategorySplitPreview)
async def preview_category_split(
    root_id: UUID,
    request: CategorySplitPreviewRequest,
    service: CategoryServiceDependency,
) -> CategorySplitPreview:
    return await service.split_preview(root_id, request)


@router.post(
    "/{root_id}/split-commit",
    response_model=CategoryTransformReceipt,
    dependencies=[formal_mutation("ledger", "reports", "attention", "ai")],
)
async def commit_category_split(
    root_id: UUID,
    request: CategorySplitCommitRequest,
    service: CategoryServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> CategoryTransformReceipt:
    return await service.split_commit(root_id, request, idempotency_key)
