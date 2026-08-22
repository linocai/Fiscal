from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class P22APIModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class DataRevisionResponse(P22APIModel):
    revision: int
    scopes: list[str] = []


class ArchiveExportRequest(P22APIModel):
    password: str = Field(min_length=12, max_length=128)
    # The public app/API contract must never make raw AI payloads portable.
    # Operator-only CLI export retains its separate explicit capability.
    include_ai_raw: Literal[False] = False


class ArchiveManifestResponse(P22APIModel):
    archive_schema: str
    api_schema: str
    exported_at: datetime
    business_timezone: str
    currency: str
    database_revision: str
    data_revision: int
    entity_counts: dict[str, int]
    payload_sha256: str
    includes_ai_raw: bool
