from __future__ import annotations

from uuid import UUID

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from fiscal_api.api.p2_schemas import (
    CategoryDraft,
    CategoryPatch,
    CategoryResponse,
)
from fiscal_api.core.time import utc_now
from fiscal_api.db.models import Category, CategoryDirection
from fiscal_api.repositories.categories import CategoryRepository
from fiscal_api.repositories.transactions import TransactionRepository
from fiscal_api.services.common import (
    acquire_p2_mutation_lock,
    check_version,
    conflict,
    invalid,
    not_found,
)


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

    async def create(self, draft: CategoryDraft) -> CategoryResponse:
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
            sort_order=await self.repository.next_sort_order(draft.parent_id, draft.direction),
        )
        self.repository.add(category)
        await self._commit_name_safe()
        await self.session.refresh(category)
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

    async def _required(self, category_id: UUID, *, for_update: bool = False) -> Category:
        category = await self.repository.get(category_id, for_update=for_update)
        if category is None:
            not_found("category_not_found", "The category does not exist")
        return category

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
