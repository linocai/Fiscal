from __future__ import annotations

import base64
import binascii
import hashlib
import json
import unicodedata
from collections.abc import Mapping
from typing import cast
from uuid import UUID

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p31_schemas import (
    MerchantDraft,
    MerchantMappingReceipt,
    MerchantMappingRequest,
    MerchantMappingResponse,
    MerchantPage,
    MerchantPatch,
    MerchantResponse,
)
from fiscal_api.core.time import utc_now
from fiscal_api.db.models import Merchant, MerchantOperation, TransactionMerchantMapping
from fiscal_api.repositories.merchants import MerchantRepository
from fiscal_api.repositories.transactions import TransactionRepository
from fiscal_api.services.common import (
    acquire_mutation_lock,
    check_version,
    conflict,
    invalid,
    not_found,
)


class MerchantService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = MerchantRepository(session)
        self.transactions = TransactionRepository(session)

    async def list(
        self, *, include_archived: bool, query: str | None, limit: int, cursor: str | None
    ) -> MerchantPage:
        query_key = self._normalized_key(query) if query else None
        after_key, after_id = self._decode_cursor(cursor, query_key, include_archived)
        merchants = await self.repository.merchants_page(
            include_archived=include_archived,
            query_key=query_key,
            after_key=after_key,
            after_id=after_id,
            limit=limit + 1,
        )
        page = merchants[:limit]
        aliases = await self.repository.aliases_for_merchants([merchant.id for merchant in page])
        next_cursor = None
        if len(merchants) > limit and page:
            last = page[-1]
            next_cursor = self._encode_cursor(
                self._normalized_key(last.name), last.id, query_key, include_archived
            )
        return MerchantPage(
            items=[self._response(merchant, aliases.get(merchant.id, [])) for merchant in page],
            next_cursor=next_cursor,
        )

    async def get(self, merchant_id: UUID) -> MerchantResponse:
        return await self.response(await self._merchant(merchant_id))

    async def create(self, draft: MerchantDraft) -> MerchantResponse:
        name_key = self._identifier_key(draft.name, field="name")
        aliases = self._normalized_aliases(draft.aliases)
        await acquire_mutation_lock(self.session)
        merchant = Merchant(name=draft.name)
        self.repository.add(merchant)
        await self.session.flush()
        await self.repository.replace_identifiers(
            merchant,
            name_key=name_key,
            aliases=aliases,
        )
        try:
            await self.session.commit()
        except IntegrityError:
            await self.session.rollback()
            conflict(
                "merchant_name_or_alias_conflict",
                "A merchant or alias already uses this name",
            )
        return await self.response(merchant)

    async def update(self, merchant_id: UUID, patch: MerchantPatch) -> MerchantResponse:
        await acquire_mutation_lock(self.session)
        merchant = await self._merchant(merchant_id, for_update=True)
        check_version(
            merchant.version,
            patch.expected_version,
            resource_type="merchant",
            resource_id=str(merchant.id),
            reload_path=f"/api/v1/merchants/{merchant.id}",
        )
        name = patch.name if patch.name is not None else merchant.name
        existing = await self.repository.identifiers(merchant.id)
        aliases = (
            patch.aliases
            if patch.aliases is not None
            else [item.display_value for item in existing if item.kind == "alias"]
        )
        name_key = self._identifier_key(name, field="name")
        normalized_aliases = self._normalized_aliases(aliases)
        if patch.name is not None:
            merchant.name = patch.name
        if patch.name is not None or patch.aliases is not None:
            await self.repository.replace_identifiers(
                merchant,
                name_key=name_key,
                aliases=normalized_aliases,
            )
        merchant.version += 1
        merchant.updated_at = utc_now()
        try:
            await self.session.commit()
        except IntegrityError:
            await self.session.rollback()
            conflict(
                "merchant_name_or_alias_conflict",
                "A merchant or alias already uses this name",
            )
        return await self.response(merchant)

    async def mapping(self, transaction_id: UUID) -> MerchantMappingResponse | None:
        mapping = await self.repository.mapping(transaction_id)
        if mapping is None:
            return None
        return await self._mapping_response(mapping)

    async def confirm_mapping(
        self,
        transaction_id: UUID,
        request: MerchantMappingRequest,
        idempotency_key: UUID,
    ) -> MerchantMappingReceipt:
        payload_hash = self._hash(
            {"transaction_id": transaction_id, **request.model_dump(mode="json")}
        )
        existing_operation = await self.repository.operation(idempotency_key)
        if existing_operation is not None:
            if existing_operation.request_hash != payload_hash:
                conflict(
                    "idempotency_key_reused",
                    "Idempotency-Key was used for a different request",
                )
            return MerchantMappingReceipt.model_validate(existing_operation.receipt)

        await acquire_mutation_lock(self.session)
        existing_operation = await self.repository.operation(idempotency_key)
        if existing_operation is not None:
            if existing_operation.request_hash != payload_hash:
                conflict(
                    "idempotency_key_reused", "Idempotency-Key was used for a different request"
                )
            return MerchantMappingReceipt.model_validate(existing_operation.receipt)
        transaction = await self.transactions.get(transaction_id, for_update=True)
        if transaction is None:
            not_found("transaction_not_found", "The transaction does not exist")
        merchant = await self._merchant(request.merchant_id, for_update=True)
        if merchant.archived_at is not None:
            invalid("merchant_archived", "An archived merchant cannot be confirmed")
        mapping = await self.repository.mapping(transaction_id, for_update=True)
        action = "confirmed"
        if mapping is None:
            if request.expected_mapping_version is not None:
                conflict("merchant_mapping_not_found", "The mapping no longer exists")
            mapping = TransactionMerchantMapping(
                transaction_id=transaction_id, merchant_id=merchant.id
            )
            self.repository.add(mapping)
        else:
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
            if mapping.merchant_id != merchant.id:
                mapping.merchant_id = merchant.id
                mapping.version += 1
                mapping.confirmed_at = utc_now()
                action = "corrected"
            else:
                action = "confirmed"
        await self.session.flush()
        receipt = MerchantMappingReceipt(
            action=action,
            mapping=await self._mapping_response(mapping),
            transaction_version=transaction.version,
        )
        self.repository.add(
            MerchantOperation(
                idempotency_key=idempotency_key,
                request_hash=payload_hash,
                action=action,
                receipt=receipt.model_dump(mode="json"),
            )
        )
        try:
            await self.session.commit()
        except IntegrityError:
            await self.session.rollback()
            existing_operation = await self.repository.operation(idempotency_key)
            if existing_operation is not None:
                if existing_operation.request_hash != payload_hash:
                    conflict(
                        "idempotency_key_reused", "Idempotency-Key was used for a different request"
                    )
                return MerchantMappingReceipt.model_validate(existing_operation.receipt)
            raise
        return receipt

    async def release_mapping(
        self,
        transaction_id: UUID,
        expected_mapping_version: int,
        idempotency_key: UUID,
    ) -> MerchantMappingReceipt:
        payload_hash = self._hash(
            {
                "transaction_id": transaction_id,
                "expected_mapping_version": expected_mapping_version,
            }
        )
        existing_operation = await self.repository.operation(idempotency_key)
        if existing_operation is not None:
            if existing_operation.request_hash != payload_hash:
                conflict(
                    "idempotency_key_reused",
                    "Idempotency-Key was used for a different request",
                )
            return MerchantMappingReceipt.model_validate(existing_operation.receipt)

        await acquire_mutation_lock(self.session)
        existing_operation = await self.repository.operation(idempotency_key)
        if existing_operation is not None:
            if existing_operation.request_hash != payload_hash:
                conflict(
                    "idempotency_key_reused", "Idempotency-Key was used for a different request"
                )
            return MerchantMappingReceipt.model_validate(existing_operation.receipt)
        transaction = await self.transactions.get(transaction_id, for_update=True)
        if transaction is None:
            not_found("transaction_not_found", "The transaction does not exist")
        mapping = await self.repository.mapping(transaction_id, for_update=True)
        if mapping is None:
            not_found("merchant_mapping_not_found", "The transaction has no merchant mapping")
        check_version(
            mapping.version,
            expected_mapping_version,
            resource_type="transaction_merchant_mapping",
            resource_id=str(mapping.id),
            reload_path=f"/api/v1/transactions/{transaction_id}/merchant-mapping",
        )
        await self.session.delete(mapping)
        receipt = MerchantMappingReceipt(
            action="released",
            mapping=None,
            transaction_version=transaction.version,
        )
        self.repository.add(
            MerchantOperation(
                idempotency_key=idempotency_key,
                request_hash=payload_hash,
                action="released",
                receipt=receipt.model_dump(mode="json"),
            )
        )
        try:
            await self.session.commit()
        except IntegrityError:
            await self.session.rollback()
            existing_operation = await self.repository.operation(idempotency_key)
            if existing_operation is not None:
                if existing_operation.request_hash != payload_hash:
                    conflict(
                        "idempotency_key_reused", "Idempotency-Key was used for a different request"
                    )
                return MerchantMappingReceipt.model_validate(existing_operation.receipt)
            raise
        return receipt

    async def response(self, merchant: Merchant) -> MerchantResponse:
        aliases = await self.repository.aliases_for_merchants([merchant.id])
        return self._response(merchant, aliases[merchant.id])

    @staticmethod
    def _response(merchant: Merchant, aliases: list[str]) -> MerchantResponse:
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
        merchant = await self._merchant(mapping.merchant_id)
        return MerchantMappingResponse(
            transaction_id=mapping.transaction_id,
            merchant=await self.response(merchant),
            mapping_version=mapping.version,
            confirmed_at=mapping.confirmed_at,
        )

    async def _merchant(self, merchant_id: UUID, *, for_update: bool = False) -> Merchant:
        merchant = await self.repository.merchant(merchant_id, for_update=for_update)
        if merchant is None:
            not_found("merchant_not_found", "The merchant does not exist")
        return merchant

    @staticmethod
    def _hash(payload: object) -> str:
        return hashlib.sha256(
            json.dumps(
                payload,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                default=str,
            ).encode()
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

    @classmethod
    def _normalized_aliases(cls, aliases: list[str]) -> list[tuple[str, str]]:
        values = [
            (cls._identifier_key(value, field=f"aliases[{index}]"), value)
            for index, value in enumerate(aliases)
        ]
        if len({key for key, _ in values}) != len(values):
            conflict(
                "merchant_name_or_alias_conflict", "A merchant or alias already uses this name"
            )
        return values

    @staticmethod
    def _cursor_filter(query_key: str | None, include_archived: bool) -> str:
        return hashlib.sha256(
            json.dumps(
                {"query": query_key, "include_archived": include_archived}, sort_keys=True
            ).encode()
        ).hexdigest()

    @classmethod
    def _encode_cursor(
        cls, key: str, merchant_id: UUID, query_key: str | None, include_archived: bool
    ) -> str:
        payload = json.dumps(
            {
                "v": 1,
                "key": key,
                "id": str(merchant_id),
                "filter": cls._cursor_filter(query_key, include_archived),
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        return base64.urlsafe_b64encode(payload).decode().rstrip("=")

    @classmethod
    def _decode_cursor(
        cls, cursor: str | None, query_key: str | None, include_archived: bool
    ) -> tuple[str | None, UUID | None]:
        if cursor is None:
            return None, None
        try:
            raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4))
            payload = json.loads(raw.decode("utf-8"))
        except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
            invalid("invalid_merchant_cursor", "The merchant cursor is invalid")
        if not isinstance(payload, dict):
            invalid("invalid_merchant_cursor", "The merchant cursor is invalid")
        decoded = cast(Mapping[str, object], payload)
        if decoded.get("v") != 1:
            invalid("invalid_merchant_cursor", "The merchant cursor is invalid")
        key, raw_id = decoded.get("key"), decoded.get("id")
        if (
            not isinstance(key, str)
            or not isinstance(raw_id, str)
            or decoded.get("filter") != cls._cursor_filter(query_key, include_archived)
        ):
            invalid("invalid_merchant_cursor", "The merchant cursor is invalid")
        try:
            return key, UUID(raw_id)
        except ValueError:
            invalid("invalid_merchant_cursor", "The merchant cursor is invalid")
