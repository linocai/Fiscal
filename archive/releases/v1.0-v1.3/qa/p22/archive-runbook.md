# Fiscal Archive v1 operator runbook

This is the supported local export/recovery path until the P22 production gate closes. The archive password is independent of the Fiscal access passphrase and is never passed as an argument or recorded in shell history.

## Export

From `Backend/`, with only `FISCAL_DATABASE_URL` configured for the intended source database:

```sh
uv run python -m fiscal_api.cli.archive_export /secure/location/fiscal-YYYYMMDD.far
```

The command reads one password from standard input (12–128 characters), creates the target path exclusively, and defaults to excluding AI raw input. To explicitly include AI raw input in the encrypted payload, add `--include-ai-raw`. Keep the resulting `.far` and its password separately.

The protected `POST /api/v1/archives/export` endpoint is available to authenticated clients, but its password request body must not be sent to logs, diagnostics, or untrusted clients.

## Isolated recovery

1. Create and migrate an empty, isolated PostgreSQL target to the same Alembic head as the archive manifest. Set only that target as `FISCAL_DATABASE_URL`.
2. Review before any write:

   ```sh
   uv run python -m fiscal_api.cli.archive /secure/location/fiscal-YYYYMMDD.far --dry-run
   ```

3. Compare the printed entity counts, CNY minor-unit posting totals, relationship report, and manifest revision. A wrong password, tampering, incompatible schema, missing field, duplicate primary key, or orphan relation must fail here without an insert.
4. Only after review, apply to the still-empty isolated target:

   ```sh
   uv run python -m fiscal_api.cli.archive /secure/location/fiscal-YYYYMMDD.far --apply --confirm-empty-target
   ```

5. Run the documented database consistency checks and application smoke test against the isolated target. Switch application configuration only after those checks pass. Never merge into or overwrite the current production database.

AI provider credentials/configuration are deliberately absent from v1 archives and must be reconfigured after recovery.
