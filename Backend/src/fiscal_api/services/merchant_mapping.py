from __future__ import annotations

import hashlib
import json
import unicodedata
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p31_schemas import (
    MerchantMappingRead,
    MerchantMappingReceipt,
    MerchantMappingRequest,
    MerchantMappingResponse,
    MerchantResponse,
)
from fiscal_api.core.time import utc_now
from fiscal_api.db.models import (
    Merchant,
    MerchantIdentifier,
    MerchantOperation,
    TransactionMerchantMapping,
)
from fiscal_api.repositories.transactions import TransactionRepository
from fiscal_api.services.common import (
    acquire_mutation_lock,
    check_version,
    conflict,
    invalid,
    not_found,
)


class MerchantMappingService:
    """Exact recognition and explicit transaction-level confirmation."""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.transactions = TransactionRepository(session)

    async def read(self, transaction_id: UUID) -> MerchantMappingRead:
        transaction = await self.transactions.get(transaction_id)
        if transaction is None:
            not_found("transaction_not_found", "The transaction does not exist")
        mapping = await self._mapping(transaction_id)
        if mapping is not None:
            return MerchantMappingRead(
                mapping=await self._mapping_response(mapping), suggested_merchant=None
            )
        # Suggestions never enter reports or mutate the ledger. Only an exact
        # normalized canonical name/alias match is strong enough to show here.
        key = self._normalized_key(transaction.title)
        identifier = await self._identifier(key) if len(key) <= 240 else None
        merchant = await self._merchant(identifier.merchant_id) if identifier else None
        return MerchantMappingRead(
            mapping=None,
            suggested_merchant=(
                await self._merchant_response(merchant)
                if merchant is not None and merchant.archived_at is None
                else None
            ),
        )

    async def confirm(
        self, transaction_id: UUID, request: MerchantMappingRequest, idempotency_key: UUID
    ) -> MerchantMappingReceipt:
        payload_hash = self._hash(
            {"action": "confirm", "transaction_id": str(transaction_id), **request.model_dump()}
        )
        replay = await self._replay(idempotency_key, payload_hash)
        if replay is not None:
            return replay
        await acquire_mutation_lock(self.session)
        replay = await self._replay(idempotency_key, payload_hash)
        if replay is not None:
            return replay
        transaction = await self.transactions.get(transaction_id, for_update=True)
        if transaction is None:
            not_found("transaction_not_found", "The transaction does not exist")
        mapping = await self._mapping(transaction_id, for_update=True)
        if mapping is None and request.expected_mapping_version is not None:
            conflict("merchant_mapping_not_found", "The mapping no longer exists")
        if mapping is not None:
            if request.expected_mapping_version is None:
                conflict(
                    "merchant_mapping_version_required",
                    "Correcting a mapping requires its version",
                )
            check_version(
                mapping.version,
                request.expected_mapping_version,
                resource_type="transaction_merchant_mapping",
                resource_id=str(mapping.id),
                reload_path=f"/api/v1/transactions/{transaction_id}/merchant-mapping",
            )

        name_key = self._identifier_key(request.merchant_name, field="merchant_name")
        aliases = [
            (self._identifier_key(alias, field=f"aliases[{index}]"), alias)
            for index, alias in enumerate(request.aliases)
        ]
        requested_keys = [name_key, *(key for key, _ in aliases)]
        if len(set(requested_keys)) != len(requested_keys):
            conflict(
                "merchant_name_or_alias_conflict", "A merchant or alias already uses this name"
            )
        identifier = await self._identifier(name_key)
        merchant = await self._merchant(identifier.merchant_id) if identifier else None
        if merchant is None:
            merchant = Merchant(name=request.merchant_name)
            self.session.add(merchant)
            await self.session.flush()
            self.session.add(
                MerchantIdentifier(
                    merchant_id=merchant.id,
                    normalized_key=name_key,
                    display_value=merchant.name,
                    kind="canonical",
                )
            )
        elif merchant.archived_at is not None:
            invalid("merchant_archived", "An archived merchant cannot be confirmed")
        added_alias = False
        for key, value in aliases:
            existing = await self._identifier(key)
            if existing is not None:
                if existing.merchant_id != merchant.id:
                    conflict(
                        "merchant_name_or_alias_conflict",
                        "A merchant or alias already uses this name",
                    )
                continue
            self.session.add(
                MerchantIdentifier(
                    merchant_id=merchant.id,
                    normalized_key=key,
                    display_value=value,
                    kind="alias",
                )
            )
            added_alias = True
        if added_alias and identifier is not None:
            merchant.version += 1
            merchant.updated_at = utc_now()
        await self.session.flush()

        action = "confirmed"
        if mapping is None:
            mapping = TransactionMerchantMapping(
                transaction_id=transaction_id,
                merchant_id=merchant.id,
                version=transaction.merchant_mapping_generation + 1,
            )
            self.session.add(mapping)
        elif mapping.merchant_id != merchant.id:
            mapping.merchant_id = merchant.id
            mapping.version = transaction.merchant_mapping_generation + 1
            mapping.confirmed_at = utc_now()
            action = "corrected"
        transaction.merchant_mapping_generation = mapping.version
        await self.session.flush()
        receipt = MerchantMappingReceipt(
            action=action,
            mapping=await self._mapping_response(mapping),
            transaction_version=transaction.version,
        )
        self._record(idempotency_key, payload_hash, action, receipt)
        try:
            await self.session.commit()
        except IntegrityError:
            await self.session.rollback()
            replay = await self._replay(idempotency_key, payload_hash)
            if replay is not None:
                return replay
            conflict(
                "merchant_name_or_alias_conflict", "A merchant or alias already uses this name"
            )
        return receipt

    async def release(
        self, transaction_id: UUID, expected_mapping_version: int, idempotency_key: UUID
    ) -> MerchantMappingReceipt:
        payload_hash = self._hash(
            {
                "action": "release",
                "transaction_id": str(transaction_id),
                "expected_mapping_version": expected_mapping_version,
            }
        )
        replay = await self._replay(idempotency_key, payload_hash)
        if replay is not None:
            return replay
        await acquire_mutation_lock(self.session)
        replay = await self._replay(idempotency_key, payload_hash)
        if replay is not None:
            return replay
        transaction = await self.transactions.get(transaction_id, for_update=True)
        if transaction is None:
            not_found("transaction_not_found", "The transaction does not exist")
        mapping = await self._mapping(transaction_id, for_update=True)
        if mapping is None:
            not_found("merchant_mapping_not_found", "The transaction has no merchant mapping")
        check_version(
            mapping.version,
            expected_mapping_version,
            resource_type="transaction_merchant_mapping",
            resource_id=str(mapping.id),
            reload_path=f"/api/v1/transactions/{transaction_id}/merchant-mapping",
        )
        transaction.merchant_mapping_generation += 1
        await self.session.delete(mapping)
        receipt = MerchantMappingReceipt(
            action="released", mapping=None, transaction_version=transaction.version
        )
        self._record(idempotency_key, payload_hash, "released", receipt)
        await self.session.commit()
        return receipt

    async def _mapping(
        self, transaction_id: UUID, *, for_update: bool = False
    ) -> TransactionMerchantMapping | None:
        statement = select(TransactionMerchantMapping).where(
            TransactionMerchantMapping.transaction_id == transaction_id
        )
        if for_update:
            statement = statement.with_for_update()
        return await self.session.scalar(statement)

    async def _identifier(self, key: str) -> MerchantIdentifier | None:
        return await self.session.scalar(
            select(MerchantIdentifier).where(MerchantIdentifier.normalized_key == key)
        )

    async def _merchant(self, merchant_id: UUID) -> Merchant:
        merchant = await self.session.get(Merchant, merchant_id)
        if merchant is None:
            not_found("merchant_not_found", "The merchant does not exist")
        return merchant

    async def _merchant_response(self, merchant: Merchant) -> MerchantResponse:
        aliases = list(
            (
                await self.session.scalars(
                    select(MerchantIdentifier.display_value)
                    .where(
                        MerchantIdentifier.merchant_id == merchant.id,
                        MerchantIdentifier.kind == "alias",
                    )
                    .order_by(MerchantIdentifier.display_value, MerchantIdentifier.id)
                )
            ).all()
        )
        return MerchantResponse(
            id=merchant.id,
            name=merchant.name,
            aliases=aliases,
            version=merchant.version,
            archived_at=merchant.archived_at,
            created_at=merchant.created_at,
            updated_at=merchant.updated_at,
        )

    async def _mapping_response(
        self, mapping: TransactionMerchantMapping
    ) -> MerchantMappingResponse:
        return MerchantMappingResponse(
            transaction_id=mapping.transaction_id,
            merchant=await self._merchant_response(await self._merchant(mapping.merchant_id)),
            mapping_version=mapping.version,
            confirmed_at=mapping.confirmed_at,
        )

    async def _replay(self, key: UUID, payload_hash: str) -> MerchantMappingReceipt | None:
        operation = await self.session.scalar(
            select(MerchantOperation).where(MerchantOperation.idempotency_key == key)
        )
        if operation is None:
            return None
        if operation.request_hash != payload_hash:
            conflict("idempotency_key_reused", "Idempotency-Key was used for a different request")
        return MerchantMappingReceipt.model_validate(operation.receipt)

    def _record(
        self, key: UUID, payload_hash: str, action: str, receipt: MerchantMappingReceipt
    ) -> None:
        self.session.add(
            MerchantOperation(
                idempotency_key=key,
                request_hash=payload_hash,
                action=action,
                receipt=receipt.model_dump(mode="json"),
            )
        )

    @staticmethod
    def _hash(payload: object) -> str:
        return hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        ).hexdigest()

    @staticmethod
    def _normalized_key(value: str) -> str:
        return unicodedata.normalize("NFKC", value).casefold()

    @classmethod
    def _identifier_key(cls, value: str, *, field: str) -> str:
        key = cls._normalized_key(value)
        try:
            key.encode("utf-8")
        except UnicodeEncodeError:
            invalid(
                "merchant_identifier_invalid",
                "Merchant names and aliases must be valid UTF-8 text",
                details={"field": field, "reason": "invalid_utf8"},
            )
        if len(key) > 240:
            invalid(
                "merchant_identifier_too_long",
                "Merchant name or alias is too long after normalization",
                details={"field": field, "max_length": 240},
            )
        return key
