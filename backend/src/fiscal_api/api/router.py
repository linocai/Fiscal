from fastapi import APIRouter

from fiscal_api.api.routes import health, system

api_router = APIRouter(prefix="/api/v1")
api_router.include_router(health.router)
api_router.include_router(system.router)
