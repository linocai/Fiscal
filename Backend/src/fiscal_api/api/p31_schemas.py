from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import Field, StrictInt, field_validator

from fiscal_api.api.p2_schemas import (
    APIModel,
    CategoryResponse,
)


class MerchantMappingRequest(APIModel):
    merchant_name: str = Field(min_length=1, max_length=120)
    aliases: list[str] = Field(default_factory=list, max_length=30)
    expected_mapping_version: StrictInt | None = Field(default=None, ge=1)

    @field_validator("merchant_name")
    @classmethod
    def clean_merchant_name(cls, value: str) -> str:
        name = value.strip()
        if not name:
            raise ValueError("merchant name must not be empty")
        return name

    @field_validator("aliases")
    @classmethod
    def clean_aliases(cls, values: list[str]) -> list[str]:
        aliases = [value.strip() for value in values]
        if any(not value or len(value) > 120 for value in aliases):
            raise ValueError("merchant aliases must be 1-120 characters")
        return aliases


class MerchantMappingReleaseRequest(APIModel):
    expected_mapping_version: StrictInt = Field(ge=1)


class MerchantResponse(APIModel):
    id: UUID
    name: str
    aliases: list[str]
    version: int
    archived_at: datetime | None
    created_at: datetime
    updated_at: datetime


class MerchantMappingResponse(APIModel):
    transaction_id: UUID
    merchant: MerchantResponse
    mapping_version: int
    confirmed_at: datetime
    provenance: str = "user_confirmed"


class MerchantMappingRead(APIModel):
    mapping: MerchantMappingResponse | None
    suggested_merchant: MerchantResponse | None


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


class CategoryTransformReceipt(APIModel):
    action: str
    categories: list[CategoryResponse]
    reclassified_transaction_count: int
