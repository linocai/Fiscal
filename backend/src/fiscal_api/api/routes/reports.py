from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query

from fiscal_api.api.dependencies import ReportingServiceDependency
from fiscal_api.api.p7_schemas import (
    CashFlowReport,
    DebtReport,
    OverviewReport,
    ReportDrillDownPage,
    ReportLens,
    SpendingReport,
)
from fiscal_api.core.security import require_device_token

router = APIRouter(
    prefix="/reports",
    tags=["reports"],
    dependencies=[Depends(require_device_token)],
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
