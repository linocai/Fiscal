from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from uuid import UUID

from pydantic import Field

from fiscal_api.api.p3_schemas import APIModel, TransactionDraft
from fiscal_api.api.p10_schemas import BatchCategoryRequest
from fiscal_api.api.p13_schemas import CashFlowItemResponse


class FormalAction(StrEnum):
    REPAYMENT = "repayment"
    CATEGORY_CHANGE = "category_change"
    CASH_FLOW_CONFIRM = "cash_flow_confirm"


class PreviewMeta(APIModel):
    preview_token: UUID
    action: FormalAction
    data_revision: int = Field(ge=0)
    expires_at: datetime


class RepaymentPreviewRequest(APIModel):
    draft: TransactionDraft


class RepaymentPreview(APIModel):
    meta: PreviewMeta
    amount_minor: int = Field(gt=0)
    payment_account_id: UUID
    payment_account_name: str
    payment_balance_before_minor: int
    payment_balance_after_minor: int
    credit_account_id: UUID
    credit_account_name: str
    credit_debt_before_minor: int = Field(ge=0)
    credit_debt_after_minor: int = Field(ge=0)
    credit_cycle_id: UUID
    cycle_remaining_before_minor: int = Field(ge=0)
    cycle_remaining_after_minor: int = Field(ge=0)


class CategoryChangePreviewItem(APIModel):
    transaction_id: UUID
    title: str
    expected_version: int = Field(ge=1)
    previous_category_id: UUID | None
    previous_category_name: str | None
    proposed_category_id: UUID
    proposed_category_name: str
    changed: bool


class CategoryChangePreview(APIModel):
    meta: PreviewMeta
    items: list[CategoryChangePreviewItem]
    changed_count: int = Field(ge=0)


class CategoryChangePreviewRequest(BatchCategoryRequest):
    pass


class CashFlowConfirmPreviewRequest(APIModel):
    expected_version: int = Field(ge=1)


class CashFlowConfirmPreview(APIModel):
    meta: PreviewMeta
    item_before: CashFlowItemResponse
    status_after: str


class ActionCommitRequest(APIModel):
    preview_token: UUID


class ActionCommitReceipt(APIModel):
    operation_id: UUID
    preview_token: UUID
    action: FormalAction
    data_revision: int = Field(ge=0)
    result: dict[str, object]
    replay: bool = False
