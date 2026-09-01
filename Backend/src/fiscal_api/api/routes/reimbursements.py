from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query
from starlette import status as http_status

from fiscal_api.api.dependencies import ReimbursementServiceDependency, formal_mutation
from fiscal_api.api.p6_schemas import (
    ReimbursementCancelCommit,
    ReimbursementCancelPreview,
    ReimbursementClaimCommit,
    ReimbursementClaimDraft,
    ReimbursementClaimPage,
    ReimbursementClaimPreview,
    ReimbursementClaimReplace,
    ReimbursementClaimResponse,
    ReimbursementEligibility,
    ReimbursementExpenseCandidatePage,
    ReimbursementExpenseOption,
    ReimbursementReceiptAccountOptions,
    ReimbursementReceiptCreateCommit,
    ReimbursementReceiptDraft,
    ReimbursementReceiptPage,
    ReimbursementReceiptPreview,
    ReimbursementReceiptReplace,
    ReimbursementReceiptReplaceCommit,
    ReimbursementReceiptResponse,
    ReimbursementReceiptVersionRequest,
    ReimbursementSummary,
    ReimbursementVersionRequest,
)
from fiscal_api.core.security import require_authenticated
from fiscal_api.db.models import ReimbursementClaimStatus

router = APIRouter(tags=["reimbursements"], dependencies=[Depends(require_authenticated)])


@router.get("/reimbursement-claims", response_model=ReimbursementClaimPage)
async def list_claims(
    service: ReimbursementServiceDependency,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
    status: ReimbursementClaimStatus | None = None,
    query: str | None = None,
    expense_transaction_id: UUID | None = None,
    include_archived: bool = False,
    include_voided: bool = False,
) -> ReimbursementClaimPage:
    return await service.list(
        cursor=cursor,
        limit=limit,
        status=status,
        query=query,
        expense_transaction_id=expense_transaction_id,
        include_archived=include_archived,
        include_voided=include_voided,
    )


@router.post(
    "/reimbursement-claims",
    response_model=ReimbursementClaimResponse,
    status_code=http_status.HTTP_201_CREATED,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def create_claim(
    request: ReimbursementClaimDraft,
    service: ReimbursementServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> ReimbursementClaimResponse:
    return await service.create(request, idempotency_key)


@router.get("/reimbursement-claims/{claim_id}", response_model=ReimbursementClaimResponse)
async def get_claim(
    claim_id: UUID, service: ReimbursementServiceDependency
) -> ReimbursementClaimResponse:
    return await service.get(claim_id)


@router.post("/reimbursement-claims/{claim_id}/preview", response_model=ReimbursementClaimPreview)
async def preview_claim(
    claim_id: UUID, request: ReimbursementClaimReplace, service: ReimbursementServiceDependency
) -> ReimbursementClaimPreview:
    return await service.preview(claim_id, request)


@router.put(
    "/reimbursement-claims/{claim_id}",
    response_model=ReimbursementClaimResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def replace_claim(
    claim_id: UUID,
    request: ReimbursementClaimCommit,
    service: ReimbursementServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> ReimbursementClaimResponse:
    return await service.update(
        claim_id, request, preview_token=request.preview_token, idempotency_key=idempotency_key
    )


async def _claim_action(
    claim_id: UUID,
    request: ReimbursementVersionRequest,
    service: ReimbursementServiceDependency,
    action: str,
) -> ReimbursementClaimResponse:
    return await service.lifecycle(claim_id, request.expected_version, action)


@router.post(
    "/reimbursement-claims/{claim_id}/submit",
    response_model=ReimbursementClaimResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def submit(
    claim_id: UUID, request: ReimbursementVersionRequest, service: ReimbursementServiceDependency
) -> ReimbursementClaimResponse:
    return await _claim_action(claim_id, request, service, "submit")


@router.post(
    "/reimbursement-claims/{claim_id}/retract-submission",
    response_model=ReimbursementClaimResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def retract(
    claim_id: UUID, request: ReimbursementVersionRequest, service: ReimbursementServiceDependency
) -> ReimbursementClaimResponse:
    return await _claim_action(claim_id, request, service, "retract_submission")


@router.post(
    "/reimbursement-claims/{claim_id}/cancel-preview", response_model=ReimbursementCancelPreview
)
async def cancel_preview(
    claim_id: UUID, request: ReimbursementVersionRequest, service: ReimbursementServiceDependency
) -> ReimbursementCancelPreview:
    return await service.cancel_preview(claim_id, request.expected_version)


@router.post(
    "/reimbursement-claims/{claim_id}/cancel-outstanding",
    response_model=ReimbursementClaimResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def cancel(
    claim_id: UUID,
    request: ReimbursementCancelCommit,
    service: ReimbursementServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> ReimbursementClaimResponse:
    return await service.lifecycle(
        claim_id,
        request.expected_version,
        "cancel_outstanding",
        preview_token=request.preview_token,
        idempotency_key=idempotency_key,
    )


@router.post(
    "/reimbursement-claims/{claim_id}/reopen",
    response_model=ReimbursementClaimResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def reopen(
    claim_id: UUID, request: ReimbursementVersionRequest, service: ReimbursementServiceDependency
) -> ReimbursementClaimResponse:
    return await _claim_action(claim_id, request, service, "reopen")


@router.post(
    "/reimbursement-claims/{claim_id}/void",
    response_model=ReimbursementClaimResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def void(
    claim_id: UUID, request: ReimbursementVersionRequest, service: ReimbursementServiceDependency
) -> ReimbursementClaimResponse:
    return await _claim_action(claim_id, request, service, "void")


@router.post(
    "/reimbursement-claims/{claim_id}/restore",
    response_model=ReimbursementClaimResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def restore(
    claim_id: UUID, request: ReimbursementVersionRequest, service: ReimbursementServiceDependency
) -> ReimbursementClaimResponse:
    return await _claim_action(claim_id, request, service, "restore")


@router.post(
    "/reimbursement-claims/{claim_id}/archive",
    response_model=ReimbursementClaimResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def archive(
    claim_id: UUID, request: ReimbursementVersionRequest, service: ReimbursementServiceDependency
) -> ReimbursementClaimResponse:
    return await _claim_action(claim_id, request, service, "archive")


@router.post(
    "/reimbursement-claims/{claim_id}/unarchive",
    response_model=ReimbursementClaimResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def unarchive(
    claim_id: UUID, request: ReimbursementVersionRequest, service: ReimbursementServiceDependency
) -> ReimbursementClaimResponse:
    return await _claim_action(claim_id, request, service, "unarchive")


@router.get("/reimbursement-claims/{claim_id}/receipts", response_model=ReimbursementReceiptPage)
async def list_receipts(
    claim_id: UUID,
    service: ReimbursementServiceDependency,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
) -> ReimbursementReceiptPage:
    return await service.receipts(claim_id, cursor=cursor, limit=limit)


@router.post(
    "/reimbursement-claims/{claim_id}/receipts",
    response_model=ReimbursementReceiptResponse,
    status_code=http_status.HTTP_201_CREATED,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def create_receipt(
    claim_id: UUID,
    request: ReimbursementReceiptCreateCommit,
    service: ReimbursementServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> ReimbursementReceiptResponse:
    return await service.create_receipt(
        claim_id, request, idempotency_key, preview_token=request.preview_token
    )


@router.post(
    "/reimbursement-claims/{claim_id}/receipt-preview", response_model=ReimbursementReceiptPreview
)
async def receipt_preview(
    claim_id: UUID, request: ReimbursementReceiptDraft, service: ReimbursementServiceDependency
) -> ReimbursementReceiptPreview:
    return await service.receipt_preview(claim_id, request)


@router.get("/reimbursement-receipts/{receipt_id}", response_model=ReimbursementReceiptResponse)
async def get_receipt(
    receipt_id: UUID, service: ReimbursementServiceDependency
) -> ReimbursementReceiptResponse:
    return await service.receipt_get(receipt_id)


@router.post(
    "/reimbursement-receipts/{receipt_id}/preview", response_model=ReimbursementReceiptPreview
)
async def replace_receipt_preview(
    receipt_id: UUID, request: ReimbursementReceiptReplace, service: ReimbursementServiceDependency
) -> ReimbursementReceiptPreview:
    claim_id = await service.receipt_claim_id(receipt_id)
    return await service.receipt_preview(claim_id, request, exclude_receipt=receipt_id)


@router.put(
    "/reimbursement-receipts/{receipt_id}",
    response_model=ReimbursementReceiptResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def replace_receipt(
    receipt_id: UUID,
    request: ReimbursementReceiptReplaceCommit,
    service: ReimbursementServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> ReimbursementReceiptResponse:
    return await service.replace_receipt(
        receipt_id, request, preview_token=request.preview_token, idempotency_key=idempotency_key
    )


@router.post(
    "/reimbursement-receipts/{receipt_id}/void",
    response_model=ReimbursementReceiptResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def void_receipt(
    receipt_id: UUID,
    request: ReimbursementReceiptVersionRequest,
    service: ReimbursementServiceDependency,
) -> ReimbursementReceiptResponse:
    return await service.receipt_lifecycle(
        receipt_id, request.expected_claim_version, request.expected_receipt_version, "void"
    )


@router.post(
    "/reimbursement-receipts/{receipt_id}/restore",
    response_model=ReimbursementReceiptResponse,
    dependencies=[formal_mutation("reimbursements", "ledger", "accounts", "reports")],
)
async def restore_receipt(
    receipt_id: UUID,
    request: ReimbursementReceiptVersionRequest,
    service: ReimbursementServiceDependency,
) -> ReimbursementReceiptResponse:
    return await service.receipt_lifecycle(
        receipt_id, request.expected_claim_version, request.expected_receipt_version, "restore"
    )


@router.get(
    "/transactions/{transaction_id}/reimbursement-eligibility",
    response_model=ReimbursementEligibility,
)
async def eligibility(
    transaction_id: UUID, service: ReimbursementServiceDependency
) -> ReimbursementEligibility:
    return await service.eligibility(transaction_id)


@router.get("/reimbursement-expense-options", response_model=list[ReimbursementExpenseOption])
async def expense_options(
    service: ReimbursementServiceDependency,
) -> list[ReimbursementExpenseOption]:
    return await service.expense_options()


@router.get(
    "/reimbursement-expense-candidates",
    response_model=ReimbursementExpenseCandidatePage,
)
async def expense_candidates(
    service: ReimbursementServiceDependency,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 30,
    query: str | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
) -> ReimbursementExpenseCandidatePage:
    return await service.expense_candidates(
        cursor=cursor,
        limit=limit,
        query=query,
        date_from=date_from,
        date_to=date_to,
    )


@router.get(
    "/reimbursement-receipt-account-options",
    response_model=ReimbursementReceiptAccountOptions,
)
async def receipt_account_options(
    service: ReimbursementServiceDependency,
) -> ReimbursementReceiptAccountOptions:
    return await service.receipt_account_options()


@router.get("/reimbursements/summary", response_model=ReimbursementSummary)
async def summary(
    service: ReimbursementServiceDependency,
    date_from: date | None = None,
    date_to: date | None = None,
) -> ReimbursementSummary:
    return await service.summary(date_from=date_from, date_to=date_to)
