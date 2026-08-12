import json
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Path, Query, Response
from pydantic import ValidationError
from starlette import status

from fiscal_api.api.dependencies import (
    StatementImportConfirmationServiceDependency,
    StatementImportFinalDraftServiceDependency,
    StatementImportReviewServiceDependency,
    StatementImportServiceDependency,
    StatementImportWorkbenchServiceDependency,
    formal_mutation,
)
from fiscal_api.api.p24_schemas import (
    StatementImportAttemptResponse,
    StatementImportEvidenceResponse,
    StatementImportEvidenceSubmission,
    StatementImportFailure,
    StatementImportRegister,
    StatementImportRegistrationResponse,
    StatementImportResponse,
    StatementImportVersionRequest,
)
from fiscal_api.api.p26_schemas import (
    StatementImportProviderAttemptCreate,
    StatementImportProviderAttemptResponse,
)
from fiscal_api.api.p27_confirmation_schemas import (
    StatementImportConfirmReceipt,
    StatementImportConfirmRequest,
    StatementImportFinalCreateDraftPut,
    StatementImportFinalCreateDraftResponse,
)
from fiscal_api.api.p27_schemas import (
    StatementImportDraftResolutionPut,
    StatementImportReviewResponse,
    StatementImportValidationRunCreate,
)
from fiscal_api.api.p28_schemas import (
    StatementImportWorkbenchFilters,
    StatementImportWorkbenchPageResponse,
    StatementImportWorkbenchResponse,
)
from fiscal_api.core.security import require_authenticated

router = APIRouter(
    prefix="/statement-imports",
    tags=["statement-imports"],
    dependencies=[Depends(require_authenticated)],
)


@router.post(
    "",
    response_model=StatementImportRegistrationResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[formal_mutation("statement_imports")],
)
async def register_statement_import(
    request: StatementImportRegister,
    response: Response,
    service: StatementImportServiceDependency,
) -> StatementImportRegistrationResponse:
    registered, duplicate = await service.register(request)
    if duplicate:
        response.status_code = status.HTTP_200_OK
    return registered


@router.get("/{statement_import_id}", response_model=StatementImportResponse)
async def get_statement_import(
    statement_import_id: UUID, service: StatementImportServiceDependency
) -> StatementImportResponse:
    return await service.get(statement_import_id)


def _workbench_filters(value: str | None) -> StatementImportWorkbenchFilters:
    if value is None:
        return StatementImportWorkbenchFilters()
    try:
        return StatementImportWorkbenchFilters.model_validate(json.loads(value))
    except (json.JSONDecodeError, ValidationError) as error:
        raise HTTPException(status_code=422, detail="Invalid workbench filters") from error


@router.get(
    "/{statement_import_id}/review-workbench", response_model=StatementImportWorkbenchResponse
)
async def get_statement_import_review_workbench(
    statement_import_id: UUID,
    service: StatementImportWorkbenchServiceDependency,
    cursor: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=200)] = 100,
    filters: str | None = None,
) -> StatementImportWorkbenchResponse:
    return await service.get(
        statement_import_id, cursor=cursor, limit=limit, filters=_workbench_filters(filters)
    )


@router.get(
    "/{statement_import_id}/review-workbench/pages/{page_number}",
    response_model=StatementImportWorkbenchPageResponse,
)
async def get_statement_import_review_workbench_page(
    statement_import_id: UUID,
    page_number: Annotated[int, Path(ge=1)],
    service: StatementImportWorkbenchServiceDependency,
) -> StatementImportWorkbenchPageResponse:
    return await service.page(statement_import_id, page_number)


@router.post(
    "/{statement_import_id}/attempts",
    response_model=StatementImportAttemptResponse,
    dependencies=[formal_mutation("statement_imports")],
)
async def start_statement_import_attempt(
    statement_import_id: UUID,
    request: StatementImportVersionRequest,
    response: Response,
    service: StatementImportServiceDependency,
) -> StatementImportAttemptResponse:
    _batch, attempt = await service.start_attempt(statement_import_id, request)
    response.headers["X-Fiscal-Statement-Import-Version"] = str(_batch.version)
    return attempt


@router.post(
    "/{statement_import_id}/evidence",
    response_model=StatementImportEvidenceResponse,
    dependencies=[formal_mutation("statement_imports")],
)
async def submit_statement_import_evidence(
    statement_import_id: UUID,
    request: StatementImportEvidenceSubmission,
    service: StatementImportServiceDependency,
) -> StatementImportEvidenceResponse:
    return await service.submit_evidence(statement_import_id, request)


@router.post(
    "/{statement_import_id}/provider-attempts",
    response_model=StatementImportProviderAttemptResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[formal_mutation("statement_imports")],
)
async def start_statement_import_provider_attempt(
    statement_import_id: UUID,
    request: StatementImportProviderAttemptCreate,
    response: Response,
    service: StatementImportServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> StatementImportProviderAttemptResponse:
    attempt, replay = await service.start_provider_attempt(
        statement_import_id, request, idempotency_key
    )
    if replay:
        response.status_code = status.HTTP_200_OK
    return attempt


@router.post(
    "/{statement_import_id}/validation-runs",
    response_model=StatementImportReviewResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[formal_mutation("statement_imports")],
)
async def start_statement_import_validation_run(
    statement_import_id: UUID,
    request: StatementImportValidationRunCreate,
    response: Response,
    service: StatementImportReviewServiceDependency,
) -> StatementImportReviewResponse:
    review = await service.start_run(statement_import_id, request)
    if review.replay:
        response.status_code = status.HTTP_200_OK
    return review


@router.get("/{statement_import_id}/review", response_model=StatementImportReviewResponse)
async def get_statement_import_review(
    statement_import_id: UUID, service: StatementImportReviewServiceDependency
) -> StatementImportReviewResponse:
    return await service.get_review(statement_import_id)


@router.put(
    "/{statement_import_id}/rows/{row_id}/draft-resolution",
    response_model=StatementImportReviewResponse,
    dependencies=[formal_mutation("statement_imports")],
)
async def put_statement_import_draft_resolution(
    statement_import_id: UUID,
    row_id: UUID,
    request: StatementImportDraftResolutionPut,
    service: StatementImportReviewServiceDependency,
) -> StatementImportReviewResponse:
    return await service.put_draft(statement_import_id, row_id, request)


@router.get(
    "/{statement_import_id}/rows/{row_id}/final-create-draft",
    response_model=StatementImportFinalCreateDraftResponse,
)
async def get_final_create_draft(
    statement_import_id: UUID, row_id: UUID, service: StatementImportFinalDraftServiceDependency
) -> StatementImportFinalCreateDraftResponse:
    return await service.get(statement_import_id, row_id)


@router.put(
    "/{statement_import_id}/rows/{row_id}/final-create-draft",
    response_model=StatementImportFinalCreateDraftResponse,
    dependencies=[formal_mutation("statement_imports")],
)
async def put_final_create_draft(
    statement_import_id: UUID,
    row_id: UUID,
    request: StatementImportFinalCreateDraftPut,
    service: StatementImportFinalDraftServiceDependency,
) -> StatementImportFinalCreateDraftResponse:
    return await service.put(statement_import_id, row_id, request)


@router.post(
    "/{statement_import_id}/confirm",
    response_model=StatementImportConfirmReceipt,
    dependencies=[formal_mutation("statement_imports", "ledger", "accounts", "credit")],
)
async def confirm_statement_import(
    statement_import_id: UUID,
    request: StatementImportConfirmRequest,
    service: StatementImportConfirmationServiceDependency,
    idempotency_key: Annotated[UUID, Header(alias="Idempotency-Key")],
) -> StatementImportConfirmReceipt:
    return await service.confirm(statement_import_id, request, idempotency_key)


@router.post(
    "/{statement_import_id}/fail",
    response_model=StatementImportResponse,
    dependencies=[formal_mutation("statement_imports")],
)
async def fail_statement_import_attempt(
    statement_import_id: UUID,
    request: StatementImportFailure,
    service: StatementImportServiceDependency,
) -> StatementImportResponse:
    return await service.fail_attempt(statement_import_id, request)


@router.post(
    "/{statement_import_id}/abandon",
    response_model=StatementImportResponse,
    dependencies=[formal_mutation("statement_imports")],
)
async def abandon_statement_import(
    statement_import_id: UUID,
    request: StatementImportVersionRequest,
    service: StatementImportServiceDependency,
) -> StatementImportResponse:
    return await service.abandon(statement_import_id, request)
