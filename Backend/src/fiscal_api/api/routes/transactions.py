from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response
from starlette import status

from fiscal_api.api.dependencies import (
    ActionPreviewServiceDependency,
    MerchantServiceDependency,
    TransactionHistoryServiceDependency,
    TransactionServiceDependency,
    formal_mutation,
)
from fiscal_api.api.p3_schemas import (
    TransactionDraft,
    TransactionPage,
    TransactionReplace,
    TransactionResponse,
    TransactionSummary,
    TransactionVersionRequest,
)
from fiscal_api.api.p10_schemas import (
    BatchCategoryRequest,
    BatchCategoryResponse,
    TransactionClassification,
)
from fiscal_api.api.p31_schemas import (
    MerchantMappingReceipt,
    MerchantMappingReleaseRequest,
    MerchantMappingRequest,
    MerchantMappingResponse,
    TransactionProvenanceResponse,
    TransactionRevisionPage,
)
from fiscal_api.api.p36_schemas import (
    ActionCommitReceipt,
    ActionCommitRequest,
    CategoryChangePreview,
    CategoryChangePreviewRequest,
    RepaymentPreview,
    RepaymentPreviewRequest,
)
from fiscal_api.core.security import require_authenticated
from fiscal_api.db.models import TransactionKind, TransactionSource

router = APIRouter(
    prefix="/transactions",
    tags=["transactions"],
    dependencies=[Depends(require_authenticated)],
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
    classification: TransactionClassification = TransactionClassification.ALL,
    source: TransactionSource | None = None,
    amount_min_minor: Annotated[int | None, Query(ge=1)] = None,
    amount_max_minor: Annotated[int | None, Query(ge=1)] = None,
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
        classification=classification,
        source=source,
        amount_min_minor=amount_min_minor,
        amount_max_minor=amount_max_minor,
    )


@router.post(
    "",
    response_model=TransactionResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[
        formal_mutation(
            "ledger",
            "accounts",
            "credit",
            "reimbursements",
            "cash_flow",
            "reports",
            "ai",
        )
    ],
)
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


@router.get("/export.csv", response_class=Response)
async def export_transactions_csv(
    service: TransactionServiceDependency,
    kind: TransactionKind | None = None,
    account_id: UUID | None = None,
    category_id: UUID | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    query: str | None = None,
    include_voided: bool = False,
    classification: TransactionClassification = TransactionClassification.ALL,
    source: TransactionSource | None = None,
    amount_min_minor: Annotated[int | None, Query(ge=1)] = None,
    amount_max_minor: Annotated[int | None, Query(ge=1)] = None,
) -> Response:
    body = await service.export_csv(
        kind=kind,
        account_id=account_id,
        category_id=category_id,
        date_from=date_from,
        date_to=date_to,
        query=query,
        include_voided=include_voided,
        classification=classification,
        source=source,
        amount_min_minor=amount_min_minor,
        amount_max_minor=amount_max_minor,
    )
    return Response(
        content=body,
        media_type="text/csv; charset=utf-8",
        # This is intentionally the legacy ledger export, not a P34 report.
        headers={
            "Content-Disposition": 'attachment; filename="fiscal-transactions-v1.csv"',
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.post(
    "/bulk-category",
    response_model=BatchCategoryResponse,
    dependencies=[formal_mutation("ledger", "reports", "ai")],
)
async def bulk_category_transactions(
    request: BatchCategoryRequest,
    service: TransactionServiceDependency,
) -> BatchCategoryResponse:
    return await service.bulk_category(request)


@router.post("/repayment-preview", response_model=RepaymentPreview)
async def preview_repayment(
    request: RepaymentPreviewRequest,
    service: ActionPreviewServiceDependency,
) -> RepaymentPreview:
    return await service.preview_repayment(request.draft)


@router.post(
    "/repayment-commit",
    response_model=ActionCommitReceipt,
    dependencies=[formal_mutation("ledger", "accounts", "credit", "reports")],
)
async def commit_repayment(
    request: ActionCommitRequest,
    service: ActionPreviewServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> ActionCommitReceipt:
    return await service.commit_repayment(request.preview_token, idempotency_key)


@router.post("/category-preview", response_model=CategoryChangePreview)
async def preview_category_change(
    request: CategoryChangePreviewRequest,
    service: ActionPreviewServiceDependency,
) -> CategoryChangePreview:
    return await service.preview_category(request)


@router.post(
    "/category-commit",
    response_model=ActionCommitReceipt,
    dependencies=[formal_mutation("ledger", "reports", "ai")],
)
async def commit_category_change(
    request: ActionCommitRequest,
    service: ActionPreviewServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> ActionCommitReceipt:
    return await service.commit_category(request.preview_token, idempotency_key)


@router.get("/{transaction_id}/merchant-mapping", response_model=MerchantMappingResponse | None)
async def transaction_merchant_mapping(
    transaction_id: UUID,
    service: MerchantServiceDependency,
) -> MerchantMappingResponse | None:
    return await service.mapping(transaction_id)


@router.put(
    "/{transaction_id}/merchant-mapping",
    response_model=MerchantMappingReceipt,
    dependencies=[formal_mutation("reports")],
)
async def confirm_transaction_merchant_mapping(
    transaction_id: UUID,
    request: MerchantMappingRequest,
    service: MerchantServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> MerchantMappingReceipt:
    return await service.confirm_mapping(transaction_id, request, idempotency_key)


@router.delete(
    "/{transaction_id}/merchant-mapping",
    response_model=MerchantMappingReceipt,
    dependencies=[formal_mutation("reports")],
)
async def release_transaction_merchant_mapping(
    transaction_id: UUID,
    request: MerchantMappingReleaseRequest,
    service: MerchantServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> MerchantMappingReceipt:
    return await service.release_mapping(
        transaction_id,
        request.expected_mapping_version,
        idempotency_key,
    )


@router.get("/{transaction_id}/revisions", response_model=TransactionRevisionPage)
async def transaction_revisions(
    transaction_id: UUID,
    service: TransactionHistoryServiceDependency,
    cursor: Annotated[int | None, Query(ge=1)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 30,
) -> TransactionRevisionPage:
    return await service.revisions(transaction_id, cursor=cursor, limit=limit)


@router.get("/{transaction_id}/provenance", response_model=TransactionProvenanceResponse)
async def transaction_provenance(
    transaction_id: UUID,
    service: TransactionHistoryServiceDependency,
) -> TransactionProvenanceResponse:
    return await service.provenance(transaction_id)


@router.get("/{transaction_id}", response_model=TransactionResponse)
async def get_transaction(
    transaction_id: UUID,
    service: TransactionServiceDependency,
) -> TransactionResponse:
    return await service.get(transaction_id)


@router.put(
    "/{transaction_id}",
    response_model=TransactionResponse,
    dependencies=[
        formal_mutation(
            "ledger",
            "accounts",
            "credit",
            "reimbursements",
            "cash_flow",
            "reports",
            "ai",
        )
    ],
)
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


@router.post(
    "/{transaction_id}/void",
    response_model=TransactionResponse,
    dependencies=[
        formal_mutation(
            "ledger",
            "accounts",
            "credit",
            "reimbursements",
            "cash_flow",
            "reports",
            "ai",
        )
    ],
)
async def void_transaction(
    transaction_id: UUID,
    request: TransactionVersionRequest,
    service: TransactionServiceDependency,
) -> TransactionResponse:
    return await service.void(transaction_id, request.expected_version)


@router.post(
    "/{transaction_id}/restore",
    response_model=TransactionResponse,
    dependencies=[
        formal_mutation(
            "ledger",
            "accounts",
            "credit",
            "reimbursements",
            "cash_flow",
            "reports",
            "ai",
        )
    ],
)
async def restore_transaction(
    transaction_id: UUID,
    request: TransactionVersionRequest,
    service: TransactionServiceDependency,
) -> TransactionResponse:
    return await service.restore(transaction_id, request.expected_version)
