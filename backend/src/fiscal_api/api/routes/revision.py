from fastapi import APIRouter, Depends
from sqlalchemy import select

from fiscal_api.api.dependencies import SessionDependency
from fiscal_api.api.p22_schemas import DataRevisionResponse
from fiscal_api.core.security import require_authenticated
from fiscal_api.db.models.revision import DataRevision

router = APIRouter(
    prefix="/data-revision",
    tags=["data-revision"],
    dependencies=[Depends(require_authenticated)],
)


@router.get("", response_model=DataRevisionResponse)
async def current_data_revision(session: SessionDependency) -> DataRevisionResponse:
    revision = await session.scalar(select(DataRevision.revision).where(DataRevision.id == 1))
    if revision is None:
        raise RuntimeError("data_revision singleton is missing")
    return DataRevisionResponse(revision=revision)
