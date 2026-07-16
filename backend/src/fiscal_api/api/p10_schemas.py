from enum import StrEnum
from uuid import UUID

from pydantic import Field, StrictInt, field_validator

from fiscal_api.api.p3_schemas import APIModel, TransactionResponse


class TransactionClassification(StrEnum):
    ALL = "all"
    CATEGORIZED = "categorized"
    UNCATEGORIZED = "uncategorized"


class BatchCategoryItem(APIModel):
    transaction_id: UUID
    expected_version: StrictInt = Field(ge=1)


class BatchCategoryRequest(APIModel):
    items: list[BatchCategoryItem] = Field(min_length=1, max_length=100)
    category_id: UUID

    @field_validator("items")
    @classmethod
    def require_distinct_transactions(
        cls, value: list[BatchCategoryItem]
    ) -> list[BatchCategoryItem]:
        ids = [item.transaction_id for item in value]
        if len(ids) != len(set(ids)):
            raise ValueError("transaction_id values must be distinct")
        return value


class BatchCategoryResponse(APIModel):
    items: list[TransactionResponse]
    changed_count: int = Field(ge=0)
