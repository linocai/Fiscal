import json
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from fiscal_api.core.operations import OperationsStatusReader, read_release_metadata

UTC = ZoneInfo("UTC")
NOW = datetime(2026, 7, 16, 8, 0, tzinfo=UTC)


def _write(directory: Path, filename: str, payload: object) -> None:
    (directory / filename).write_text(json.dumps(payload), encoding="utf-8")


def _reader(directory: Path) -> OperationsStatusReader:
    return OperationsStatusReader(
        directory,
        backup_stale_hours=30,
        restore_stale_hours=192,
        disk_stale_minutes=60,
    )


def test_operation_status_is_truthfully_unavailable_when_files_are_missing(tmp_path: Path) -> None:
    reader = _reader(tmp_path)
    assert reader.backup(NOW).state == "unavailable"
    assert reader.restore(NOW).state == "unavailable"
    assert reader.disk(NOW).state == "unavailable"


def test_operation_status_reports_verified_stale_failed_and_disk_thresholds(tmp_path: Path) -> None:
    _write(
        tmp_path,
        "latest-backup.json",
        {
            "result": "verified",
            "created_at": (NOW - timedelta(hours=31)).isoformat(),
            "duration_seconds": 4,
            "size_bytes": 1024,
        },
    )
    _write(
        tmp_path,
        "latest-restore-verify.json",
        {
            "result": "failed",
            "checked_at": (NOW - timedelta(hours=2)).isoformat(),
            "duration_seconds": 12,
        },
    )
    _write(
        tmp_path,
        "latest-disk.json",
        {
            "state": "warning",
            "checked_at": (NOW - timedelta(minutes=10)).isoformat(),
            "used_percent": 78,
            "warning_percent": 75,
            "failure_percent": 85,
        },
    )
    reader = _reader(tmp_path)
    backup = reader.backup(NOW)
    assert backup.state == "stale" and backup.age_hours == 31 and backup.size_bytes == 1024
    assert reader.restore(NOW).state == "failed"
    disk = reader.disk(NOW)
    assert disk.state == "warning" and disk.used_percent == 78


def test_operation_status_rejects_malformed_or_oversized_values(tmp_path: Path) -> None:
    _write(tmp_path, "latest-backup.json", {"result": "verified", "created_at": "not-a-date"})
    _write(
        tmp_path,
        "latest-disk.json",
        {
            "state": "healthy",
            "checked_at": NOW.isoformat(),
            "used_percent": True,
            "warning_percent": 75,
            "failure_percent": 85,
        },
    )
    assert _reader(tmp_path).backup(NOW).state == "unavailable"
    assert _reader(tmp_path).disk(NOW).state == "unavailable"


def test_release_metadata_accepts_only_bounded_expected_fields(tmp_path: Path) -> None:
    metadata = tmp_path / "RELEASE"
    revision = "a" * 40
    metadata.write_text(f"revision={revision}\nalembic_head=20260716_0010\n", encoding="utf-8")
    assert read_release_metadata(metadata) == (revision, "20260716_0010")
    metadata.write_text("revision=unsafe\nalembic_head=\n", encoding="utf-8")
    assert read_release_metadata(metadata) == (None, None)
