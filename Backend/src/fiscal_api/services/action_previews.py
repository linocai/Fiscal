from __future__ import annotations

import hashlib
import json
from typing import cast
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p3_schemas import TransactionDraft
from fiscal_api.api.p10_schemas import BatchCategoryRequest
from fiscal_api.api.p36_schemas import (
    ActionCommitReceipt,
    CashFlowConfirmPreview,
    CategoryChangePreview,
    CategoryChangePreviewItem,
    FormalAction,
    PreviewMeta,
    RepaymentPreview,
)
from fiscal_api.core.time import utc_now
from fiscal_api.db.models import (
    AccountKind,
    ActionOperation,
    ActionPreviewSession,
    CashFlowStatus,
    DataRevision,
    TransactionKind,
)
from fiscal_api.repositories.accounts import AccountRepository
from fiscal_api.repositories.categories import CategoryRepository
from fiscal_api.repositories.credit import CreditRepository
from fiscal_api.services.cash_flow import CashFlowService
from fiscal_api.services.common import (
    acquire_mutation_lock,
    checked_int64,
    conflict,
    invalid,
    not_found,
)
from fiscal_api.services.transactions import TransactionService


class ActionPreviewService:
    """Version-bound previews for the three v1.6 formal action families."""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def preview_repayment(self, draft: TransactionDraft) -> RepaymentPreview:
        if draft.kind is not TransactionKind.REPAYMENT:
            invalid("repayment_preview_kind_required", "The preview requires a repayment draft")
        if (
            draft.account_id is None
            or draft.destination_account_id is None
            or draft.credit_cycle_id is None
            or draft.category_id is not None
        ):
            invalid(
                "invalid_transaction_configuration",
                "Repayments require payment account, credit account, and credit cycle",
            )
        accounts = AccountRepository(self.session)
        source = await accounts.get(draft.account_id)
        destination = await accounts.get(draft.destination_account_id)
        if source is None or destination is None:
            not_found("account_not_found", "A repayment account does not exist")
        if source.kind not in {AccountKind.CASH.value, AccountKind.DEBIT.value}:
            invalid("invalid_transaction_configuration", "The payment account must hold cash")
        if destination.kind != AccountKind.CREDIT.value:
            invalid("invalid_transaction_configuration", "The destination must be a credit account")
        if source.archived_at is not None or destination.archived_at is not None:
            conflict("account_archived", "A repayment account is archived")

        credit = CreditRepository(self.session)
        cycle = await credit.cycle(draft.credit_cycle_id)
        if cycle is None:
            not_found("credit_cycle_not_found", "The credit cycle does not exist")
        if cycle.account_id != destination.id:
            conflict("credit_cycle_account_mismatch", "The credit cycle belongs to another account")
        impacts = await accounts.balance_impacts([source.id, destination.id])
        source_before = checked_int64(
            source.opening_balance_minor + impacts.get(source.id, 0), label="payment balance"
        )
        debt_before = max(
            checked_int64(
                destination.opening_balance_minor - impacts.get(destination.id, 0),
                label="credit debt",
            ),
            0,
        )
        amounts = await credit.amounts([cycle.id])
        purchase, repaid = amounts.get(cycle.id, (0, 0))
        opening = destination.opening_balance_minor if cycle.is_opening_cycle else 0
        remaining = checked_int64(opening + purchase - repaid, label="credit cycle remaining")
        if draft.amount_minor > remaining:
            conflict(
                "repayment_exceeds_cycle_remaining",
                "The repayment exceeds the selected credit cycle remaining amount",
            )
        if draft.amount_minor > source_before:
            conflict("insufficient_account_balance", "The payment account balance is insufficient")

        revision = await self._data_revision()
        preview = await self._store(
            FormalAction.REPAYMENT,
            draft.model_dump(mode="json"),
            revision,
        )
        return RepaymentPreview(
            meta=self._meta(preview),
            amount_minor=draft.amount_minor,
            payment_account_id=source.id,
            payment_account_name=source.name,
            payment_balance_before_minor=source_before,
            payment_balance_after_minor=checked_int64(
                source_before - draft.amount_minor, label="payment balance after"
            ),
            credit_account_id=destination.id,
            credit_account_name=destination.name,
            credit_debt_before_minor=debt_before,
            credit_debt_after_minor=max(debt_before - draft.amount_minor, 0),
            credit_cycle_id=cycle.id,
            cycle_remaining_before_minor=remaining,
            cycle_remaining_after_minor=remaining - draft.amount_minor,
        )

    async def preview_category(self, request: BatchCategoryRequest) -> CategoryChangePreview:
        service = TransactionService(self.session)
        category, transactions = await service.validated_bulk_category(request, for_update=False)
        category_repository = CategoryRepository(self.session)
        names: dict[UUID, str] = {category.id: category.name}
        for transaction in transactions:
            if transaction.category_id is not None and transaction.category_id not in names:
                previous = await category_repository.get(transaction.category_id)
                if previous is not None:
                    names[previous.id] = previous.name
        revision = await self._data_revision()
        preview = await self._store(
            FormalAction.CATEGORY_CHANGE,
            request.model_dump(mode="json"),
            revision,
        )
        items = [
            CategoryChangePreviewItem(
                transaction_id=transaction.id,
                title=transaction.title,
                expected_version=transaction.version,
                previous_category_id=transaction.category_id,
                previous_category_name=(
                    names.get(transaction.category_id)
                    if transaction.category_id is not None
                    else None
                ),
                proposed_category_id=category.id,
                proposed_category_name=category.name,
                changed=transaction.category_id != category.id,
            )
            for transaction in transactions
        ]
        return CategoryChangePreview(
            meta=self._meta(preview),
            items=items,
            changed_count=sum(1 for item in items if item.changed),
        )

    async def preview_cash_flow_confirm(
        self, item_id: UUID, expected_version: int
    ) -> CashFlowConfirmPreview:
        item = await CashFlowService(self.session).get(item_id)
        if item.manual_item_id != item_id:
            conflict("cash_flow_system_item_read_only", "Only a manual cash flow item can confirm")
        if item.version != expected_version:
            conflict("version_conflict", "The cash flow item changed; reload it")
        if item.status is not CashFlowStatus.EXPECTED:
            conflict("cash_flow_cannot_confirm", "Only expected cash flow items can be confirmed")
        revision = await self._data_revision()
        preview = await self._store(
            FormalAction.CASH_FLOW_CONFIRM,
            {"item_id": str(item_id), "expected_version": expected_version},
            revision,
        )
        return CashFlowConfirmPreview(
            meta=self._meta(preview), item_before=item, status_after=CashFlowStatus.CONFIRMED.value
        )

    async def commit_repayment(
        self, preview_token: UUID, idempotency_key: UUID
    ) -> ActionCommitReceipt:
        preview, replay = await self._preview_for_commit(
            preview_token, FormalAction.REPAYMENT, idempotency_key
        )
        if replay is not None:
            return replay
        draft = TransactionDraft.model_validate(preview.payload["request"])
        transaction = await TransactionService(self.session).create(
            draft, idempotency_key, commit=False
        )
        return await self._finish(
            preview,
            idempotency_key,
            transaction.model_dump(mode="json"),
        )

    async def commit_category(
        self, preview_token: UUID, idempotency_key: UUID
    ) -> ActionCommitReceipt:
        preview, replay = await self._preview_for_commit(
            preview_token, FormalAction.CATEGORY_CHANGE, idempotency_key
        )
        if replay is not None:
            return replay
        request = BatchCategoryRequest.model_validate(preview.payload["request"])
        result = await TransactionService(self.session).bulk_category(request, commit=False)
        return await self._finish(preview, idempotency_key, result.model_dump(mode="json"))

    async def commit_cash_flow_confirm(
        self, item_id: UUID, preview_token: UUID, idempotency_key: UUID
    ) -> ActionCommitReceipt:
        preview, replay = await self._preview_for_commit(
            preview_token, FormalAction.CASH_FLOW_CONFIRM, idempotency_key
        )
        if replay is not None:
            return replay
        request = self._request(preview)
        if request.get("item_id") != str(item_id):
            invalid(
                "action_preview_input_mismatch", "The preview belongs to another cash flow item"
            )
        expected_version = request.get("expected_version")
        if not isinstance(expected_version, int) or isinstance(expected_version, bool):
            invalid("action_preview_invalid", "The preview payload is invalid")
        result = await CashFlowService(self.session).confirm(
            item_id, expected_version, commit=False
        )
        return await self._finish(preview, idempotency_key, result.model_dump(mode="json"))

    async def operation(self, idempotency_key: UUID) -> ActionCommitReceipt:
        operation = await self.session.scalar(
            select(ActionOperation).where(ActionOperation.idempotency_key == idempotency_key)
        )
        if operation is None:
            not_found("action_operation_not_found", "The action receipt was not found")
        return ActionCommitReceipt.model_validate({**operation.receipt, "replay": True})

    async def _store(
        self, action: FormalAction, request: dict[str, object], data_revision: int
    ) -> ActionPreviewSession:
        request_hash = self._hash({"action": action.value, "request": request})
        preview = ActionPreviewSession(
            action=action.value,
            request_hash=request_hash,
            payload={"request": request},
            data_revision=data_revision,
        )
        self.session.add(preview)
        await self.session.commit()
        return preview

    async def _preview_for_commit(
        self, preview_token: UUID, action: FormalAction, idempotency_key: UUID
    ) -> tuple[ActionPreviewSession, ActionCommitReceipt | None]:
        # The preview revision must be checked while holding the same global
        # write lock as every formal mutation. Otherwise another writer can
        # commit between this check and the domain service's lock acquisition,
        # leaving a successful write with a stale/incorrect receipt.
        await acquire_mutation_lock(self.session)
        request_hash = self._commit_hash(preview_token, action)
        existing = await self.session.scalar(
            select(ActionOperation).where(ActionOperation.idempotency_key == idempotency_key)
        )
        if existing is not None:
            if existing.request_hash != request_hash:
                conflict("idempotency_key_reused", "Idempotency-Key was used for another action")
            return (
                await self._required_preview(existing.preview_id),
                ActionCommitReceipt.model_validate({**existing.receipt, "replay": True}),
            )
        preview = await self.session.scalar(
            select(ActionPreviewSession)
            .where(ActionPreviewSession.id == preview_token)
            .with_for_update()
        )
        if preview is None:
            invalid("action_preview_not_found", "The preview token is invalid")
        if preview.action != action.value:
            invalid("action_preview_input_mismatch", "The preview belongs to another action")
        if preview.consumed_at is not None:
            consumed_operation = await self.session.scalar(
                select(ActionOperation).where(ActionOperation.preview_id == preview.id)
            )
            if (
                consumed_operation is not None
                and consumed_operation.idempotency_key == idempotency_key
            ):
                return (
                    preview,
                    ActionCommitReceipt.model_validate(
                        {**consumed_operation.receipt, "replay": True}
                    ),
                )
            conflict("action_preview_consumed", "The preview was already committed")
        if preview.expires_at <= utc_now():
            conflict("action_preview_expired", "The preview expired; preview again")
        current_revision = await self._data_revision()
        if current_revision != preview.data_revision:
            conflict(
                "action_preview_stale",
                "Fiscal data changed after the preview; preview again",
                details={
                    "reason": "data_revision_changed",
                    "expected_data_revision": preview.data_revision,
                    "current_data_revision": current_revision,
                    "safe_to_reload": True,
                },
            )
        return preview, None

    async def _finish(
        self,
        preview: ActionPreviewSession,
        idempotency_key: UUID,
        result: dict[str, object],
    ) -> ActionCommitReceipt:
        action = FormalAction(preview.action)
        predicted_revision = preview.data_revision + 1
        operation_id = UUID(bytes=hashlib.sha256(idempotency_key.bytes).digest()[:16])
        receipt = ActionCommitReceipt(
            operation_id=operation_id,
            preview_token=preview.id,
            action=action,
            data_revision=predicted_revision,
            result=result,
        )
        preview.consumed_at = utc_now()
        operation = ActionOperation(
            id=operation_id,
            preview_id=preview.id,
            action=action.value,
            idempotency_key=idempotency_key,
            request_hash=self._commit_hash(preview.id, action),
            data_revision=predicted_revision,
            receipt=receipt.model_dump(mode="json"),
        )
        self.session.add(operation)
        await self.session.commit()
        committed = self.session.info.get("committed_data_revision")
        if committed is not None and committed != predicted_revision:
            raise RuntimeError("formal action receipt revision mismatch")
        return receipt

    async def _required_preview(self, preview_id: UUID) -> ActionPreviewSession:
        preview = await self.session.get(ActionPreviewSession, preview_id)
        if preview is None:
            raise RuntimeError("action operation preview is missing")
        return preview

    @staticmethod
    def _request(preview: ActionPreviewSession) -> dict[str, object]:
        value = preview.payload.get("request")
        if not isinstance(value, dict):
            invalid("action_preview_invalid", "The preview payload is invalid")
        mapping = cast(dict[object, object], value)
        if any(not isinstance(key, str) for key in mapping.keys()):
            invalid("action_preview_invalid", "The preview payload is invalid")
        return cast(dict[str, object], mapping)

    async def _data_revision(self) -> int:
        revision = await self.session.scalar(
            select(DataRevision.revision).where(DataRevision.id == 1)
        )
        if revision is None:
            raise RuntimeError("data_revision singleton is missing")
        return int(revision)

    @staticmethod
    def _meta(preview: ActionPreviewSession) -> PreviewMeta:
        return PreviewMeta(
            preview_token=preview.id,
            action=FormalAction(preview.action),
            data_revision=preview.data_revision,
            expires_at=preview.expires_at,
        )

    @staticmethod
    def _hash(value: object) -> str:
        return hashlib.sha256(
            json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
        ).hexdigest()

    @classmethod
    def _commit_hash(cls, preview_token: UUID, action: FormalAction) -> str:
        return cls._hash({"preview_token": str(preview_token), "action": action.value})
