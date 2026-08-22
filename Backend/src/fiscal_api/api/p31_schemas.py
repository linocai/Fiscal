from __future__ import annotations

from datetime import datetime
from typing import Annotated
from uuid import UUID

from pydantic import BeforeValidator, Field, StrictInt, field_validator

from fiscal_api.api.p2_schemas import (
    APIModel,
    CategoryDraft,
    CategoryResponse,
    TrimmedName,
    normalize_terms,
)


def trim_merchant_name(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("merchant name must be text")
    return value.strip()


MerchantName = Annotated[
    str,
    BeforeValidator(trim_merchant_name),
    Field(min_length=1, max_length=120),
]


class MerchantDraft(APIModel):
    name: MerchantName
    aliases: list[str] = Field(default_factory=list)

    @field_validator("aliases")
    @classmethod
    def clean_aliases(cls, values: list[str]) -> list[str]:
        return normalize_terms(values)


class MerchantPatch(APIModel):
    expected_version: StrictInt = Field(ge=1)
    name: MerchantName | None = None
    aliases: list[str] | None = None

    @field_validator("aliases")
    @classmethod
    def clean_aliases(cls, values: list[str] | None) -> list[str] | None:
        return normalize_terms(values) if values is not None else None


class MerchantResponse(APIModel):
    id: UUID
    name: str
    aliases: list[str]
    version: int
    archived_at: datetime | None
    created_at: datetime
    updated_at: datetime


class MerchantPage(APIModel):
    items: list[MerchantResponse]
    next_cursor: str | None


class MerchantMappingRequest(APIModel):
    merchant_id: UUID
    expected_mapping_version: StrictInt | None = Field(default=None, ge=1)


class MerchantMappingReleaseRequest(APIModel):
    expected_mapping_version: StrictInt = Field(ge=1)


class MerchantMappingResponse(APIModel):
    transaction_id: UUID
    merchant: MerchantResponse
    mapping_version: int
    confirmed_at: datetime
    provenance: str = "user_confirmed"


class MerchantMappingReceipt(APIModel):
    action: str
    mapping: MerchantMappingResponse | None
    transaction_version: int


class TransactionRevisionResponse(APIModel):
    id: UUID
    version: int
    event: str
    snapshot: dict[str, object]
    created_at: datetime


class TransactionRevisionPage(APIModel):
    items: list[TransactionRevisionResponse]
    next_cursor: str | None


class TransactionProvenanceLink(APIModel):
    source_type: str
    target_type: str
    target_id: UUID | None
    deep_link: str | None
    recorded_at: datetime


class TransactionProvenanceResponse(APIModel):
    transaction_id: UUID
    source: str
    links: list[TransactionProvenanceLink]


class CategoryDependency(APIModel):
    category_id: UUID
    transaction_count: int
    amount_minor: int


class CategoryChildMappingRequirement(APIModel):
    source_child_id: UUID
    source_child_name: str
    target_child_ids: list[UUID]


class CategoryMergePreviewRequest(APIModel):
    target_id: UUID
    source_expected_version: StrictInt = Field(ge=1)
    target_expected_version: StrictInt = Field(ge=1)


class CategoryMergePreview(APIModel):
    preview_token: UUID
    source: CategoryDependency
    target_id: UUID
    child_mapping_requirements: list[CategoryChildMappingRequirement]
    atomic: bool = True


class CategoryChildMapping(APIModel):
    source_child_id: UUID
    target_child_id: UUID


def empty_child_mappings() -> list[CategoryChildMapping]:
    return []


class CategoryMergeCommitRequest(APIModel):
    preview_token: UUID
    child_mappings: list[CategoryChildMapping] = Field(default_factory=empty_child_mappings)


class CategorySplitPreviewRequest(APIModel):
    root_expected_version: StrictInt = Field(ge=1)
    children: list[CategoryDraft] = Field(min_length=2)


class CategorySplitAssignment(APIModel):
    transaction_id: UUID
    child_name: TrimmedName


class CategorySplitPreview(APIModel):
    preview_token: UUID
    root: CategoryDependency
    required_transaction_ids: list[UUID]
    child_names: list[str]
    atomic: bool = True


class CategorySplitCommitRequest(APIModel):
    preview_token: UUID
    assignments: list[CategorySplitAssignment]


class CategoryTransformReceipt(APIModel):
    action: str
    categories: list[CategoryResponse]
    reclassified_transaction_count: int
