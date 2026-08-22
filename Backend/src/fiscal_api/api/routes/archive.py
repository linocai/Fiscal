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
        # Keep the public boundary fail-closed even if its request model is
        # later refactored.  Raw AI export remains an operator-only CLI mode.
        password=request.password,
        include_ai_raw=False,
    )
    return Response(
        content=archive,
        media_type="application/vnd.fiscal.archive+json",
        headers={
            "Content-Disposition": 'attachment; filename="fiscal-archive-v1.far"',
            # Archive is a synchronous file transfer, not a persisted export
            # job.  Clients may only show this transfer's local progress.
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )
