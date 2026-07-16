from collections.abc import AsyncIterator
from typing import Annotated, cast

from fastapi import Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from fiscal_api.core.config import Settings, get_settings
from fiscal_api.db.readiness import ReadinessCheck
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.ai import AIService
from fiscal_api.services.ai_provider import AIProvider, build_ai_provider
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.credit import CreditService
from fiscal_api.services.installments import InstallmentService
from fiscal_api.services.reimbursements import ReimbursementService
from fiscal_api.services.reporting import ReportingService
from fiscal_api.services.security import DeviceTokenService
from fiscal_api.services.transactions import TransactionService


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


def get_transaction_service(session: SessionDependency) -> TransactionService:
    return TransactionService(session)


def get_credit_service(session: SessionDependency) -> CreditService:
    return CreditService(session)


def get_installment_service(session: SessionDependency) -> InstallmentService:
    return InstallmentService(session)


def get_reimbursement_service(session: SessionDependency) -> ReimbursementService:
    return ReimbursementService(session)


def get_reporting_service(session: SessionDependency) -> ReportingService:
    return ReportingService(session)


def get_ai_provider(settings: Annotated[Settings, Depends(get_settings)]) -> AIProvider:
    return build_ai_provider(settings)


AIProviderDependency = Annotated[AIProvider, Depends(get_ai_provider)]


def get_ai_service(session: SessionDependency, provider: AIProviderDependency) -> AIService:
    return AIService(session, provider)


def get_device_token_service(
    session: SessionDependency, settings: Annotated[Settings, Depends(get_settings)]
) -> DeviceTokenService:
    return DeviceTokenService(session, settings)


AccountServiceDependency = Annotated[AccountService, Depends(get_account_service)]
CategoryServiceDependency = Annotated[CategoryService, Depends(get_category_service)]
TransactionServiceDependency = Annotated[TransactionService, Depends(get_transaction_service)]
CreditServiceDependency = Annotated[CreditService, Depends(get_credit_service)]
InstallmentServiceDependency = Annotated[InstallmentService, Depends(get_installment_service)]
ReimbursementServiceDependency = Annotated[ReimbursementService, Depends(get_reimbursement_service)]
ReportingServiceDependency = Annotated[ReportingService, Depends(get_reporting_service)]
AIServiceDependency = Annotated[AIService, Depends(get_ai_service)]
DeviceTokenServiceDependency = Annotated[DeviceTokenService, Depends(get_device_token_service)]
