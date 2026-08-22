from datetime import datetime
from typing import Literal

from fiscal_api.api.schemas import APIModel


class RateLimitPolicy(APIModel):
    read_per_minute: int
    write_per_minute: int
    ai_per_minute: int
    failed_auth_per_minute: int


class BackupOperationStatus(APIModel):
    state: Literal["verified", "stale", "unavailable"]
    created_at: datetime | None = None
    age_hours: int | None = None
    duration_seconds: int | None = None
    size_bytes: int | None = None


class RestoreOperationStatus(APIModel):
    state: Literal["verified", "failed", "stale", "unavailable"]
    checked_at: datetime | None = None
    age_hours: int | None = None
    duration_seconds: int | None = None


class DiskOperationStatus(APIModel):
    state: Literal["healthy", "warning", "failure", "stale", "unavailable"]
    checked_at: datetime | None = None
    used_percent: int | None = None
    warning_percent: int | None = None
    failure_percent: int | None = None


class OperationsStatusResponse(APIModel):
    service_version: str
    release_revision: str | None
    database: Literal["ready"] = "ready"
    alembic_revision: str
    release_alembic_revision: str | None
    schema_state: Literal["current", "mismatch", "unknown"]
    backup: BackupOperationStatus
    restore: RestoreOperationStatus
    disk: DiskOperationStatus
