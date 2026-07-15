from __future__ import annotations

from datetime import datetime
from typing import Annotated
from uuid import UUID

from pydantic import (
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    StrictInt,
    field_validator,
    model_validator,
)

from fiscal_api.db.models import AccountKind, CategoryDirection


def trimmed(value: str) -> str:
    result = value.strip()
    if not result:
        raise ValueError("value must not be empty")
    return result


TrimmedName = Annotated[str, BeforeValidator(trimmed), Field(max_length=80)]
TrimmedOptional = Annotated[str, BeforeValidator(trimmed), Field(max_length=80)]
MinorUnits = StrictInt


class APIModel(BaseModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)


class AccountDraft(APIModel):
    name: TrimmedName
    kind: AccountKind
    institution: TrimmedOptional | None = None
    last_four: str | None = Field(default=None, pattern=r"^[0-9]{4}$")
    opening_balance_minor: MinorUnits
    credit_limit_minor: MinorUnits | None = None
    statement_day: StrictInt | None = Field(default=None, ge=1, le=28)
    due_day: StrictInt | None = Field(default=None, ge=1, le=28)


class AccountPatch(APIModel):
    expected_version: StrictInt = Field(ge=1)
    name: TrimmedName | None = None
    kind: AccountKind | None = None
    institution: TrimmedOptional | None = None
    last_four: str | None = Field(default=None, pattern=r"^[0-9]{4}$")
    opening_balance_minor: MinorUnits | None = None
    credit_limit_minor: MinorUnits | None = None
    statement_day: StrictInt | None = Field(default=None, ge=1, le=28)
    due_day: StrictInt | None = Field(default=None, ge=1, le=28)

    @model_validator(mode="after")
    def reject_null_required_fields(self) -> AccountPatch:
        for field in ("name", "kind", "opening_balance_minor"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null")
        return self


class AccountResponse(APIModel):
    id: UUID
    name: str
    kind: AccountKind
    institution: str | None
    last_four: str | None
    opening_balance_minor: int
    current_balance_minor: int
    credit_limit_minor: int | None
    statement_day: int | None
    due_day: int | None
    sort_order: int
    archived_at: datetime | None
    usage_count: int
    version: int
    created_at: datetime
    updated_at: datetime


class VersionRequest(APIModel):
    expected_version: StrictInt = Field(ge=1)


class AccountOrderRequest(APIModel):
    ordered_ids: list[UUID]


def normalize_terms(values: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("values must not be empty")
        if len(cleaned) > 40:
            raise ValueError("each value must contain at most 40 characters")
        key = cleaned.casefold()
        if key not in seen:
            seen.add(key)
            result.append(cleaned)
    if len(result) > 20:
        raise ValueError("at most 20 unique values are allowed")
    return result


class CategoryDraft(APIModel):
    name: TrimmedName
    direction: CategoryDirection
    parent_id: UUID | None = None
    icon: TrimmedOptional
    color_hex: str = Field(pattern=r"^#[0-9A-Fa-f]{6}$")
    aliases: list[str] = Field(default_factory=list)
    examples: list[str] = Field(default_factory=list)

    @field_validator("color_hex")
    @classmethod
    def uppercase_color(cls, value: str) -> str:
        return value.upper()

    @field_validator("aliases", "examples")
    @classmethod
    def clean_terms(cls, values: list[str]) -> list[str]:
        return normalize_terms(values)


class CategoryPatch(APIModel):
    expected_version: StrictInt = Field(ge=1)
    name: TrimmedName | None = None
    direction: CategoryDirection | None = None
    parent_id: UUID | None = None
    icon: TrimmedOptional | None = None
    color_hex: str | None = Field(default=None, pattern=r"^#[0-9A-Fa-f]{6}$")
    aliases: list[str] | None = None
    examples: list[str] | None = None

    @model_validator(mode="after")
    def reject_null_required_fields(self) -> CategoryPatch:
        for field in ("name", "direction", "icon", "color_hex", "aliases", "examples"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null")
        return self

    @field_validator("color_hex")
    @classmethod
    def uppercase_optional_color(cls, value: str | None) -> str | None:
        return value.upper() if value is not None else None

    @field_validator("aliases", "examples")
    @classmethod
    def clean_optional_terms(cls, values: list[str] | None) -> list[str] | None:
        return normalize_terms(values) if values is not None else None


class CategoryResponse(APIModel):
    id: UUID
    name: str
    direction: CategoryDirection
    parent_id: UUID | None
    icon: str
    color_hex: str
    aliases: list[str]
    examples: list[str]
    sort_order: int
    archived_at: datetime | None
    usage_count: int
    version: int
    created_at: datetime
    updated_at: datetime
    # Recursive response mirrors the two-level API tree; Pyright cannot fully resolve
    # Pydantic's runtime forward-reference rebuild for this declaration.
    children: list[CategoryResponse] = Field(  # pyright: ignore[reportUnknownVariableType]
        default_factory=list
    )


class CategoryOrderRequest(APIModel):
    parent_id: UUID | None = None
    ordered_ids: list[UUID]


class CategoryMergeRequest(APIModel):
    target_id: UUID
    source_expected_version: StrictInt = Field(ge=1)
    target_expected_version: StrictInt = Field(ge=1)


class CategorySplitRequest(APIModel):
    root_expected_version: StrictInt = Field(ge=1)
    children: list[CategoryDraft] = Field(min_length=2)
