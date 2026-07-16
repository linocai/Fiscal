import json
from collections.abc import Mapping
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, cast

from fiscal_api.api.p11_schemas import (
    BackupOperationStatus,
    DiskOperationStatus,
    RestoreOperationStatus,
)
from fiscal_api.core.time import ensure_utc, utc_now

_MAX_STATUS_BYTES = 65_536


class OperationsStatusReader:
    """Read bounded, non-secret facts emitted by root-owned operation jobs."""

    def __init__(
        self,
        directory: Path,
        *,
        backup_stale_hours: int,
        restore_stale_hours: int,
        disk_stale_minutes: int,
    ) -> None:
        self.directory = directory
        self.backup_stale_after = timedelta(hours=backup_stale_hours)
        self.restore_stale_after = timedelta(hours=restore_stale_hours)
        self.disk_stale_after = timedelta(minutes=disk_stale_minutes)

    def backup(self, now: datetime | None = None) -> BackupOperationStatus:
        payload = self._read("latest-backup.json")
        created_at = self._timestamp(payload, "created_at")
        if payload is None or payload.get("result") != "verified" or created_at is None:
            return BackupOperationStatus(state="unavailable")
        size_bytes = self._integer(payload, "size_bytes", minimum=0)
        duration_seconds = self._integer(payload, "duration_seconds", minimum=0)
        if size_bytes is None or duration_seconds is None:
            return BackupOperationStatus(state="unavailable")
        age = ensure_utc(now or utc_now()) - created_at
        return BackupOperationStatus(
            state="stale" if age > self.backup_stale_after else "verified",
            created_at=created_at,
            age_hours=max(0, int(age.total_seconds() // 3600)),
            duration_seconds=duration_seconds,
            size_bytes=size_bytes,
        )

    def restore(self, now: datetime | None = None) -> RestoreOperationStatus:
        payload = self._read("latest-restore-verify.json")
        checked_at = self._timestamp(payload, "checked_at")
        if payload is None or checked_at is None:
            return RestoreOperationStatus(state="unavailable")
        result = payload.get("result")
        if result not in {"verified", "failed"}:
            return RestoreOperationStatus(state="unavailable")
        duration_seconds = self._integer(payload, "duration_seconds", minimum=0)
        if duration_seconds is None:
            return RestoreOperationStatus(state="unavailable")
        age = ensure_utc(now or utc_now()) - checked_at
        state = (
            "failed"
            if result == "failed"
            else ("stale" if age > self.restore_stale_after else "verified")
        )
        return RestoreOperationStatus(
            state=state,
            checked_at=checked_at,
            age_hours=max(0, int(age.total_seconds() // 3600)),
            duration_seconds=duration_seconds,
        )

    def disk(self, now: datetime | None = None) -> DiskOperationStatus:
        payload = self._read("latest-disk.json")
        checked_at = self._timestamp(payload, "checked_at")
        if payload is None or checked_at is None:
            return DiskOperationStatus(state="unavailable")
        reported_state = payload.get("state")
        if reported_state not in {"healthy", "warning", "failure"}:
            return DiskOperationStatus(state="unavailable")
        used = self._integer(payload, "used_percent", minimum=0, maximum=100)
        warning = self._integer(payload, "warning_percent", minimum=1, maximum=99)
        failure = self._integer(payload, "failure_percent", minimum=1, maximum=100)
        if used is None or warning is None or failure is None or warning >= failure:
            return DiskOperationStatus(state="unavailable")
        age = ensure_utc(now or utc_now()) - checked_at
        return DiskOperationStatus(
            state="stale" if age > self.disk_stale_after else reported_state,
            checked_at=checked_at,
            used_percent=used,
            warning_percent=warning,
            failure_percent=failure,
        )

    def _read(self, filename: str) -> Mapping[str, Any] | None:
        path = self.directory / filename
        try:
            if path.stat().st_size > _MAX_STATUS_BYTES:
                return None
            decoded = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            return None
        if not isinstance(decoded, dict):
            return None
        mapping = cast(dict[Any, Any], decoded)
        if not all(isinstance(key, str) for key in mapping):
            return None
        return cast(dict[str, Any], mapping)

    @staticmethod
    def _timestamp(payload: Mapping[str, Any] | None, key: str) -> datetime | None:
        if payload is None or not isinstance(payload.get(key), str):
            return None
        try:
            return ensure_utc(datetime.fromisoformat(str(payload[key]).replace("Z", "+00:00")))
        except ValueError:
            return None

    @staticmethod
    def _integer(
        payload: Mapping[str, Any], key: str, *, minimum: int, maximum: int | None = None
    ) -> int | None:
        value = payload.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
            return None
        if maximum is not None and value > maximum:
            return None
        return value


def read_release_metadata(path: Path) -> tuple[str | None, str | None]:
    try:
        if path.stat().st_size > 4_096:
            return None, None
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None, None
    fields = dict(line.split("=", 1) for line in lines if "=" in line)
    revision = fields.get("revision")
    alembic_head = fields.get("alembic_head")
    if revision is not None and (
        len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision)
    ):
        revision = None
    if alembic_head is not None and (not alembic_head or len(alembic_head) > 128):
        alembic_head = None
    return revision, alembic_head
