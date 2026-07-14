from typing import Annotated

from fastapi import Depends, Request

from fiscal_api.db.readiness import ReadinessCheck


def get_readiness_check(request: Request) -> ReadinessCheck:
    return request.app.state.readiness_check  # type: ignore[no-any-return]


ReadinessDependency = Annotated[ReadinessCheck, Depends(get_readiness_check)]
