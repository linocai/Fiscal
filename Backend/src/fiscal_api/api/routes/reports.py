from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Path, Query, Request, Response
from fastapi.responses import JSONResponse

from fiscal_api.api.dependencies import ReportingServiceDependency
from fiscal_api.api.legacy_report_serialization import (
    facts_drill_down_response,
    facts_response,
    period_report_response,
)
from fiscal_api.api.p7_schemas import (
    CashFlowReport,
    DebtReport,
    FactsDrillDownScopeType,
    KnownFutureEventPage,
    OverviewReport,
    ReportDrillDownPage,
    ReportLens,
    SpendingReport,
)
from fiscal_api.api.p34_schemas import (
    SUPPORTED_REPORT_YEAR_RANGE,
    PeriodReportDrillDownPage,
    PeriodReportDrillDownPageV2,
    PeriodReportV2,
    ReportPeriodKind,
)
from fiscal_api.core.middleware import DATA_REVISION_HEADER
from fiscal_api.core.security import require_authenticated
from fiscal_api.db.models import TransactionSource
from fiscal_api.services.report_exports import report_csv, report_export_filename, report_pdf

BALANCE_SEMANTICS_HEADER = "X-Fiscal-Report-Balance-Semantics"


async def report_balance_semantics(
    request: Request, response: Response, service: ReportingServiceDependency
) -> None:
    service.balance_as_of_semantics = (
        "/reports/v2/" in request.url.path
        and request.headers.get(BALANCE_SEMANTICS_HEADER) == "as-of-v1"
    )
    response.headers["Vary"] = BALANCE_SEMANTICS_HEADER
    if service.balance_as_of_semantics:
        response.headers[BALANCE_SEMANTICS_HEADER] = "as-of-v1"


def _v2_response(report: PeriodReportV2, service: ReportingServiceDependency) -> JSONResponse:
    content = report.model_dump(mode="json")
    headers = {"Vary": BALANCE_SEMANTICS_HEADER}
    if service.balance_as_of_semantics:
        headers[BALANCE_SEMANTICS_HEADER] = "as-of-v1"
    else:
        for key in (
            "credit_debt_at_period_end_status",
            "unknown_balance_account_ids",
            "balance_unavailable_reason",
        ):
            content["summary"].pop(key, None)
        for row in content["accounts"]:
            for key in (
                "opening_balance_status",
                "closing_balance_status",
                "balance_as_of_date",
                "balance_unavailable_reason",
            ):
                row.pop(key, None)
    return JSONResponse(content=content, headers=headers)


router = APIRouter(
    prefix="/reports",
    tags=["reports"],
    dependencies=[Depends(require_authenticated), Depends(report_balance_semantics)],
)


@router.get("/overview", response_model=OverviewReport)
async def overview(
    service: ReportingServiceDependency,
    month: Annotated[str | None, Query(pattern=r"^\d{4}-(0[1-9]|1[0-2])$")] = None,
) -> OverviewReport:
    return await service.overview(month=month)


@router.get("/spending", response_model=SpendingReport)
async def spending(
    service: ReportingServiceDependency,
    date_from: date | None = None,
    date_to: date | None = None,
) -> SpendingReport:
    return await service.spending(date_from=date_from, date_to=date_to)


@router.get("/cash-flow", response_model=CashFlowReport)
async def cash_flow(
    service: ReportingServiceDependency,
    date_from: date | None = None,
    date_to: date | None = None,
    forecast_days: Annotated[int, Query(ge=1, le=90)] = 30,
    today: date | None = None,
) -> CashFlowReport:
    return await service.cash_flow(
        date_from=date_from,
        date_to=date_to,
        forecast_days=forecast_days,
        today=today,
    )


@router.get("/debt", response_model=DebtReport)
async def debt(
    service: ReportingServiceDependency,
    as_of: date | None = None,
) -> DebtReport:
    return await service.debt(as_of=as_of)


@router.get("/facts", response_class=JSONResponse)
async def facts(
    service: ReportingServiceDependency,
    window_days: Annotated[int, Query(ge=1, le=90)] = 30,
) -> JSONResponse:
    return facts_response(await service.facts(window_days=window_days))


@router.get("/facts/drill-down", response_class=JSONResponse)
async def facts_drill_down(
    service: ReportingServiceDependency,
    scope: FactsDrillDownScopeType,
    expected_data_revision: Annotated[int, Query(ge=0)],
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> JSONResponse:
    return facts_drill_down_response(
        await service.facts_drill_down(
            scope_type=scope,
            expected_data_revision=expected_data_revision,
            cursor=cursor,
            limit=limit,
        )
    )


@router.get("/future-events", response_model=KnownFutureEventPage)
async def future_events(
    service: ReportingServiceDependency,
    window_days: Annotated[int, Query(ge=7, le=90)] = 30,
    account_id: UUID | None = None,
    cursor: str | None = None,
    expected_data_revision: Annotated[int | None, Query(ge=0)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> KnownFutureEventPage:
    return await service.future_events(
        window_days=window_days,
        account_id=account_id,
        cursor=cursor,
        limit=limit,
        expected_data_revision=expected_data_revision,
    )


@router.get("/monthly/{period}", response_class=JSONResponse)
async def monthly_report(
    period: Annotated[
        str,
        Path(
            pattern=r"^\d{4}-(0[1-9]|1[0-2])$",
            description=f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}",
        ),
    ],
    service: ReportingServiceDependency,
) -> JSONResponse:
    return period_report_response(await service.monthly_report(period=period))


@router.get("/yearly/{period}", response_class=JSONResponse)
async def yearly_report(
    period: Annotated[
        str,
        Path(
            pattern=r"^\d{4}$", description=f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}"
        ),
    ],
    service: ReportingServiceDependency,
) -> JSONResponse:
    return period_report_response(await service.yearly_report(period=period))


@router.get("/v2/monthly/{period}", response_model=PeriodReportV2)
async def monthly_report_v2(
    period: Annotated[
        str,
        Path(
            pattern=r"^\d{4}-(0[1-9]|1[0-2])$",
            description=f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}",
        ),
    ],
    service: ReportingServiceDependency,
) -> JSONResponse:
    return _v2_response(await service.monthly_report_v2(period=period), service)


@router.get("/v2/yearly/{period}", response_model=PeriodReportV2)
async def yearly_report_v2(
    period: Annotated[
        str,
        Path(
            pattern=r"^\d{4}$", description=f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}"
        ),
    ],
    service: ReportingServiceDependency,
) -> JSONResponse:
    return _v2_response(await service.yearly_report_v2(period=period), service)


@router.get("/v2/monthly/{period}/export.csv", response_class=Response)
async def export_monthly_report_v2_csv(
    period: Annotated[
        str,
        Path(pattern=r"^\d{4}-(0[1-9]|1[0-2])$"),
    ],
    service: ReportingServiceDependency,
    expected_data_revision: Annotated[int, Query(ge=0)],
) -> Response:
    report = await service.monthly_report_v2(
        period=period, expected_data_revision=expected_data_revision
    )
    return _report_file_response(
        report_csv(report),
        report_export_filename(report, "csv"),
        "text/csv; charset=utf-8",
        data_revision=report.meta.data_revision,
        balance_semantics=service.balance_as_of_semantics,
    )


@router.get("/v2/monthly/{period}/export.pdf", response_class=Response)
async def export_monthly_report_v2_pdf(
    period: Annotated[str, Path(pattern=r"^\d{4}-(0[1-9]|1[0-2])$")],
    service: ReportingServiceDependency,
    expected_data_revision: Annotated[int, Query(ge=0)],
) -> Response:
    report = await service.monthly_report_v2(
        period=period, expected_data_revision=expected_data_revision
    )
    return _report_file_response(
        report_pdf(report),
        report_export_filename(report, "pdf"),
        "application/pdf",
        data_revision=report.meta.data_revision,
        balance_semantics=service.balance_as_of_semantics,
    )


@router.get("/v2/yearly/{period}/export.csv", response_class=Response)
async def export_yearly_report_v2_csv(
    period: Annotated[str, Path(pattern=r"^\d{4}$")],
    service: ReportingServiceDependency,
    expected_data_revision: Annotated[int, Query(ge=0)],
) -> Response:
    report = await service.yearly_report_v2(
        period=period, expected_data_revision=expected_data_revision
    )
    return _report_file_response(
        report_csv(report),
        report_export_filename(report, "csv"),
        "text/csv; charset=utf-8",
        data_revision=report.meta.data_revision,
        balance_semantics=service.balance_as_of_semantics,
    )


@router.get("/v2/yearly/{period}/export.pdf", response_class=Response)
async def export_yearly_report_v2_pdf(
    period: Annotated[str, Path(pattern=r"^\d{4}$")],
    service: ReportingServiceDependency,
    expected_data_revision: Annotated[int, Query(ge=0)],
) -> Response:
    report = await service.yearly_report_v2(
        period=period, expected_data_revision=expected_data_revision
    )
    return _report_file_response(
        report_pdf(report),
        report_export_filename(report, "pdf"),
        "application/pdf",
        data_revision=report.meta.data_revision,
        balance_semantics=service.balance_as_of_semantics,
    )


@router.get("/monthly/{period}/export.csv", response_class=Response)
async def export_monthly_report_csv(
    period: Annotated[
        str,
        Path(
            pattern=r"^\d{4}-(0[1-9]|1[0-2])$",
            description=f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}",
        ),
    ],
    service: ReportingServiceDependency,
    expected_data_revision: Annotated[int | None, Query(ge=0)] = None,
) -> Response:
    report = await service.monthly_report(
        period=period, expected_data_revision=expected_data_revision
    )
    return _report_file_response(
        report_csv(report),
        report_export_filename(report, "csv"),
        "text/csv; charset=utf-8",
        data_revision=report.meta.data_revision,
        balance_semantics=service.balance_as_of_semantics,
    )


@router.get("/monthly/{period}/export.pdf", response_class=Response)
async def export_monthly_report_pdf(
    period: Annotated[
        str,
        Path(
            pattern=r"^\d{4}-(0[1-9]|1[0-2])$",
            description=f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}",
        ),
    ],
    service: ReportingServiceDependency,
    expected_data_revision: Annotated[int | None, Query(ge=0)] = None,
) -> Response:
    report = await service.monthly_report(
        period=period, expected_data_revision=expected_data_revision
    )
    return _report_file_response(
        report_pdf(report),
        report_export_filename(report, "pdf"),
        "application/pdf",
        data_revision=report.meta.data_revision,
        balance_semantics=service.balance_as_of_semantics,
    )


@router.get("/yearly/{period}/export.csv", response_class=Response)
async def export_yearly_report_csv(
    period: Annotated[
        str,
        Path(
            pattern=r"^\d{4}$", description=f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}"
        ),
    ],
    service: ReportingServiceDependency,
    expected_data_revision: Annotated[int | None, Query(ge=0)] = None,
) -> Response:
    report = await service.yearly_report(
        period=period, expected_data_revision=expected_data_revision
    )
    return _report_file_response(
        report_csv(report),
        report_export_filename(report, "csv"),
        "text/csv; charset=utf-8",
        data_revision=report.meta.data_revision,
        balance_semantics=service.balance_as_of_semantics,
    )


@router.get("/yearly/{period}/export.pdf", response_class=Response)
async def export_yearly_report_pdf(
    period: Annotated[
        str,
        Path(
            pattern=r"^\d{4}$", description=f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}"
        ),
    ],
    service: ReportingServiceDependency,
    expected_data_revision: Annotated[int | None, Query(ge=0)] = None,
) -> Response:
    report = await service.yearly_report(
        period=period, expected_data_revision=expected_data_revision
    )
    return _report_file_response(
        report_pdf(report),
        report_export_filename(report, "pdf"),
        "application/pdf",
        data_revision=report.meta.data_revision,
        balance_semantics=service.balance_as_of_semantics,
    )


@router.get("/period-drill-down", response_model=PeriodReportDrillDownPage)
async def period_report_drill_down(
    service: ReportingServiceDependency,
    period_kind: Annotated[
        ReportPeriodKind,
        Query(description="Selects period format: month uses YYYY-MM; year uses YYYY."),
    ],
    period: Annotated[
        str,
        Query(
            description=(
                f"Supported report years: {SUPPORTED_REPORT_YEAR_RANGE}; "
                "month uses YYYY-MM; year uses YYYY."
            )
        ),
    ],
    expected_data_revision: Annotated[int, Query(ge=0)],
    category_id: UUID | None = None,
    account_id: UUID | None = None,
    merchant_id: UUID | None = None,
    source: TransactionSource | None = None,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> PeriodReportDrillDownPage:
    return await service.period_report_drill_down(
        period_kind=period_kind,
        period=period,
        expected_data_revision=expected_data_revision,
        category_id=category_id,
        account_id=account_id,
        merchant_id=merchant_id,
        source=source,
        cursor=cursor,
        limit=limit,
    )


@router.get("/v2/period-drill-down", response_model=PeriodReportDrillDownPageV2)
async def period_report_drill_down_v2(
    service: ReportingServiceDependency,
    period_kind: Annotated[
        ReportPeriodKind,
        Query(description="Selects period format: month uses YYYY-MM; year uses YYYY."),
    ],
    period: Annotated[str, Query(description="month uses YYYY-MM; year uses YYYY")],
    expected_data_revision: Annotated[int, Query(ge=0)],
    category_id: UUID | None = None,
    account_id: UUID | None = None,
    merchant_id: UUID | None = None,
    source: TransactionSource | None = None,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> PeriodReportDrillDownPageV2:
    return await service.period_report_drill_down_v2(
        period_kind=period_kind,
        period=period,
        expected_data_revision=expected_data_revision,
        category_id=category_id,
        account_id=account_id,
        merchant_id=merchant_id,
        source=source,
        cursor=cursor,
        limit=limit,
    )


@router.get("/drill-down", response_model=ReportDrillDownPage)
async def drill_down(
    service: ReportingServiceDependency,
    lens: ReportLens,
    date_from: date,
    date_to: date,
    category_id: UUID | None = None,
    account_id: UUID | None = None,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> ReportDrillDownPage:
    return await service.drill_down(
        lens=lens,
        date_from=date_from,
        date_to=date_to,
        category_id=category_id,
        account_id=account_id,
        cursor=cursor,
        limit=limit,
    )


def _report_file_response(
    content: bytes,
    filename: str,
    media_type: str,
    *,
    data_revision: int,
    balance_semantics: bool = False,
) -> Response:
    return Response(
        content=content,
        media_type=media_type,
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            DATA_REVISION_HEADER: str(data_revision),
            "Vary": BALANCE_SEMANTICS_HEADER,
            **({BALANCE_SEMANTICS_HEADER: "as-of-v1"} if balance_semantics else {}),
        },
    )
