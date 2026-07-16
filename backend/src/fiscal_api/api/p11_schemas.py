from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import Field

from fiscal_api.api.schemas import APIModel


class DeviceTokenSummary(APIModel):
    id: UUID
    label: str
    role: Literal["device", "operator"]
    status: Literal["pending", "active", "revoked"]
    fingerprint: str
    version: int
    created_at: datetime
    activated_at: datetime | None
    last_used_at: datetime | None
    expires_at: datetime | None
    pending_expires_at: datetime | None
    revoked_at: datetime | None
    replaces_id: UUID | None


class DeviceTokenListResponse(APIModel):
    items: list[DeviceTokenSummary]


class DeviceTokenIssueRequest(APIModel):
    label: str = Field(min_length=1, max_length=80)


class ExpectedVersionRequest(APIModel):
    expected_version: int = Field(ge=1)


class DeviceTokenIssuedResponse(APIModel):
    device_token: str
    token: DeviceTokenSummary


class DeviceTokenMutationResponse(APIModel):
    token: DeviceTokenSummary


class DeviceTokenActivationResponse(DeviceTokenMutationResponse):
    revoked_predecessor_id: UUID | None


class TokenCounts(APIModel):
    active: int
    pending: int


class RateLimitPolicy(APIModel):
    read_per_minute: int
    write_per_minute: int
    ai_per_minute: int
    failed_auth_per_minute: int


class SecurityStatusResponse(APIModel):
    authentication_mode: Literal["static", "database"]
    server_time: datetime
    current_device: DeviceTokenSummary | None
    token_counts: TokenCounts
    rate_limits: RateLimitPolicy


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
