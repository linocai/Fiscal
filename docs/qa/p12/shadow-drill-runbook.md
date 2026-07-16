# P12 Shadow Migration Drill Runbook

This gate migrates only into an explicitly named, pre-provisioned empty shadow database. It does not create, replace or drop databases. The target name must contain `shadow` or `drill`; `fiscal`, `linofinance`, `postgres`, `template0` and `template1` are always rejected, case-insensitively.

The drill performs this ordered chain:

1. prove that the target DSN resolves to the explicit target name and that the target has no user tables;
2. create and verify a custom-format backup of the Fiscal baseline;
3. restore that backup into the shadow target;
4. upgrade the shadow schema to the checked release's Alembic head and verify the recorded revision;
5. run the legacy migration CLI's `audit`, `plan`, `apply` and `reconcile` commands;
6. preserve the shadow database and owner-only evidence for review, on success or failure.

No DSN is accepted on the command line or written to a report. PostgreSQL tools receive connections through their process environment. The legacy CLI must keep the source transaction read-only. Reports and the verified dump are mode `0600`, while their directory is mode `0700`.

## Prepare an empty database

Create a fresh database with the approved PostgreSQL operator process. Give it a unique name such as `fiscal_p12_shadow_20260716_01`. Do not reuse a failed or completed target: the preserved database is evidence. Use a new database suffix and a new report-directory path for every rerun; the gate refuses to overwrite an existing evidence directory.

The target role needs schema migration and business-write authority only in this disposable database. The baseline credential needs enough read access for `pg_dump`; the legacy credential must remain read-only.

## Review the dry path

From a checked release:

```sh
infra/production/scripts/p12-shadow-drill.sh \
  --target-database fiscal_p12_shadow_20260716_01 \
  --report-dir /secure/path/p12-shadow-20260716-01
```

This prints the ordered plan without requiring credentials or creating the report directory.

## Execute the shadow-only path

Set the three DSNs in the operator's protected environment, not as arguments. Do not paste them into logs, screenshots or the runbook.

```sh
export FISCAL_SHADOW_BASELINE_DATABASE_URL='REDACTED'
export FISCAL_SHADOW_TARGET_DATABASE_URL='REDACTED'
export FISCAL_SHADOW_TARGET_PG_URL='REDACTED'
export FISCAL_LEGACY_DATABASE_URL='REDACTED'

infra/production/scripts/p12-shadow-drill.sh \
  --target-database fiscal_p12_shadow_20260716_01 \
  --report-dir /secure/path/p12-shadow-20260716-01 \
  --python /opt/fiscal/current/backend/.venv/bin/python \
  --apply

unset FISCAL_SHADOW_BASELINE_DATABASE_URL
unset FISCAL_SHADOW_TARGET_DATABASE_URL
unset FISCAL_SHADOW_TARGET_PG_URL
unset FISCAL_LEGACY_DATABASE_URL
```

`FISCAL_SHADOW_TARGET_DATABASE_URL` is the SQLAlchemy async URL used by Alembic and the
migration CLI (for example, a `postgresql+asyncpg://` URL). `FISCAL_SHADOW_TARGET_PG_URL`
is the equivalent libpq `postgresql://` URL used by `psql` and `pg_restore`. They must
resolve to the same explicitly named shadow database; neither value is written to evidence.
The shell gate parses the libpq URLs in-process and passes individual `PG*` environment
variables to PostgreSQL tools; the password-bearing URL is never placed in process arguments.

For a development checkout, `--python` may point to `backend/.venv/bin/python`. The migration module defaults to `fiscal_api.cli.legacy_migration`; a release with a relocated CLI can pass `--migration-module` without changing this gate.

## Review and production gate

The evidence directory must contain:

- `status.json` with `result=verified` and `stage=complete`;
- a verified `fiscal-baseline-*.dump` plus SHA-256 manifest;
- `alembic-head.txt` matching the checked release;
- `legacy-audit.json`, `migration-plan.json`, `migration-apply.json` and `reconciliation.json`.

Review every skipped/conflict row and reconcile account balances, credit liabilities/cycles, reimbursements and report totals. A successful shell exit alone is not migration approval. Production apply remains blocked until the reports are accepted, both source databases have verified backups, the Fiscal API has an explicit maintenance window, and a separately reviewed production command targets exactly `fiscal`—this shadow script can never target that name.

On failure, do not rerun against the partial target and do not delete its evidence during diagnosis. Provision a new uniquely named empty shadow database, correct the cause, and execute a fresh drill.

## Static verification

The safety contract can be checked without PostgreSQL or credentials:

```sh
python3 -m unittest infra/production/tests/test_p12_shadow_drill.py
bash -n infra/production/scripts/p12-shadow-drill.sh
```
