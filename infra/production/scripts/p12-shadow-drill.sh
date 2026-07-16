#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

apply=false
target_database=""
report_dir=""
python_bin="${FISCAL_SHADOW_PYTHON:-}"
migration_module="${FISCAL_LEGACY_MIGRATION_MODULE:-fiscal_api.cli.legacy_migration}"

usage() {
  cat >&2 <<'EOF'
Usage: p12-shadow-drill.sh --target-database NAME [options] [--apply]

Options:
  --report-dir PATH         Evidence directory (default: ./p12-shadow-NAME-TIMESTAMP)
  --python PATH             Python from the checked release virtualenv
  --migration-module NAME   Parameterized migration CLI module
  --apply                   Execute against the named shadow database

Apply mode reads these DSNs only from the environment:
  FISCAL_SHADOW_BASELINE_DATABASE_URL  Fiscal database to back up read-only
  FISCAL_SHADOW_TARGET_DATABASE_URL    Existing empty shadow database
  FISCAL_LEGACY_DATABASE_URL           Legacy LinoFinance source (CLI enforces read-only)
EOF
}

while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    --target-database)
      shift
      [[ $# -gt 0 ]] || die "--target-database requires a value"
      target_database="$1"
      ;;
    --report-dir)
      shift
      [[ $# -gt 0 ]] || die "--report-dir requires a path"
      report_dir="$1"
      ;;
    --python)
      shift
      [[ $# -gt 0 ]] || die "--python requires a path"
      python_bin="$1"
      ;;
    --migration-module)
      shift
      [[ $# -gt 0 ]] || die "--migration-module requires a module name"
      migration_module="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$target_database" ]] || die "--target-database is required"
[[ "$target_database" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "invalid target database name"

normalized_target="$(printf '%s' "$target_database" | tr '[:upper:]' '[:lower:]')"
case "$normalized_target" in
  fiscal|linofinance|postgres|template0|template1)
    die "protected database name cannot be a shadow target: $target_database"
    ;;
esac
[[ "$normalized_target" == *shadow* || "$normalized_target" == *drill* ]] || \
  die "target database name must contain 'shadow' or 'drill'"

if [[ -z "$report_dir" ]]; then
  report_dir="$PWD/p12-shadow-$target_database-$(date -u +%Y%m%dT%H%M%SZ)"
fi
[[ "$migration_module" =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]] || die "invalid migration module"

if [[ "$apply" != true ]]; then
  log "P12 shadow drill plan"
  log "target_database=$target_database"
  log "report_dir=$report_dir"
  log "migration_module=$migration_module"
  log "would back up the Fiscal baseline, restore it into the empty shadow target, upgrade Alembic, then run audit, plan, apply and reconcile"
  log "no database or file was changed; re-run with --apply after provisioning the explicit empty target"
  exit 0
fi

: "${FISCAL_SHADOW_BASELINE_DATABASE_URL:?missing baseline database URL in environment}"
: "${FISCAL_SHADOW_TARGET_DATABASE_URL:?missing target database URL in environment}"
: "${FISCAL_LEGACY_DATABASE_URL:?missing legacy database URL in environment}"

if [[ -z "$python_bin" ]]; then
  repository_root="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
  python_bin="$repository_root/backend/.venv/bin/python"
fi
[[ -x "$python_bin" ]] || die "shadow drill Python is not executable: $python_bin"
for command in pg_dump pg_restore psql sha256sum; do
  command -v "$command" >/dev/null || die "$command is required"
done

old_umask="$(umask)"
umask 077
[[ ! -e "$report_dir" ]] || \
  die "report directory already exists; use a new path so prior evidence is never overwritten"
install -d -m 0700 "$report_dir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
baseline_dump="$report_dir/fiscal-baseline-$stamp.dump"
partial_dump="$baseline_dump.partial"
manifest="$baseline_dump.sha256"
status_file="$report_dir/status.json"
result="failed"
stage="preflight"

write_status() {
  local exit_status="$1"
  local temporary
  temporary="$(mktemp "$report_dir/.status.XXXXXX")"
  printf '{"result":"%s","stage":"%s","target_database":"%s","checked_at":"%s","exit_status":%s}\n' \
    "$result" "$stage" "$target_database" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$exit_status" \
    >"$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$status_file"
}

finish() {
  local command_status=$?
  rm -f -- "$partial_dump"
  write_status "$command_status" || true
  find "$report_dir" -maxdepth 1 -type f -exec chmod 0600 {} + 2>/dev/null || true
  umask "$old_umask"
  if ((command_status != 0)); then
    log "shadow drill failed at stage=$stage; database and evidence were preserved for inspection"
  fi
  return "$command_status"
}
trap finish EXIT

stage="preflight"
baseline_database="$(PGDATABASE="$FISCAL_SHADOW_BASELINE_DATABASE_URL" \
  psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 \
  --command='SELECT current_database()')"
target_connection_database="$(PGDATABASE="$FISCAL_SHADOW_TARGET_DATABASE_URL" \
  psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 \
  --command='SELECT current_database()')"
[[ "$target_connection_database" == "$target_database" ]] || \
  die "target DSN database does not match --target-database"
[[ "$baseline_database" != "$target_database" ]] || \
  die "baseline and target database must be different"

target_user_tables="$(PGDATABASE="$FISCAL_SHADOW_TARGET_DATABASE_URL" \
  psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 \
  --command="SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND c.relkind IN ('r','p')")"
[[ "$target_user_tables" == "0" ]] || \
  die "shadow target is not empty; provision a new database instead of overwriting evidence"

stage="backup"
log "creating a verified custom-format baseline backup"
PGDATABASE="$FISCAL_SHADOW_BASELINE_DATABASE_URL" pg_dump \
  --format=custom --compress=9 --no-owner --no-privileges --file="$partial_dump"
pg_restore --list "$partial_dump" >/dev/null
mv -- "$partial_dump" "$baseline_dump"
(
  cd -- "$report_dir"
  sha256sum "$(basename -- "$baseline_dump")" >"$(basename -- "$manifest")"
)

stage="restore"
log "restoring baseline into explicit shadow database $target_database"
pg_restore --exit-on-error --no-owner --no-privileges --file=- "$baseline_dump" | \
  PGDATABASE="$FISCAL_SHADOW_TARGET_DATABASE_URL" \
  psql --no-psqlrc --set=ON_ERROR_STOP=1 --single-transaction

stage="alembic"
backend_dir="$(cd -- "$(dirname -- "$python_bin")/../.." && pwd)"
alembic_bin="$backend_dir/.venv/bin/alembic"
alembic_config="$backend_dir/alembic.ini"
[[ -x "$alembic_bin" && -r "$alembic_config" ]] || \
  die "Alembic executable/configuration was not found beside the selected Python"
(
  cd -- "$backend_dir"
  export FISCAL_DATABASE_URL="$FISCAL_SHADOW_TARGET_DATABASE_URL"
  "$alembic_bin" --config "$alembic_config" upgrade head
  expected_head="$($alembic_bin --config "$alembic_config" heads | awk 'NR == 1 {print $1}')"
  actual_head="$(PGDATABASE="$FISCAL_SHADOW_TARGET_DATABASE_URL" \
    psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --command='SELECT version_num FROM alembic_version')"
  [[ -n "$expected_head" && "$actual_head" == "$expected_head" ]] || \
    die "shadow database did not reach the release Alembic head"
  printf '%s\n' "$actual_head" >"$report_dir/alembic-head.txt"
)

run_migration_stage() {
  local command="$1"
  local output="$2"
  stage="$command"
  (
    cd -- "$backend_dir"
    export FISCAL_DATABASE_URL="$FISCAL_SHADOW_TARGET_DATABASE_URL"
    export FISCAL_LEGACY_DATABASE_URL
    "$python_bin" -m "$migration_module" "$command" --output "$output"
  )
  [[ -f "$output" ]] || die "migration command did not create its report: $command"
  chmod 0600 "$output"
}

run_migration_stage audit "$report_dir/legacy-audit.json"
run_migration_stage plan "$report_dir/migration-plan.json"
run_migration_stage apply "$report_dir/migration-apply.json"
run_migration_stage reconcile "$report_dir/reconciliation.json"

stage="complete"
result="verified"
log "P12 shadow drill completed; target and owner-only evidence were preserved"
