#!/usr/bin/env bash

# Fixed-principal P22 shadow/archive operator wrapper.  It never creates,
# migrates, restores, or drops a database; the target must already be a fresh,
# head-migrated shadow database.  Archive export/inspection/restore are always
# run from the exact committed source tree as fiscal_migrator.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

apply=false
source_preflight=false
archive_action=""
source_root=""
target_database=""
archive_path=""
evidence_parent=""
workspace=""
source_env=""
target_env=""
password_file=""

normalize_database() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

usage_error() {
  die "use exactly one of --source-preflight, --archive-export, --archive-dry-run, or --archive-apply (or omit it for target preflight)"
}

while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    --source-preflight) source_preflight=true ;;
    --archive-export|--archive-dry-run|--archive-apply)
      [[ -z "$archive_action" ]] || usage_error
      archive_action="${1#--archive-}"
      ;;
    --source) shift; source_root="${1:?--source requires a path}" ;;
    --target-database) shift; target_database="${1:?--target-database requires a value}" ;;
    --archive) shift; archive_path="${1:?--archive requires a path}" ;;
    --evidence-parent) shift; evidence_parent="${1:?--evidence-parent requires a path}" ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$source_root" && -d "$source_root/backend" ]] || die "--source backend is required"
[[ -x "$source_root/backend/.venv/bin/python" ]] || die "source Python is missing"
[[ -x "$source_root/backend/.venv/bin/alembic" ]] || die "source Alembic is missing"
[[ -n "$evidence_parent" && "$evidence_parent" == /* ]] || \
  die "--evidence-parent must be an absolute path"
[[ "$source_preflight" != true || -z "$archive_action" ]] || usage_error

requires_target=true
if [[ "$source_preflight" == true || "$archive_action" == "export" ]]; then
  requires_target=false
fi
if [[ "$requires_target" == true ]]; then
  target_database="$(normalize_database "$target_database")"
  [[ "$target_database" =~ ^fiscal_p22_shadow_[a-z0-9_]+$ ]] || \
    die "target must be an explicitly scoped fiscal_p22_shadow database"
fi
if [[ -n "$archive_action" ]]; then
  [[ -n "$archive_path" && "$archive_path" == /* ]] || \
    die "--archive must be an absolute path"
  [[ "$archive_action" != "export" || ! -e "$archive_path" ]] || \
    die "archive output already exists and will not be overwritten"
  [[ "$archive_action" == "export" || -f "$archive_path" ]] || \
    die "archive input must be an existing regular file"
fi

if [[ "$apply" != true ]]; then
  if [[ -n "$archive_action" ]]; then
    log "P22 shadow wrapper plan: would preflight the exact source/tree/principal and archive-${archive_action} without exposing a DSN or password"
  elif [[ "$source_preflight" == true ]]; then
    log "P22 shadow wrapper plan: would preflight only the exact source/tree/principal"
  else
    log "P22 shadow wrapper plan: would preflight only the fresh target database"
  fi
  exit 0
fi

require_root
load_fiscal_env
[[ ! -e "$evidence_parent" ]] || die "evidence parent already exists"

install -d -o root -g fiscal_migrator -m 0710 "$evidence_parent"
workspace="$evidence_parent/workspace"
install -d -o fiscal_migrator -g fiscal_migrator -m 0700 "$workspace"
runuser --user=fiscal_migrator -- test -w "$workspace"
source_env="$workspace/source.env"
target_env="$workspace/target.env"
password_file="$workspace/archive-password"

cleanup() {
  rm -f -- "$source_env" "$target_env" "$password_file"
  unset FISCAL_DATABASE_URL FISCAL_MIGRATION_DATABASE_URL
}
trap cleanup EXIT

prepare_database_envs() {
  FISCAL_MIGRATION_DATABASE_URL="$FISCAL_MIGRATION_DATABASE_URL" \
    "$source_root/backend/.venv/bin/python" - "$source_env" "$target_env" "$target_database" <<'PY'
import os
import sys
from pathlib import Path

from sqlalchemy.engine import make_url

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
target_database = sys.argv[3]
url = make_url(os.environ["FISCAL_MIGRATION_DATABASE_URL"])
source_database = (url.database or "").lower()
if url.drivername != "postgresql+asyncpg" or url.username != "fiscal_migrator":
    raise SystemExit("unexpected migration URL principal")
if source_database != "fiscal":
    raise SystemExit("migration URL must use the canonical fiscal source database")
if target_database and not target_database.startswith("fiscal_p22_shadow_"):
    raise SystemExit("unexpected shadow target database")

def write_env(path: Path, database: str) -> None:
    rendered = url.set(database=database).render_as_string(hide_password=False)
    needle = "host=%2Fvar%2Frun%2Fpostgresql"
    if needle not in rendered:
        raise SystemExit("unexpected migration socket encoding")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write(f"FISCAL_DATABASE_URL={rendered.replace(needle, 'host=/var/run/postgresql')}\n")

write_env(source_path, source_database)
if target_database:
    write_env(target_path, target_database)
PY
  chown fiscal_migrator:fiscal_migrator "$source_env"
  chmod 0600 "$source_env"
  if [[ -n "$target_database" ]]; then
    chown fiscal_migrator:fiscal_migrator "$target_env"
    chmod 0600 "$target_env"
  fi
}

run_source_preflight() {
  runuser --user=fiscal_migrator -- bash -c '
    set -Eeuo pipefail
    cd "$1/backend"
    "$2" -c "import fiscal_api"
    "$3" --config alembic.ini heads >/dev/null
    psql --dbname=postgres --no-psqlrc --tuples-only --no-align --command="SELECT current_user" | grep -qx fiscal_migrator
  ' _ "$source_root" "$source_root/backend/.venv/bin/python" "$source_root/backend/.venv/bin/alembic"
}

run_target_preflight() {
  runuser --user=fiscal_migrator -- bash -c '
    set -Eeuo pipefail
    . "$1"
    cd "$2/backend"
    "$3" -c "from fiscal_api.core.config import Settings; Settings()"
    expected_head="$("$4" --config alembic.ini heads | awk "NR == 1 {print \$1}")"
    actual_head="$("$4" --config alembic.ini current | awk "NR == 1 {print \$1}")"
    [[ -n "$expected_head" && "$actual_head" == "$expected_head" ]] || exit 1
  ' _ "$target_env" "$source_root" "$source_root/backend/.venv/bin/python" "$source_root/backend/.venv/bin/alembic"
}

read_archive_password() {
  local archive_password=""
  IFS= read -r archive_password || [[ -n "$archive_password" ]] || die "archive password must be provided on standard input"
  [[ ${#archive_password} -ge 12 && ${#archive_password} -le 128 ]] || \
    die "archive password must be 12 to 128 characters"
  printf '%s\n' "$archive_password" >"$password_file"
  chown fiscal_migrator:fiscal_migrator "$password_file"
  chmod 0600 "$password_file"
  archive_password=""
}

run_archive() {
  local database_env="$1"
  local module="$2"
  shift 2
  runuser --user=fiscal_migrator -- bash -c '
    set -Eeuo pipefail
    database_env="$1"
    source_root="$2"
    python_bin="$3"
    archive_module="$4"
    archive_password="$5"
    shift 5
    . "$database_env"
    cd "$source_root/backend"
    exec "$python_bin" -m "$archive_module" "$@" < "$archive_password"
  ' _ "$database_env" "$source_root" "$source_root/backend/.venv/bin/python" "$module" "$password_file" "$@"
}

run_source_preflight
if [[ "$source_preflight" == true ]]; then
  log "P22 source/principal preflight passed; no target database was used"
  exit 0
fi

prepare_database_envs
if [[ "$requires_target" == true ]]; then
  run_target_preflight
fi

if [[ -z "$archive_action" ]]; then
  log "P22 shadow target preflight passed; target database remains untouched"
  exit 0
fi

read_archive_password
case "$archive_action" in
  export)
    run_archive "$source_env" fiscal_api.cli.archive_export "$archive_path"
    log "P22 shadow archive export passed; no database was changed"
    ;;
  dry-run)
    run_archive "$target_env" fiscal_api.cli.archive "$archive_path" --dry-run
    log "P22 shadow archive dry-run passed; target database remains untouched"
    ;;
  apply)
    run_archive "$target_env" fiscal_api.cli.archive "$archive_path" --apply --confirm-empty-target
    log "P22 shadow archive apply passed; target database was restored"
    ;;
  *) die "unexpected archive action" ;;
esac
