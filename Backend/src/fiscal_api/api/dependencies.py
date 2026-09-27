from collections.abc import AsyncIterator
from typing import Annotated, cast

from fastapi import Depends, Request
from fastapi.params import Depends as DependsParam
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from fiscal_api.core.config import Settings, get_settings
from fiscal_api.core.provider_credentials import ProviderCredentialCipher
from fiscal_api.db.readiness import ReadinessCheck
from fiscal_api.services.access import AccessService
from fiscal_api.services.accounts import AccountService
from fiscal_api.services.action_previews import ActionPreviewService
from fiscal_api.services.ai import AIService
from fiscal_api.services.ai_provider import AIProvider, build_ai_provider
from fiscal_api.services.cash_flow import CashFlowService
from fiscal_api.services.categories import CategoryService
from fiscal_api.services.credit import CreditService
from fiscal_api.services.credit_payoffs import CreditPayoffService
from fiscal_api.services.installments import InstallmentService
from fiscal_api.services.merchant_mapping import MerchantMappingService
from fiscal_api.services.migrations import MigrationRunService
from fiscal_api.services.reimbursements import ReimbursementService
from fiscal_api.services.reporting import ReportingService
from fiscal_api.services.transaction_history import TransactionHistoryService
from fiscal_api.services.transactions import TransactionService


def get_readiness_check(request: Request) -> ReadinessCheck:
    return request.app.state.readiness_check  # type: ignore[no-any-return]


ReadinessDependency = Annotated[ReadinessCheck, Depends(get_readiness_check)]


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    factory = cast(async_sessionmaker[AsyncSession], request.app.state.session_factory)
    async with factory() as session:
        # Authentication may resolve this dependency before a route-level
        # formal_mutation dependency. FiscalAsyncSession resolves current scopes
        # from this request at commit/flush time rather than snapshotting them.
        session.info["data_revision_request"] = request
        scopes = getattr(request.state, "data_revision_scopes", ())
        if scopes:
            session.info["data_revision_scopes"] = scopes
            session.info["data_revision_request"] = request
        yield session


SessionDependency = Annotated[AsyncSession, Depends(get_session)]

LEDGER_DERIVED_SCOPES = (
    "ledger",
    "accounts",
    "credit",
    "reimbursements",
    "cash_flow",
    "reports",
    "ai",
)


def formal_mutation(*scopes: str) -> DependsParam:
    """Opt a route into the one-receipt formal mutation contract."""
    if not scopes:
        raise ValueError("a formal mutation needs at least one affected scope")

    resolved = tuple(dict.fromkeys(scopes))
    if set(resolved) & {"ledger", "cash_flow", "reimbursements", "ai", "credit"}:
        resolved = tuple(dict.fromkeys((*resolved, *LEDGER_DERIVED_SCOPES)))

    async def mark(request: Request) -> None:
        request.state.data_revision_scopes = resolved

    mark.__dict__["fiscal_mutation_scopes"] = resolved
    return Depends(mark)


def get_account_service(session: SessionDependency) -> AccountService:
    return AccountService(session)


def get_category_service(session: SessionDependency) -> CategoryService:
    return CategoryService(session)


def get_cash_flow_service(session: SessionDependency) -> CashFlowService:
    return CashFlowService(session)


def get_transaction_service(session: SessionDependency) -> TransactionService:
    return TransactionService(session)


def get_merchant_mapping_service(session: SessionDependency) -> MerchantMappingService:
    return MerchantMappingService(session)


def get_transaction_history_service(session: SessionDependency) -> TransactionHistoryService:
    return TransactionHistoryService(session)


def get_credit_service(session: SessionDependency) -> CreditService:
    return CreditService(session)


def get_installment_service(session: SessionDependency) -> InstallmentService:
    return InstallmentService(session)


def get_reimbursement_service(session: SessionDependency) -> ReimbursementService:
    return ReimbursementService(session)


def get_reporting_service(session: SessionDependency) -> ReportingService:
    return ReportingService(session)


def get_migration_run_service(session: SessionDependency) -> MigrationRunService:
    return MigrationRunService(session)


def get_ai_provider(settings: Annotated[Settings, Depends(get_settings)]) -> AIProvider:
    return build_ai_provider(settings)


AIProviderDependency = Annotated[AIProvider, Depends(get_ai_provider)]


def get_ai_service(
    session: SessionDependency,
    provider: AIProviderDependency,
    settings: Annotated[Settings, Depends(get_settings)],
) -> AIService:
    return AIService(
        session,
        provider,
        runtime_settings=settings,
        credential_cipher=ProviderCredentialCipher.from_settings(settings),
    )


def get_access_service(
    session: SessionDependency, settings: Annotated[Settings, Depends(get_settings)]
) -> AccessService:
    return AccessService(session, settings)


def get_action_preview_service(session: SessionDependency) -> ActionPreviewService:
    return ActionPreviewService(session)


AccountServiceDependency = Annotated[AccountService, Depends(get_account_service)]
CategoryServiceDependency = Annotated[CategoryService, Depends(get_category_service)]
CashFlowServiceDependency = Annotated[CashFlowService, Depends(get_cash_flow_service)]
TransactionServiceDependency = Annotated[TransactionService, Depends(get_transaction_service)]
MerchantMappingServiceDependency = Annotated[
    MerchantMappingService, Depends(get_merchant_mapping_service)
]
TransactionHistoryServiceDependency = Annotated[
    TransactionHistoryService, Depends(get_transaction_history_service)
]
CreditServiceDependency = Annotated[CreditService, Depends(get_credit_service)]
InstallmentServiceDependency = Annotated[InstallmentService, Depends(get_installment_service)]
ReimbursementServiceDependency = Annotated[ReimbursementService, Depends(get_reimbursement_service)]
ReportingServiceDependency = Annotated[ReportingService, Depends(get_reporting_service)]
MigrationRunServiceDependency = Annotated[MigrationRunService, Depends(get_migration_run_service)]
AIServiceDependency = Annotated[AIService, Depends(get_ai_service)]
AccessServiceDependency = Annotated[AccessService, Depends(get_access_service)]
ActionPreviewServiceDependency = Annotated[
    ActionPreviewService, Depends(get_action_preview_service)
]


def get_credit_payoff_service(session: SessionDependency) -> CreditPayoffService:
    return CreditPayoffService(session)


CreditPayoffServiceDependency = Annotated[CreditPayoffService, Depends(get_credit_payoff_service)]
