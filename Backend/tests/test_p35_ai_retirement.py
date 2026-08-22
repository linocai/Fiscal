from fiscal_api.services.archive import _retire_ai_auto_execute


def test_archive_export_restore_and_legacy_rows_cannot_resurrect_auto_execute() -> None:
    for table in ("ai_settings", "ai_execution_policies"):
        source = {"id": 1, "auto_execute_enabled": True, "version": 7}
        sanitized = _retire_ai_auto_execute(table, source)
        assert sanitized["auto_execute_enabled"] is False
        assert source["auto_execute_enabled"] is True
        assert sanitized["version"] == 7

    unrelated = {"id": 1, "auto_execute_enabled": True}
    assert _retire_ai_auto_execute("unrelated_table", unrelated) == unrelated
