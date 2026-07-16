# P12 Production Cutover Runbook

Date: 2026-07-16

This runbook is only for the approved LinoFinance-to-Fiscal migration. It never modifies
LinoFinance. All DSNs are loaded from root-owned server configuration and must not appear in
arguments, logs, reports, screenshots or Git.

## Hard preconditions

- The exact committed release has passed the HZ PostgreSQL 16 shadow drill with 148 created,
  153 skipped, 38 reconciliation checks and zero mismatches.
- An identical shadow rerun has produced 0 created and 148 unchanged.
- Fresh custom-format dumps of both `linofinance` and `fiscal` pass `pg_restore --list`, have
  SHA-256 manifests and mode 0600.
- `fiscal-api`, `linofinance-api` and every legacy write timer/worker are stopped. Ports 8010
  and 8000 are not listening.
- The production target has no Fiscal business rows or P12 provenance before the first apply.
- The source audit and resolved plan still have the approved source fingerprint and no
  conflicts.

Any failed condition stops the cutover. Keep both APIs stopped, preserve evidence and do not
repair production with ad-hoc SQL.

## Protected environment

From `/opt/fiscal/current/backend`, load the async Fiscal target URL and read-only legacy URL
inside a protected root shell. Then set:

```sh
export FISCAL_MIGRATION_CODE_REVISION="$(sed -n 's/^revision=//p' /opt/fiscal/current/RELEASE)"
export FISCAL_MIGRATION_PRODUCTION_CONFIRM='fiscal:APPROVED_SOURCE_FINGERPRINT'
```

The CLI independently requires `current_database()='fiscal'`, the exact approved fingerprint,
no other client connection and either a pristine target or a same-source provenance replay.

## Apply, reconcile and prove idempotency

Use a new root-only evidence directory and never overwrite it:

```sh
install -d -m 0700 /var/lib/fiscal/operations/p12-production-UTC_TIMESTAMP

python -m fiscal_api.cli.legacy_migration audit --output /var/lib/fiscal/operations/p12-production-UTC_TIMESTAMP/legacy-audit.json
python -m fiscal_api.cli.legacy_migration plan --output /var/lib/fiscal/operations/p12-production-UTC_TIMESTAMP/migration-plan.json
python -m fiscal_api.cli.legacy_migration production-apply --output /var/lib/fiscal/operations/p12-production-UTC_TIMESTAMP/migration-apply.json
python -m fiscal_api.cli.legacy_migration production-reconcile --output /var/lib/fiscal/operations/p12-production-UTC_TIMESTAMP/reconciliation.json
python -m fiscal_api.cli.legacy_migration production-apply --output /var/lib/fiscal/operations/p12-production-UTC_TIMESTAMP/migration-reapply.json
python -m fiscal_api.cli.legacy_migration production-reconcile --output /var/lib/fiscal/operations/p12-production-UTC_TIMESTAMP/rereconciliation.json

unset FISCAL_MIGRATION_PRODUCTION_CONFIRM FISCAL_MIGRATION_CODE_REVISION
```

Expected evidence is exactly 148 created on the first apply, 0 created / 148 unchanged on the
second, and 38 checks / 0 mismatches on both reconciliations. Reports must remain mode 0600.

## Resume and client verification

Start Fiscal, verify loopback readiness and public HTTPS, then verify the migrated balances and
reports from the macOS Release app and the iOS Release Simulator build. LinoFinance remains
available only as the retained legacy reference after the write window. Physical-iPhone Siri,
Back Tap, Photos/OCR and notification acceptance is explicitly deferred to post-release
`v1.0.x` regression by the user.
