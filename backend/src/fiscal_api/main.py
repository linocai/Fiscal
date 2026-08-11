from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from uuid import UUID

from fastapi import FastAPI
from sqlalchemy import func, select

from fiscal_api import __version__
from fiscal_api.api.router import api_router
from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.errors import install_error_handlers
from fiscal_api.core.logging import configure_logging
from fiscal_api.core.middleware import install_request_middleware
from fiscal_api.core.principal import AuthenticatedPrincipal
from fiscal_api.core.rate_limit import RateLimiter
from fiscal_api.core.security import require_authenticated
from fiscal_api.db.models.access import AccessCredential
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
        if resolved_settings.environment in {"staging", "production"}:
            async with app.state.session_factory() as session:
                credential_count = await session.scalar(
                    select(func.count()).select_from(AccessCredential)
                )
                if credential_count != 1:
                    raise RuntimeError(
                        "Authentication requires exactly one access passphrase credential"
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
    if resolved_settings.environment == "test":
        # Unit/domain tests own their authorization boundary explicitly; this
        # avoids reviving a static runtime credential solely to exercise a
        # schema or service contract against an otherwise disposable database.
        app.dependency_overrides[require_authenticated] = lambda: AuthenticatedPrincipal(
            id=UUID(int=1), label="Test access key", credential_generation=1
        )
    app.include_router(api_router)
    return app


app = create_app()
