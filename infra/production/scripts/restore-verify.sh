#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_apply "${1:-}"
require_root
load_fiscal_env
prepare_state_directories

dump="$(find "$FISCAL_BACKUP_DIR" -maxdepth 1 -type f -name 'fiscal-*.dump' -printf '%T@ %p\n' | sort -nr | sed -n '1{s/^[^ ]* //;p;}')"
[[ -n "$dump" && -f "$dump" ]] || die "no backup is available for restore verification"
manifest="$dump.sha256"
[[ -f "$manifest" ]] || die "backup checksum manifest is missing"

started_epoch="$(date +%s)"
drill_database="fiscal_restore_verify_$(date -u +%Y%m%d%H%M%S)_$$"
result="failed"

finish() {
  local command_status=$?
  run_as_postgres dropdb --if-exists "$drill_database" >/dev/null 2>&1 || true
  local finished_epoch
  finished_epoch="$(date +%s)"
  write_operation_json "$FISCAL_OPERATIONS_DIR/latest-restore-verify.json" \
    "{\"result\":\"$result\",\"checked_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"checked_epoch\":$finished_epoch,\"duration_seconds\":$((finished_epoch - started_epoch)),\"backup_file\":\"$(basename -- "$dump")\"}"
  return "$command_status"
}
trap finish EXIT

(
  cd -- "$FISCAL_BACKUP_DIR"
  sha256sum --check --status "$(basename -- "$manifest")"
)
run_as_postgres pg_restore --list "$dump" >/dev/null

run_as_postgres createdb --template=template0 "$drill_database"
run_as_postgres pg_restore \
  --exit-on-error \
  --no-owner \
  --no-privileges \
  --dbname="$drill_database" \
  "$dump"

actual_head="$(run_as_postgres psql --dbname="$drill_database" --no-psqlrc --tuples-only --no-align \
  --command='SELECT version_num FROM alembic_version')"
expected_head="$(cd /opt/fiscal/current/backend && \
  run_as_postgres env FISCAL_DATABASE_URL="${FISCAL_MIGRATION_DATABASE_URL:?missing migration URL}" \
  .venv/bin/alembic heads | awk 'NR == 1 {print $1}')"
[[ -n "$actual_head" && "$actual_head" == "$expected_head" ]] || \
  die "restored Alembic revision does not match the deployed head"

table_check="$(run_as_postgres psql --dbname="$drill_database" --no-psqlrc --tuples-only --no-align \
  --command="SELECT (to_regclass('public.accounts') IS NOT NULL AND to_regclass('public.categories') IS NOT NULL AND to_regclass('public.transactions') IS NOT NULL AND to_regclass('public.postings') IS NOT NULL)::int")"
[[ "$table_check" == "1" ]] || die "canonical tables are missing from the restored database"

orphan_count="$(run_as_postgres psql --dbname="$drill_database" --no-psqlrc --tuples-only --no-align \
  --command='SELECT count(*) FROM postings p LEFT JOIN transactions t ON t.id = p.transaction_id WHERE t.id IS NULL')"
[[ "$orphan_count" == "0" ]] || die "restored database contains orphan postings"

result="verified"
log "restore drill completed successfully from $(basename -- "$dump")"
