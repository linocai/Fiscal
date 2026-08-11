#!/usr/bin/env bash

# Fixed-principal preflight for a newly provisioned P22 shadow target.  It does
# not create, restore, migrate, or delete a database; callers may proceed only
# after this wrapper proves the exact release/CWD/DSN contract.
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

apply=false
source_root=""
target_database=""
evidence_parent=""

while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    --source) shift; source_root="${1:?--source requires a path}" ;;
    --target-database) shift; target_database="${1:?--target-database requires a value}" ;;
    --evidence-parent) shift; evidence_parent="${1:?--evidence-parent requires a path}" ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ "$target_database" =~ ^fiscal_p22_shadow_[a-z0-9_]+$ ]] || \
  die "target must be an explicitly scoped fiscal_p22_shadow database"
[[ -n "$source_root" && -d "$source_root/backend" ]] || die "--source backend is required"
[[ -n "$evidence_parent" ]] || die "--evidence-parent is required"

if [[ "$apply" != true ]]; then
  log "P22 shadow wrapper plan: would create only a migrator-owned 0700 workspace and preflight the target"
  exit 0
fi

require_root
load_fiscal_env
[[ -x "$source_root/backend/.venv/bin/python" ]] || die "source Python is missing"
[[ -x "$source_root/backend/.venv/bin/alembic" ]] || die "source Alembic is missing"
[[ ! -e "$evidence_parent" ]] || die "evidence parent already exists"

install -d -o root -g fiscal_migrator -m 0710 "$evidence_parent"
workspace="$evidence_parent/workspace"
install -d -o fiscal_migrator -g fiscal_migrator -m 0700 "$workspace"
env_file="$workspace/target.env"
cleanup() { rm -f -- "$env_file"; }
trap cleanup EXIT

"$source_root/backend/.venv/bin/python" - "$FISCAL_MIGRATION_DATABASE_URL" "$target_database" >"$env_file" <<'PY'
import sys
from sqlalchemy.engine import make_url
url = make_url(sys.argv[1])
if url.drivername != "postgresql+asyncpg" or url.username != "fiscal_migrator":
    raise SystemExit("unexpected migration URL principal")
rendered = url.set(database=sys.argv[2]).render_as_string(hide_password=False)
needle = "host=%2Fvar%2Frun%2Fpostgresql"
if needle not in rendered:
    raise SystemExit("unexpected migration socket encoding")
print(f"FISCAL_DATABASE_URL={rendered.replace(needle, 'host=/var/run/postgresql')}")
PY
chown fiscal_migrator:fiscal_migrator "$env_file"
chmod 0600 "$env_file"

runuser --user=fiscal_migrator -- test -w "$workspace"
runuser --user=fiscal_migrator -- bash -c '
  set -a; . "$1"; set +a
  cd "$2/backend"
  "$3" -c "from fiscal_api.core.config import Settings; Settings()"
  "$4" --config alembic.ini current
' _ "$env_file" "$source_root" "$source_root/backend/.venv/bin/python" "$source_root/backend/.venv/bin/alembic"
log "P22 shadow wrapper preflight passed; target database remains untouched"
