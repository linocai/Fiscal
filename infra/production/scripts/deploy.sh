#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

apply=false
public_smoke=false
defer_start=false
source_root="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    --public-smoke) public_smoke=true ;;
    --defer-start) defer_start=true ;;
    --source)
      shift
      [[ $# -gt 0 ]] || die "--source requires a repository path"
      source_root="$1"
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [[ "$defer_start" == true && "$public_smoke" == true ]]; then
  die "--defer-start cannot be combined with --public-smoke"
fi

revision="$(git -C "$source_root" rev-parse --verify HEAD 2>/dev/null || true)"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "source must be a Git repository with a committed HEAD"
short_revision="${revision:0:12}"
release="/opt/fiscal/releases/$short_revision"

if [[ "$apply" != true ]]; then
  log "dry-run deployment plan"
  log "source=$source_root"
  log "revision=$revision"
  log "release=$release"
  if [[ "$defer_start" == true ]]; then
    log "first-install mode: would archive, test, back up, migrate and switch current without starting the API"
  else
    log "would archive the committed revision, run backend gates, take a verified backup, migrate, switch the release, restart and smoke-test"
  fi
  log "no state was changed; re-run with --apply after review"
  exit 0
fi

require_root
load_fiscal_env
systemctl cat fiscal-api.service >/dev/null 2>&1 || \
  die "install the Fiscal systemd units and run systemctl daemon-reload before deployment"
if [[ "$defer_start" == true ]]; then
  [[ ! -e /opt/fiscal/current && ! -L /opt/fiscal/current ]] || \
    die "--defer-start is restricted to the first installation; current already exists"
else
  [[ -e /opt/fiscal/current || -L /opt/fiscal/current ]] || \
    die "the first installation must use --defer-start"
fi
[[ ! -e "$release" ]] || die "release already exists: $release"
command -v git >/dev/null || die "git is required"
command -v systemctl >/dev/null || die "systemd is required"
uv_bin="${FISCAL_UV_BIN:-/opt/fiscal/tools/uv/bin/uv}"
[[ -x "$uv_bin" ]] || die "the pinned uv tool is missing; run bootstrap-host.sh --apply first"
expected_uv_version="${FISCAL_UV_VERSION:-0.11.16}"
installed_uv_version="$($uv_bin --version | awk '{print $2}')"
[[ "$installed_uv_version" == "$expected_uv_version" ]] || \
  die "uv version mismatch: expected $expected_uv_version"

install -d -o root -g fiscal -m 0755 /opt/fiscal /opt/fiscal/releases
temporary_release="$(mktemp -d "/opt/fiscal/releases/.deploy-$short_revision.XXXXXX")"
cleanup() {
  [[ -z "${temporary_release:-}" ]] || rm -rf -- "$temporary_release"
}
trap cleanup EXIT

log "materializing committed release $revision"
git -C "$source_root" archive "$revision" | tar -x -C "$temporary_release"

log "running release verification gates without production database access"
(
  cd -- "$temporary_release/backend"
  if grep -Eq 'pypi\.org|files\.pythonhosted\.org' uv.lock; then
    die "uv.lock contains direct PyPI sources; regenerate it against the approved mirror"
  fi
  unset FISCAL_DATABASE_URL FISCAL_TEST_DATABASE_URL FISCAL_DEVICE_TOKEN
  unset FISCAL_TOKEN_PEPPER FISCAL_AI_PROVIDER_API_KEY
  export UV_DEFAULT_INDEX="${FISCAL_PYPI_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
  export UV_HTTP_TIMEOUT="${FISCAL_UV_HTTP_TIMEOUT_SECONDS:-60}"
  "$uv_bin" venv --relocatable .venv
  "$uv_bin" sync --frozen --no-editable
  "$uv_bin" run ruff format --check .
  "$uv_bin" run ruff check .
  "$uv_bin" run pyright
  "$uv_bin" run pytest
  "$uv_bin" sync --frozen --no-dev --no-editable
)

chown -R root:fiscal "$temporary_release"
find "$temporary_release" -type d -exec chmod 0755 {} +
mv -- "$temporary_release" "$release"
temporary_release=""

runuser --user=fiscal -- "$release/backend/.venv/bin/python" -c 'import fiscal_api'

alembic_bin="$release/backend/.venv/bin/alembic"
alembic_config="$release/backend/alembic.ini"
expected_head="$(
  cd -- "$release/backend"
  run_as_migrator env \
    FISCAL_DATABASE_URL="${FISCAL_MIGRATION_DATABASE_URL:?missing migration URL}" \
    "$alembic_bin" --config "$alembic_config" heads | awk 'NR == 1 {print $1}'
)"
[[ -n "$expected_head" ]] || die "unable to determine the release Alembic head"
printf 'revision=%s\nalembic_head=%s\ncreated_at=%s\n' \
  "$revision" "$expected_head" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$release/RELEASE"
chown root:fiscal "$release/RELEASE"
chmod 0644 "$release/RELEASE"

log "creating and verifying the mandatory pre-migration backup"
"$release/infra/production/scripts/backup.sh" --apply

log "upgrading the production schema explicitly"
(
  cd -- "$release/backend"
  run_as_migrator env \
    FISCAL_DATABASE_URL="${FISCAL_MIGRATION_DATABASE_URL:?missing migration URL}" \
    "$alembic_bin" --config "$alembic_config" upgrade head
)

actual_head="$(run_as_postgres psql --dbname="${FISCAL_BACKUP_DATABASE:-fiscal}" \
  --no-psqlrc --tuples-only --no-align --command='SELECT version_num FROM alembic_version')"
[[ "$actual_head" == "$expected_head" ]] || die "database did not reach the release Alembic head"

new_link="/opt/fiscal/.current-$short_revision"
ln -s "$release" "$new_link"
mv -Tf "$new_link" /opt/fiscal/current

if [[ "$defer_start" == true ]]; then
  log "release switched with API start deferred; import the first operator before starting"
else
  systemctl restart fiscal-api.service
  "$release/infra/production/scripts/health-check.sh"
fi

if [[ "$public_smoke" == true ]]; then
  public_base="${FISCAL_PUBLIC_BASE_URL:?public URL is required for public smoke}"
  curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
    "$public_base/api/v1/health/live" >/dev/null
fi

log "deployment completed revision=$revision alembic_head=$expected_head deferred_start=$defer_start"
