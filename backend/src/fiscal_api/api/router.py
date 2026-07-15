from fastapi import APIRouter

from fiscal_api.api.routes import accounts, categories, health, system

api_router = APIRouter(prefix="/api/v1")
api_router.include_router(health.router)
api_router.include_router(system.router)
api_router.include_router(accounts.router)
api_router.include_router(categories.router)
