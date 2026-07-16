#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

apply=false
revision=""
while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    --revision)
      shift
      [[ $# -gt 0 ]] || die "--revision requires a 12-character release revision"
      revision="$1"
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ "$revision" =~ ^[0-9a-f]{12}$ ]] || die "a 12-character --revision is required"
release="/opt/fiscal/releases/$revision"
[[ -f "$release/RELEASE" ]] || die "target release does not exist or has no manifest"

if [[ "$apply" != true ]]; then
  log "dry-run rollback target=$release"
  log "the apply path will refuse unless the target and current database Alembic heads match exactly"
  log "no state was changed; re-run with --apply after review"
  exit 0
fi

require_root
load_fiscal_env

target_head="$(awk -F= '$1 == "alembic_head" {print $2}' "$release/RELEASE")"
actual_head="$(run_as_postgres psql --dbname="${FISCAL_BACKUP_DATABASE:-fiscal}" \
  --no-psqlrc --tuples-only --no-align --command='SELECT version_num FROM alembic_version')"
[[ -n "$target_head" && "$target_head" == "$actual_head" ]] || die \
  "schema compatibility is not proven; do not downgrade in place—restore the pre-migration backup into a new database"

new_link="/opt/fiscal/.rollback-$revision"
ln -s "$release" "$new_link"
mv -Tf "$new_link" /opt/fiscal/current
systemctl restart fiscal-api.service
"$release/infra/production/scripts/health-check.sh"
log "application release rollback completed target=$revision schema=$actual_head"
