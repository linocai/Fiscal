from fiscal_api.db.models import (
    MigrationObjectLink,
    MigrationRun,
    MigrationRunMode,
    MigrationRunStatus,
    TransactionSource,
)


def test_p12_provenance_models_and_legacy_source_are_registered() -> None:
    assert TransactionSource.LEGACY_IMPORT.value == "legacy_import"
    assert MigrationRunMode.DRY_RUN.value == "dry_run"
    assert MigrationRunMode.SHADOW.value == "shadow"
    assert MigrationRunMode.PRODUCTION.value == "production"
    assert MigrationRunStatus.RUNNING.value == "running"
    assert MigrationRunStatus.SUCCEEDED.value == "succeeded"
    assert MigrationRunStatus.FAILED.value == "failed"
    assert MigrationRun.__table__.name == "migration_runs"
    assert MigrationObjectLink.__table__.name == "migration_object_links"


def test_p12_source_and_target_identity_constraints_are_explicit() -> None:
    constraints = {
        constraint.name: tuple(column.name for column in constraint.columns)
        for constraint in MigrationObjectLink.__table__.constraints
        if constraint.name is not None and hasattr(constraint, "columns")
    }
    assert constraints["uq_migration_object_links_source_identity"] == (
        "source_database_fingerprint",
        "source_object_type",
        "source_object_id",
    )
    assert constraints["uq_migration_object_links_target_identity"] == (
        "target_object_type",
        "target_object_id",
    )
