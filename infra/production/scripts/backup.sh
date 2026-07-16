#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_apply "${1:-}"
require_root
load_fiscal_env
prepare_state_directories

database="${FISCAL_BACKUP_DATABASE:-fiscal}"
retention_days="${FISCAL_BACKUP_RETENTION_DAYS:-14}"
[[ "$database" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "invalid backup database name"
[[ "$retention_days" =~ ^[0-9]+$ ]] || die "invalid backup retention"
(( retention_days >= 1 )) || die "backup retention must be at least one day"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dump="$FISCAL_BACKUP_DIR/fiscal-$stamp.dump"
manifest="$dump.sha256"
temporary="$dump.partial"
started_epoch="$(date +%s)"

cleanup() {
  rm -f -- "$temporary"
}
trap cleanup EXIT

log "creating a PostgreSQL custom-format backup"
run_as_postgres pg_dump \
  --format=custom \
  --compress=9 \
  --no-owner \
  --no-privileges \
  --file="$temporary" \
  "$database"
run_as_postgres pg_restore --list "$temporary" >/dev/null
mv -- "$temporary" "$dump"
chown postgres:postgres "$dump"
chmod 0600 "$dump"

(
  cd -- "$FISCAL_BACKUP_DIR"
  sha256sum "$(basename -- "$dump")" >"$(basename -- "$manifest")"
)
chown root:postgres "$manifest"
chmod 0640 "$manifest"

finished_epoch="$(date +%s)"
size_bytes="$(stat -c %s "$dump")"
write_operation_json "$FISCAL_OPERATIONS_DIR/latest-backup.json" \
  "{\"result\":\"verified\",\"created_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"created_epoch\":$finished_epoch,\"duration_seconds\":$((finished_epoch - started_epoch)),\"size_bytes\":$size_bytes,\"file\":\"$(basename -- "$dump")\"}"

find "$FISCAL_BACKUP_DIR" -maxdepth 1 -type f \
  \( -name 'fiscal-*.dump' -o -name 'fiscal-*.dump.sha256' \) \
  -mtime "+$((retention_days - 1))" -delete
log "backup completed and verified: $(basename -- "$dump")"
