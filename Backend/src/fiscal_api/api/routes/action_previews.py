from uuid import UUID

from fastapi import APIRouter, Depends

from fiscal_api.api.dependencies import ActionPreviewServiceDependency
from fiscal_api.api.p36_schemas import ActionCommitReceipt
from fiscal_api.core.security import require_authenticated

router = APIRouter(
    prefix="/action-operations",
    tags=["action-previews"],
    dependencies=[Depends(require_authenticated)],
)


@router.get("/{idempotency_key}", response_model=ActionCommitReceipt)
async def operation_receipt(
    idempotency_key: UUID,
    service: ActionPreviewServiceDependency,
) -> ActionCommitReceipt:
    return await service.operation(idempotency_key)
