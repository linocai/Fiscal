from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from sqlalchemy import func, select

from fiscal_api import __version__
from fiscal_api.api.router import api_router
from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.errors import install_error_handlers
from fiscal_api.core.logging import configure_logging
from fiscal_api.core.middleware import install_request_middleware
from fiscal_api.core.rate_limit import RateLimiter
from fiscal_api.db.models.access import AccessCredential
from fiscal_api.db.models.security import DeviceToken, DeviceTokenStatus
from fiscal_api.db.readiness import ReadinessCheck, build_readiness_check
from fiscal_api.db.session import create_engine, create_session_factory


def create_app(
    settings: Settings | None = None,
    readiness_check: ReadinessCheck | None = None,
) -> FastAPI:
    resolved_settings = settings or get_settings()
    configure_logging(resolved_settings.log_level)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncGenerator[None]:
        engine = create_engine(resolved_settings.database_url)
        app.state.db_engine = engine
        app.state.session_factory = create_session_factory(engine)
        app.state.readiness_check = readiness_check or build_readiness_check(engine)
        app.state.rate_limiter = RateLimiter(resolved_settings)
        if resolved_settings.uses_database_device_tokens:
            async with app.state.session_factory() as session:
                credential_count = await session.scalar(
                    select(func.count()).select_from(AccessCredential)
                )
                active_tokens = await session.scalar(
                    select(func.count())
                    .select_from(DeviceToken)
                    .where(DeviceToken.status == DeviceTokenStatus.ACTIVE)
                )
                # Transition-safe: an access passphrase credential OR (before it is
                # set) at least one active device token keeps deployments bootable.
                if not credential_count and not active_tokens:
                    raise RuntimeError(
                        "Authentication requires an access passphrase credential "
                        "or at least one active device token"
                    )
        yield
        await engine.dispose()

    app = FastAPI(
        title="Fiscal API",
        version=__version__,
        lifespan=lifespan,
        docs_url="/docs" if resolved_settings.environment in {"local", "test"} else None,
        redoc_url=None,
    )
    install_request_middleware(app)
    install_error_handlers(app)
    app.dependency_overrides[get_settings] = lambda: resolved_settings
    app.include_router(api_router)
    return app


app = create_app()
