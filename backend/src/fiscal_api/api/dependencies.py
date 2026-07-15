from collections.abc import AsyncIterator
from typing import Annotated, cast

from fastapi import Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from fiscal_api.db.readiness import ReadinessCheck
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.categories import CategoryService


def get_readiness_check(request: Request) -> ReadinessCheck:
    return request.app.state.readiness_check  # type: ignore[no-any-return]


ReadinessDependency = Annotated[ReadinessCheck, Depends(get_readiness_check)]


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    factory = cast(async_sessionmaker[AsyncSession], request.app.state.session_factory)
    async with factory() as session:
        yield session


SessionDependency = Annotated[AsyncSession, Depends(get_session)]


def get_account_service(session: SessionDependency) -> AccountService:
    return AccountService(session)


def get_category_service(session: SessionDependency) -> CategoryService:
    return CategoryService(session)


AccountServiceDependency = Annotated[AccountService, Depends(get_account_service)]
CategoryServiceDependency = Annotated[CategoryService, Depends(get_category_service)]
