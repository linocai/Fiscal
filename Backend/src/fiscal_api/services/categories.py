from __future__ import annotations

import hashlib
import json
from typing import cast
from urllib.parse import urlencode
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p2_schemas import (
    CategoryDraft,
    CategoryOrderState,
    CategoryPatch,
    CategoryResponse,
)
from fiscal_api.api.p31_schemas import (
    CategoryChildMappingRequirement,
    CategoryDependency,
    CategoryMergeCommitRequest,
    CategoryMergePreview,
    CategoryMergePreviewRequest,
    CategorySplitCommitRequest,
    CategorySplitPreview,
    CategorySplitPreviewRequest,
    CategoryTransformReceipt,
)
from fiscal_api.core.time import utc_now
from fiscal_api.db.models import (
    Category,
    CategoryDirection,
    CategoryTransformOperation,
    CategoryTransformPreview,
    DataRevision,
    LedgerTransaction,
)
from fiscal_api.repositories.categories import CategoryRepository
from fiscal_api.repositories.transactions import TransactionRepository
from fiscal_api.services.common import (
    acquire_p2_mutation_lock,
    check_version,
    conflict,
    invalid,
    list_revision,
    not_found,
)
from fiscal_api.services.transactions import TransactionService


class CategoryService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = CategoryRepository(session)

    @staticmethod
    def response(
        category: Category, children: list[CategoryResponse] | None = None
    ) -> CategoryResponse:
        return CategoryResponse(
            id=category.id,
            name=category.name,
            direction=CategoryDirection(category.direction),
            parent_id=category.parent_id,
            icon=category.icon,
            color_hex=category.color_hex,
            aliases=list(category.aliases),
            examples=list(category.examples),
            is_balance_adjustment=category.is_balance_adjustment,
            sort_order=category.sort_order,
            archived_at=category.archived_at,
            usage_count=category.usage_count,
            version=category.version,
            created_at=category.created_at,
            updated_at=category.updated_at,
            children=children or [],
        )

    async def list(
        self,
        *,
        direction: CategoryDirection | None,
        include_archived: bool,
    ) -> list[CategoryResponse]:
        categories = await self.repository.list(
            direction=direction, include_archived=include_archived
        )
        children_by_parent: dict[UUID, list[CategoryResponse]] = {}
        for category in categories:
            if category.parent_id is not None:
                children_by_parent.setdefault(category.parent_id, []).append(
                    self.response(category)
                )
        return [
            self.response(category, children_by_parent.get(category.id, []))
            for category in categories
            if category.parent_id is None
        ]

    async def get(self, category_id: UUID) -> CategoryResponse:
        category = await self._required(category_id)
        children = [self.response(child) for child in await self.repository.children(category.id)]
        return self.response(category, children)

    async def order_state(
        self, *, parent_id: UUID | None, direction: CategoryDirection
    ) -> CategoryOrderState:
        if parent_id is not None:
            parent = await self._required(parent_id)
            if parent.parent_id is not None or parent.direction != direction.value:
                invalid(
                    "invalid_category_hierarchy",
                    "parent_id and direction do not identify a list",
                )
        siblings = await self.repository.active_siblings(parent_id=parent_id, direction=direction)
        return CategoryOrderState(
            parent_id=parent_id,
            direction=direction,
            items=[self.response(item) for item in siblings],
            list_revision=self._order_revision(parent_id, direction, siblings),
        )

    async def create(self, draft: CategoryDraft, *, commit: bool = True) -> CategoryResponse:
        await acquire_p2_mutation_lock(self.session)
        await self._validate_parent(draft.parent_id, draft.direction)
        await self._ensure_name_available(draft.name, draft.parent_id)
        category = Category(
            name=draft.name,
            direction=draft.direction.value,
            parent_id=draft.parent_id,
            icon=draft.icon,
            color_hex=draft.color_hex,
            aliases=draft.aliases,
            examples=draft.examples,
            is_balance_adjustment=draft.is_balance_adjustment,
            sort_order=await self.repository.next_sort_order(draft.parent_id, draft.direction),
        )
        self.repository.add(category)
        if commit:
            await self._commit_name_safe()
            await self.session.refresh(category)
        else:
            await self.session.flush()
        return self.response(category)

    async def update(self, category_id: UUID, patch: CategoryPatch) -> CategoryResponse:
        await acquire_p2_mutation_lock(self.session)
        category = await self._required(category_id, for_update=True)
        check_version(category.version, patch.expected_version)
        updates = patch.model_dump(exclude={"expected_version"}, exclude_unset=True)
        if (
            category.usage_count > 0
            and "direction" in updates
            and updates["direction"].value != category.direction
        ):
            conflict("category_in_use", "A used category cannot change direction")
        new_parent_id = updates.get("parent_id", category.parent_id)
        direction = CategoryDirection(updates.get("direction", category.direction))
        children = await self.repository.children(category.id)
        if children and (new_parent_id is not None or direction.value != category.direction):
            invalid(
                "invalid_category_hierarchy",
                "A category with children must remain a root with the same direction",
            )
        if new_parent_id == category.id:
            invalid("invalid_category_hierarchy", "A category cannot be its own parent")
        await self._validate_parent(new_parent_id, direction)
        name = updates.get("name", category.name)
        if category.archived_at is None:
            await self._ensure_name_available(name, new_parent_id, excluding=category.id)
        for field, value in updates.items():
            if isinstance(value, CategoryDirection):
                value = value.value
            setattr(category, field, value)
        self._touch(category)
        await self._commit_name_safe()
        await self.session.refresh(category)
        return self.response(category)

    async def archive(self, category_id: UUID, expected_version: int) -> CategoryResponse:
        await acquire_p2_mutation_lock(self.session)
        category = await self._required(category_id, for_update=True)
        check_version(category.version, expected_version)
        if category.archived_at is None:
            if await self.repository.children(category.id, active_only=True):
                conflict(
                    "category_has_children",
                    "Archive active children before archiving this category",
                )
            category.archived_at = utc_now()
            self._touch(category)
            await self.session.commit()
            await self.session.refresh(category)
        return self.response(category)

    async def restore(self, category_id: UUID, expected_version: int) -> CategoryResponse:
        await acquire_p2_mutation_lock(self.session)
        category = await self._required(category_id, for_update=True)
        check_version(category.version, expected_version)
        if category.archived_at is not None:
            await self._validate_parent(category.parent_id, CategoryDirection(category.direction))
            await self._ensure_name_available(
                category.name, category.parent_id, excluding=category.id
            )
            category.archived_at = None
            self._touch(category)
            await self._commit_name_safe()
            await self.session.refresh(category)
        return self.response(category)

    async def delete(self, category_id: UUID, expected_version: int) -> None:
        await acquire_p2_mutation_lock(self.session)
        category = await self._required(category_id, for_update=True)
        check_version(category.version, expected_version)
        if await self.repository.children(category.id):
            conflict("category_has_children", "A category with children cannot be deleted")
        if category.usage_count != 0:
            conflict("category_in_use", "The category is referenced and cannot be deleted")
        await self.repository.delete(category)
        try:
            await self.session.commit()
        except IntegrityError:
            await self.session.rollback()
            conflict("category_in_use", "The category is referenced and cannot be deleted")

    async def reorder(
        self,
        *,
        parent_id: UUID | None,
        ordered_ids: list[UUID],
        expected_list_revision: str | None,
    ) -> list[CategoryResponse]:
        await acquire_p2_mutation_lock(self.session)
        if not ordered_ids or len(ordered_ids) != len(set(ordered_ids)):
            invalid(
                "invalid_category_hierarchy",
                "ordered_ids must identify one complete sibling set exactly once",
            )
        first = await self._required(ordered_ids[0])
        if first.parent_id != parent_id:
            invalid("invalid_category_hierarchy", "ordered_ids do not match parent_id")
        direction = CategoryDirection(first.direction)
        siblings = await self.repository.active_siblings(parent_id=parent_id, direction=direction)
        if set(ordered_ids) != {category.id for category in siblings}:
            invalid(
                "invalid_category_hierarchy",
                "ordered_ids must contain every active sibling exactly once",
            )
        current_list_revision = self._order_revision(parent_id, direction, siblings)
        order_scope = self._order_scope(parent_id, direction)
        reload_path = self._order_reload_path(order_scope)
        if expected_list_revision is None:
            conflict(
                "list_revision_required",
                "Reordering requires the current category list revision",
                details={
                    "reason": "list_revision_required",
                    "order_scope": order_scope,
                    "reload_path": reload_path,
                    "safe_to_reload": True,
                },
            )
        if current_list_revision != expected_list_revision:
            conflict(
                "list_revision_conflict",
                "The category order changed by another request",
                details={
                    "reason": "list_changed",
                    "current_list_revision": current_list_revision,
                    "expected_list_revision": expected_list_revision,
                    "order_scope": order_scope,
                    "reload_path": reload_path,
                    "safe_to_reload": True,
                },
            )
        by_id = {category.id: category for category in siblings}
        for order, category_id in enumerate(ordered_ids):
            category = by_id[category_id]
            category.sort_order = order
            self._touch(category)
        await self.session.commit()
        return [self.response(by_id[category_id]) for category_id in ordered_ids]

    async def merge(
        self,
        *,
        source_id: UUID,
        target_id: UUID,
        source_expected_version: int,
        target_expected_version: int,
    ) -> CategoryResponse:
        await acquire_p2_mutation_lock(self.session)
        if source_id == target_id:
            invalid("invalid_category_hierarchy", "Source and target must be distinct")
        source = await self._required(source_id, for_update=True)
        target = await self._required(target_id, for_update=True)
        check_version(source.version, source_expected_version)
        check_version(target.version, target_expected_version)
        if source.archived_at is not None or target.archived_at is not None:
            invalid("invalid_category_hierarchy", "Merge requires active categories")
        if source.direction != target.direction:
            invalid("invalid_category_hierarchy", "Merge requires matching directions")
        if (source.parent_id is None) != (target.parent_id is None):
            invalid(
                "invalid_category_hierarchy",
                "Merge requires two roots or two children",
            )
        source_children = await self.repository.children(source.id)
        ledger = TransactionRepository(self.session)
        reassigned = await ledger.reassign_category(source.id, target.id)
        source.usage_count -= reassigned
        target.usage_count += reassigned
        if source.parent_id is None and target.parent_id is None:
            target_by_name = {
                child.name.casefold(): child
                for child in await self.repository.children(target.id, active_only=True)
            }
            for child in source_children:
                matching = target_by_name.get(child.name.casefold())
                if child.archived_at is None and matching is not None:
                    child_reassigned = await ledger.reassign_category(child.id, matching.id)
                    child.usage_count -= child_reassigned
                    matching.usage_count += child_reassigned
                    child.archived_at = utc_now()
                    self._touch(child)
                    continue
                child.parent_id = target.id
                self._touch(child)
        source.archived_at = utc_now()
        self._touch(source)
        self._touch(target)
        await self._commit_name_safe()
        await self.session.refresh(target)
        return self.response(target)

    async def split(
        self,
        *,
        root_id: UUID,
        root_expected_version: int,
        drafts: list[CategoryDraft],
    ) -> list[CategoryResponse]:
        await acquire_p2_mutation_lock(self.session)
        root = await self._required(root_id, for_update=True)
        check_version(root.version, root_expected_version)
        if root.archived_at is not None or root.parent_id is not None:
            invalid("invalid_category_hierarchy", "Split requires an active root category")
        existing_names = {
            child.name.casefold()
            for child in await self.repository.children(root.id, active_only=True)
        }
        draft_names: set[str] = set()
        for draft in drafts:
            if draft.parent_id not in {None, root.id}:
                invalid("invalid_category_hierarchy", "Split children must use the requested root")
            if draft.direction.value != root.direction:
                invalid("invalid_category_hierarchy", "Child direction must match its root")
            key = draft.name.casefold()
            if key in existing_names or key in draft_names:
                conflict("category_name_conflict", "An active sibling already uses this name")
            draft_names.add(key)
        next_order = await self.repository.next_sort_order(
            root.id, CategoryDirection(root.direction)
        )
        created: list[Category] = []
        for offset, draft in enumerate(drafts):
            category = Category(
                name=draft.name,
                direction=draft.direction.value,
                parent_id=root.id,
                icon=draft.icon,
                color_hex=draft.color_hex,
                aliases=draft.aliases,
                examples=draft.examples,
                sort_order=next_order + offset,
            )
            self.repository.add(category)
            created.append(category)
        self._touch(root)
        await self._commit_name_safe()
        for category in created:
            await self.session.refresh(category)
        return [self.response(category) for category in created]

    async def merge_preview(
        self, source_id: UUID, request: CategoryMergePreviewRequest
    ) -> CategoryMergePreview:
        if source_id == request.target_id:
            invalid("invalid_category_hierarchy", "Source and target must be distinct")
        source = await self._required(source_id)
        target = await self._required(request.target_id)
        self._validate_merge_pair(
            source,
            target,
            request.source_expected_version,
            request.target_expected_version,
        )
        source_count, source_amount = await self.repository.dependency(source.id)
        requirements: list[CategoryChildMappingRequirement] = []
        if source.parent_id is None:
            target_children = await self.repository.children(target.id, active_only=True)
            for child in await self.repository.children(source.id, active_only=True):
                requirements.append(
                    CategoryChildMappingRequirement(
                        source_child_id=child.id,
                        source_child_name=child.name,
                        target_child_ids=[item.id for item in target_children],
                    )
                )
        source_children = await self.repository.children(source.id, active_only=True)
        target_children = await self.repository.children(target.id, active_only=True)
        dependency_categories = [source, target, *source_children, *target_children]
        category_ids = [item.id for item in [source, *source_children]]
        transaction_ids = [
            transaction_id
            for category_id in category_ids
            for transaction_id in await self.repository.category_transaction_ids(category_id)
        ]
        transactions = await TransactionRepository(self.session).get_many_for_update(
            transaction_ids
        )
        payload = {
            "source_id": str(source.id),
            "target_id": str(target.id),
            "source_version": source.version,
            "target_version": target.version,
            "source_child_ids": [str(item.source_child_id) for item in requirements],
            "active_child_ids_by_parent": self._active_child_ids_payload(
                {source.id: source_children, target.id: target_children}
            ),
            "category_dependencies": [
                self._category_dependency(item) for item in dependency_categories
            ],
            "transaction_dependencies": [
                self._transaction_dependency(item) for item in transactions
            ],
            "transaction_scope_category_ids": [str(item) for item in category_ids],
            "data_revision": await self._data_revision(),
        }
        preview = CategoryTransformPreview(
            kind="merge",
            request_hash=self._hash(payload),
            payload=payload,
        )
        self.session.add(preview)
        await self.session.commit()
        return CategoryMergePreview(
            preview_token=preview.id,
            source=CategoryDependency(
                category_id=source.id,
                transaction_count=source_count,
                amount_minor=source_amount,
            ),
            target_id=target.id,
            child_mapping_requirements=requirements,
        )

    async def merge_commit(
        self,
        source_id: UUID,
        request: CategoryMergeCommitRequest,
        idempotency_key: UUID,
    ) -> CategoryTransformReceipt:
        request_hash = self._hash(
            {
                "source_id": str(source_id),
                **request.model_dump(mode="json"),
            }
        )
        replay = await self._transform_operation(idempotency_key, request_hash)
        if replay is not None:
            return replay
        await acquire_p2_mutation_lock(self.session)
        replay = await self._transform_operation(idempotency_key, request_hash)
        if replay is not None:
            return replay
        preview = await self._preview(request.preview_token, "merge")
        payload = preview.payload
        if payload.get("source_id") != str(source_id):
            invalid("category_preview_input_mismatch", "The preview does not belong to this source")
        source = await self._required(source_id, for_update=True)
        target = await self._required(self._payload_uuid(payload, "target_id"), for_update=True)
        await self._assert_preview_fresh(payload)
        self._validate_merge_pair(
            source,
            target,
            self._payload_int(payload, "source_version"),
            self._payload_int(payload, "target_version"),
        )
        source_children = await self.repository.children(source.id, active_only=True)
        expected_child_ids = {str(child.id) for child in source_children}
        if expected_child_ids != set(self._payload_strings(payload, "source_child_ids")):
            conflict("category_preview_stale", "The category dependencies changed; preview again")
        mappings = {
            mapping.source_child_id: mapping.target_child_id for mapping in request.child_mappings
        }
        if len(mappings) != len(request.child_mappings) or set(mappings) != {
            child.id for child in source_children
        }:
            invalid("category_child_mapping_required", "Map every active source child exactly once")
        target_children = {
            child.id: child for child in await self.repository.children(target.id, active_only=True)
        }
        for source_child in source_children:
            target_child = target_children.get(mappings[source_child.id])
            if target_child is None or target_child.direction != source_child.direction:
                invalid(
                    "invalid_category_child_mapping",
                    "Each child must map to an active target child",
                )

        previewed_by_category = self._previewed_ids_by_category(payload)
        moved = await self._move_transactions(
            source.id, target.id, transaction_ids=previewed_by_category.get(source.id, [])
        )
        for child in source_children:
            moved += await self._move_transactions(
                child.id,
                mappings[child.id],
                transaction_ids=previewed_by_category.get(child.id, []),
            )
            child.archived_at = utc_now()
            self._touch(child)
        source.archived_at = utc_now()
        self._touch(source)
        self._touch(target)
        receipt = CategoryTransformReceipt(
            action="merge",
            categories=[self.response(target)],
            reclassified_transaction_count=moved,
        )
        self.session.add(
            CategoryTransformOperation(
                preview_id=preview.id,
                idempotency_key=idempotency_key,
                request_hash=request_hash,
                receipt=receipt.model_dump(mode="json"),
            )
        )
        try:
            await self.session.commit()
        except IntegrityError:
            await self.session.rollback()
            replay = await self._transform_operation(idempotency_key, request_hash)
            if replay is not None:
                return replay
            raise
        return receipt

    async def split_preview(
        self, root_id: UUID, request: CategorySplitPreviewRequest
    ) -> CategorySplitPreview:
        root = await self._required(root_id)
        check_version(root.version, request.root_expected_version)
        self._validate_split_root(root)
        self._validate_split_drafts(
            root,
            request.children,
            await self.repository.children(root.id, active_only=True),
        )
        transaction_ids = await self.repository.category_transaction_ids(root.id)
        active_children = await self.repository.children(root.id, active_only=True)
        child_transaction_ids = [
            transaction_id
            for child in active_children
            for transaction_id in await self.repository.category_transaction_ids(child.id)
        ]
        transactions = await TransactionRepository(self.session).get_many_for_update(
            transaction_ids + child_transaction_ids
        )
        count, amount = await self.repository.dependency(root.id)
        payload = {
            "root_id": str(root.id),
            "root_version": root.version,
            "children": [draft.model_dump(mode="json") for draft in request.children],
            "transaction_ids": [str(item) for item in transaction_ids],
            "category_dependencies": [
                self._category_dependency(item) for item in [root, *active_children]
            ],
            "transaction_dependencies": [
                self._transaction_dependency(item) for item in transactions
            ],
            "transaction_scope_category_ids": [
                str(item) for item in [root.id, *[child.id for child in active_children]]
            ],
            "active_child_ids_by_parent": self._active_child_ids_payload(
                {root.id: active_children}
            ),
            "data_revision": await self._data_revision(),
        }
        preview = CategoryTransformPreview(
            kind="split", request_hash=self._hash(payload), payload=payload
        )
        self.session.add(preview)
        await self.session.commit()
        return CategorySplitPreview(
            preview_token=preview.id,
            root=CategoryDependency(
                category_id=root.id, transaction_count=count, amount_minor=amount
            ),
            required_transaction_ids=transaction_ids,
            child_names=[draft.name for draft in request.children],
        )

    async def split_commit(
        self,
        root_id: UUID,
        request: CategorySplitCommitRequest,
        idempotency_key: UUID,
    ) -> CategoryTransformReceipt:
        request_hash = self._hash({"root_id": str(root_id), **request.model_dump(mode="json")})
        replay = await self._transform_operation(idempotency_key, request_hash)
        if replay is not None:
            return replay
        await acquire_p2_mutation_lock(self.session)
        replay = await self._transform_operation(idempotency_key, request_hash)
        if replay is not None:
            return replay
        preview = await self._preview(request.preview_token, "split")
        payload = preview.payload
        if payload.get("root_id") != str(root_id):
            invalid("category_preview_input_mismatch", "The preview does not belong to this root")
        root = await self._required(root_id, for_update=True)
        await self._assert_preview_fresh(payload)
        check_version(root.version, self._payload_int(payload, "root_version"))
        self._validate_split_root(root)
        drafts = [
            CategoryDraft.model_validate(item)
            for item in self._payload_objects(payload, "children")
        ]
        self._validate_split_drafts(
            root,
            drafts,
            await self.repository.children(root.id, active_only=True),
        )
        required_ids = {UUID(item) for item in self._payload_strings(payload, "transaction_ids")}
        current_ids = set(await self.repository.category_transaction_ids(root.id))
        if current_ids != required_ids:
            conflict("category_preview_stale", "The category transactions changed; preview again")
        assignments = {item.transaction_id: item.child_name for item in request.assignments}
        if len(assignments) != len(request.assignments) or set(assignments) != required_ids:
            invalid(
                "category_transaction_mapping_required",
                "Assign every previewed transaction exactly once",
            )
        names = {draft.name: draft for draft in drafts}
        if any(name not in names for name in assignments.values()):
            invalid(
                "invalid_category_transaction_mapping",
                "Assignments must use previewed child names",
            )
        next_order = await self.repository.next_sort_order(
            root.id, CategoryDirection(root.direction)
        )
        created: dict[str, Category] = {}
        for offset, draft in enumerate(drafts):
            child = Category(
                name=draft.name,
                direction=root.direction,
                parent_id=root.id,
                icon=draft.icon,
                color_hex=draft.color_hex,
                aliases=draft.aliases,
                examples=draft.examples,
                sort_order=next_order + offset,
            )
            self.repository.add(child)
            created[draft.name] = child
        await self.session.flush()
        moved = 0
        for name, child in created.items():
            moved += await self._move_transactions(
                root.id,
                child.id,
                transaction_ids=[
                    transaction_id
                    for transaction_id, assigned in assignments.items()
                    if assigned == name
                ],
            )
        self._touch(root)
        receipt = CategoryTransformReceipt(
            action="split",
            categories=[self.response(created[draft.name]) for draft in drafts],
            reclassified_transaction_count=moved,
        )
        self.session.add(
            CategoryTransformOperation(
                preview_id=preview.id,
                idempotency_key=idempotency_key,
                request_hash=request_hash,
                receipt=receipt.model_dump(mode="json"),
            )
        )
        try:
            await self.session.commit()
        except IntegrityError:
            await self.session.rollback()
            replay = await self._transform_operation(idempotency_key, request_hash)
            if replay is not None:
                return replay
            conflict("category_name_conflict", "An active sibling already uses this name")
        return receipt

    def _validate_merge_pair(
        self, source: Category, target: Category, source_version: int, target_version: int
    ) -> None:
        check_version(source.version, source_version)
        check_version(target.version, target_version)
        if source.archived_at is not None or target.archived_at is not None:
            invalid("invalid_category_hierarchy", "Merge requires active categories")
        if source.direction != target.direction or (source.parent_id is None) != (
            target.parent_id is None
        ):
            invalid("invalid_category_hierarchy", "Merge requires matching category scopes")

    @staticmethod
    def _validate_split_root(root: Category) -> None:
        if root.archived_at is not None or root.parent_id is not None:
            invalid("invalid_category_hierarchy", "Split requires an active root category")

    @staticmethod
    def _validate_split_drafts(
        root: Category, drafts: list[CategoryDraft], existing: list[Category]
    ) -> None:
        existing_names = {child.name.casefold() for child in existing}
        names: set[str] = set()
        for draft in drafts:
            if draft.parent_id not in {None, root.id} or draft.direction.value != root.direction:
                invalid("invalid_category_hierarchy", "Split children must match the active root")
            key = draft.name.casefold()
            if key in existing_names or key in names:
                conflict("category_name_conflict", "An active sibling already uses this name")
            names.add(key)

    async def _move_transactions(
        self, source_id: UUID, target_id: UUID, *, transaction_ids: list[UUID] | None = None
    ) -> int:
        ids = (
            transaction_ids
            if transaction_ids is not None
            else await self.repository.category_transaction_ids(source_id)
        )
        if not ids:
            return 0
        transactions = await TransactionRepository(self.session).get_many_for_update(ids)
        if {transaction.id for transaction in transactions} != set(ids):
            conflict("category_preview_stale", "The category transactions changed; preview again")
        transaction_service = TransactionService(self.session)
        for transaction in transactions:
            if transaction.category_id != source_id:
                conflict(
                    "category_preview_stale", "The category transactions changed; preview again"
                )
            transaction.category_id = target_id
            transaction.version += 1
            transaction.updated_at = utc_now()
            response = await transaction_service.response_with_relation(
                transaction, list(transaction.postings)
            )
            transaction_service.record_external_update_revision(transaction, response)
        repository = TransactionRepository(self.session)
        await repository.adjust_category_usage(source_id, -len(transactions))
        await repository.adjust_category_usage(target_id, len(transactions))
        return len(transactions)

    async def _preview(self, preview_id: UUID, kind: str) -> CategoryTransformPreview:
        preview = await self.session.get(CategoryTransformPreview, preview_id)
        if preview is None or preview.kind != kind:
            invalid("category_preview_not_found", "The preview token is invalid")
        if preview.expires_at <= utc_now():
            invalid("category_preview_expired", "The preview token expired; preview again")
        return preview

    async def _data_revision(self) -> int:
        revision = await self.session.scalar(
            select(DataRevision.revision).where(DataRevision.id == 1)
        )
        return int(revision or 0)

    @staticmethod
    def _category_dependency(category: Category) -> dict[str, object]:
        return {
            "id": str(category.id),
            "version": category.version,
            "parent_id": str(category.parent_id) if category.parent_id else None,
            "archived_at": category.archived_at.isoformat() if category.archived_at else None,
        }

    @staticmethod
    def _transaction_dependency(transaction: LedgerTransaction) -> dict[str, object]:
        return {
            "id": str(transaction.id),
            "version": transaction.version,
            "category_id": str(transaction.category_id) if transaction.category_id else None,
            "voided_at": transaction.voided_at.isoformat() if transaction.voided_at else None,
            "kind": transaction.kind,
            "occurred_at": transaction.occurred_at.isoformat(),
            "postings": [
                {
                    "account_id": str(posting.account_id),
                    "amount_minor": posting.amount_minor,
                    "role": posting.role,
                    "position": posting.position,
                }
                for posting in transaction.postings
            ],
        }

    async def _assert_preview_fresh(self, payload: dict[str, object]) -> None:
        # data_revision is retained in the token as diagnostic context only.  It
        # includes unrelated formal writes, so it must not invalidate a preview.
        self._payload_int(payload, "data_revision")
        categories = self._payload_objects(payload, "category_dependencies")
        ids = [self._payload_uuid(item, "id") for item in categories]
        current: dict[UUID, Category] = {}
        for category_id in ids:
            category = await self.repository.get(category_id, for_update=True)
            if category is None:
                conflict(
                    "category_preview_stale", "The category dependencies changed; preview again"
                )
            current[category_id] = category
        if [self._category_dependency(current[category_id]) for category_id in ids] != categories:
            conflict("category_preview_stale", "The category dependencies changed; preview again")
        await self._assert_active_child_sets(payload)
        dependencies = self._payload_objects(payload, "transaction_dependencies")
        scopes = [
            UUID(item) for item in self._payload_strings(payload, "transaction_scope_category_ids")
        ]
        expected_by_category = self._previewed_ids_by_category(payload)
        for category_id in scopes:
            if set(await self.repository.category_transaction_ids(category_id)) != set(
                expected_by_category.get(category_id, [])
            ):
                conflict(
                    "category_preview_stale", "The category transactions changed; preview again"
                )
        transaction_ids = [self._payload_uuid(item, "id") for item in dependencies]
        transactions = await TransactionRepository(self.session).get_many_for_update(
            transaction_ids
        )
        if len(transactions) != len(transaction_ids):
            conflict("category_preview_stale", "The category dependencies changed; preview again")
        actual = {str(item.id): self._transaction_dependency(item) for item in transactions}
        if any(actual.get(str(item["id"])) != item for item in dependencies):
            conflict("category_preview_stale", "The category dependencies changed; preview again")

    async def _assert_active_child_sets(self, payload: dict[str, object]) -> None:
        raw_sets = payload.get("active_child_ids_by_parent")
        if not isinstance(raw_sets, dict):
            invalid("category_preview_not_found", "The preview token is invalid")
        child_sets = cast(dict[object, object], raw_sets)
        for raw_parent_id, raw_child_ids in child_sets.items():
            if not isinstance(raw_parent_id, str) or not isinstance(raw_child_ids, list):
                invalid("category_preview_not_found", "The preview token is invalid")
            try:
                parent_id = UUID(raw_parent_id)
                child_ids = cast(list[object], raw_child_ids)
                if not all(isinstance(raw_child_id, str) for raw_child_id in child_ids):
                    invalid("category_preview_not_found", "The preview token is invalid")
                expected = {UUID(cast(str, raw_child_id)) for raw_child_id in child_ids}
            except (TypeError, ValueError):
                invalid("category_preview_not_found", "The preview token is invalid")
            if len(expected) != len(child_ids):
                invalid("category_preview_not_found", "The preview token is invalid")
            current = {
                child.id for child in await self.repository.children(parent_id, active_only=True)
            }
            if current != expected:
                conflict(
                    "category_preview_stale", "The category dependencies changed; preview again"
                )

    @staticmethod
    def _active_child_ids_payload(
        children_by_parent: dict[UUID, list[Category]],
    ) -> dict[str, list[str]]:
        return {
            str(parent_id): [str(child.id) for child in children]
            for parent_id, children in children_by_parent.items()
        }

    def _previewed_ids_by_category(self, payload: dict[str, object]) -> dict[UUID, list[UUID]]:
        result: dict[UUID, list[UUID]] = {}
        for dependency in self._payload_objects(payload, "transaction_dependencies"):
            category_id = (
                self._payload_uuid(dependency, "category_id")
                if dependency.get("category_id") is not None
                else None
            )
            if category_id is not None:
                result.setdefault(category_id, []).append(self._payload_uuid(dependency, "id"))
        return result

    async def _transform_operation(
        self, idempotency_key: UUID, request_hash: str
    ) -> CategoryTransformReceipt | None:
        operation = await self.session.scalar(
            select(CategoryTransformOperation).where(
                CategoryTransformOperation.idempotency_key == idempotency_key
            )
        )
        if operation is None:
            return None
        if operation.request_hash != request_hash:
            conflict("idempotency_key_reused", "Idempotency-Key was used for a different request")
        return CategoryTransformReceipt.model_validate(operation.receipt)

    @staticmethod
    def _payload_int(payload: dict[str, object], key: str) -> int:
        value = payload.get(key)
        if isinstance(value, bool) or not isinstance(value, int):
            invalid("category_preview_not_found", "The preview token is invalid")
        return value

    @staticmethod
    def _payload_uuid(payload: dict[str, object], key: str) -> UUID:
        value = payload.get(key)
        if not isinstance(value, str):
            invalid("category_preview_not_found", "The preview token is invalid")
        try:
            return UUID(value)
        except ValueError:
            invalid("category_preview_not_found", "The preview token is invalid")

    @staticmethod
    def _payload_strings(payload: dict[str, object], key: str) -> list[str]:
        value = payload.get(key)
        if not isinstance(value, list):
            invalid("category_preview_not_found", "The preview token is invalid")
        values = cast(list[object], value)
        if not all(isinstance(item, str) for item in values):
            invalid("category_preview_not_found", "The preview token is invalid")
        return [cast(str, item) for item in values]

    @staticmethod
    def _payload_objects(payload: dict[str, object], key: str) -> list[dict[str, object]]:
        value = payload.get(key)
        if not isinstance(value, list):
            invalid("category_preview_not_found", "The preview token is invalid")
        values = cast(list[object], value)
        if not all(isinstance(item, dict) for item in values):
            invalid("category_preview_not_found", "The preview token is invalid")
        return [cast(dict[str, object], item) for item in values]

    @staticmethod
    def _hash(payload: object) -> str:
        return hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        ).hexdigest()

    async def _required(self, category_id: UUID, *, for_update: bool = False) -> Category:
        category = await self.repository.get(category_id, for_update=for_update)
        if category is None:
            not_found("category_not_found", "The category does not exist")
        return category

    @staticmethod
    def _order_revision(
        parent_id: UUID | None, direction: CategoryDirection, categories: list[Category]
    ) -> str:
        return list_revision(
            f"categories:{parent_id or 'root'}:{direction.value}",
            (
                (category.id, category.version, category.sort_order, category.archived_at)
                for category in categories
            ),
        )

    @staticmethod
    def _order_scope(parent_id: UUID | None, direction: CategoryDirection) -> dict[str, str | None]:
        return {
            "parent_id": str(parent_id) if parent_id is not None else None,
            "direction": direction.value,
        }

    @staticmethod
    def _order_reload_path(order_scope: dict[str, str | None]) -> str:
        query = {"direction": order_scope["direction"]}
        if order_scope["parent_id"] is not None:
            query["parent_id"] = order_scope["parent_id"]
        return f"/api/v1/categories/order-state?{urlencode(query)}"

    async def _validate_parent(
        self,
        parent_id: UUID | None,
        direction: CategoryDirection,
    ) -> None:
        if parent_id is None:
            return
        parent = await self.repository.get(parent_id)
        if (
            parent is None
            or parent.parent_id is not None
            or parent.archived_at is not None
            or parent.direction != direction.value
        ):
            invalid(
                "invalid_category_hierarchy",
                "Parent must be an active root with the same direction",
            )

    async def _ensure_name_available(
        self,
        name: str,
        parent_id: UUID | None,
        *,
        excluding: UUID | None = None,
    ) -> None:
        if await self.repository.active_sibling_name_exists(
            name, parent_id=parent_id, excluding=excluding
        ):
            conflict("category_name_conflict", "An active sibling already uses this name")

    async def _commit_name_safe(self) -> None:
        try:
            await self.session.commit()
        except IntegrityError as error:
            await self.session.rollback()
            if "uq_categories_active_sibling_name_ci" in str(error.orig):
                conflict("category_name_conflict", "An active sibling already uses this name")
            raise

    @staticmethod
    def _touch(category: Category) -> None:
        category.version += 1
        category.updated_at = utc_now()
