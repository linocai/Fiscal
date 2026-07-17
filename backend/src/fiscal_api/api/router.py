from fastapi import APIRouter

from fiscal_api.api.routes import (
    accounts,
    ai,
    cash_flow,
    categories,
    credit,
    device_tokens,
    health,
    installments,
    reimbursements,
    reports,
    system,
    transactions,
)

api_router = APIRouter(prefix="/api/v1")
api_router.include_router(health.router)
api_router.include_router(system.router)
api_router.include_router(device_tokens.router)
api_router.include_router(accounts.router)
api_router.include_router(ai.router)
api_router.include_router(categories.router)
api_router.include_router(cash_flow.router)
api_router.include_router(transactions.router)
api_router.include_router(credit.router)
api_router.include_router(installments.router)
api_router.include_router(reimbursements.router)
api_router.include_router(reports.router)
