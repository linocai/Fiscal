import re
from collections.abc import Awaitable, Callable
from time import perf_counter
from uuid import uuid4

import structlog
from fastapi import FastAPI, Request, Response

from fiscal_api.core.logging import bind_request_id, reset_request_id

REQUEST_ID_HEADER = "X-Request-ID"
VALID_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
logger = structlog.get_logger()


def install_request_middleware(app: FastAPI) -> None:
    async def request_context(
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        supplied = request.headers.get(REQUEST_ID_HEADER, "")
        request_id = supplied if VALID_REQUEST_ID.fullmatch(supplied) else str(uuid4())
        request.state.request_id = request_id
        context_token = bind_request_id(request_id)
        started = perf_counter()
        try:
            response = await call_next(request)
            response.headers[REQUEST_ID_HEADER] = request_id
            await logger.ainfo(
                "request_completed",
                method=request.method,
                path=request.url.path,
                status_code=response.status_code,
                duration_ms=round((perf_counter() - started) * 1000, 2),
            )
            return response
        finally:
            reset_request_id(context_token)

    app.middleware("http")(request_context)
