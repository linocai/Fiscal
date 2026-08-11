from fastapi import APIRouter, Depends, Response

from fiscal_api.api.dependencies import SessionDependency
from fiscal_api.api.p22_schemas import ArchiveExportRequest
from fiscal_api.core.security import require_authenticated
from fiscal_api.services.archive import ArchiveService

router = APIRouter(
    prefix="/archives",
    tags=["archives"],
    dependencies=[Depends(require_authenticated)],
)


@router.post("/export", response_class=Response)
async def export_archive(request: ArchiveExportRequest, session: SessionDependency) -> Response:
    archive, _manifest = await ArchiveService(session).export(
        password=request.password, include_ai_raw=request.include_ai_raw
    )
    return Response(
        content=archive,
        media_type="application/vnd.fiscal.archive+json",
        headers={"Content-Disposition": 'attachment; filename="fiscal-archive-v1.far"'},
    )
