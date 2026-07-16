#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_fiscal_env

curl --fail --silent --show-error \
  --connect-timeout 2 \
  --max-time 5 \
  http://127.0.0.1:8010/api/v1/health/ready >/dev/null

status_file="$FISCAL_OPERATIONS_DIR/latest-backup.json"
[[ -r "$status_file" ]] || die "no verified backup status exists"
max_age_hours="${FISCAL_BACKUP_MAX_AGE_HOURS:-30}"
[[ "$max_age_hours" =~ ^[0-9]+$ ]] || die "invalid backup maximum age"

created_epoch="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1], encoding="utf-8"))["created_epoch"]))' "$status_file")"
age_seconds="$(( $(date +%s) - created_epoch ))"
(( age_seconds >= 0 )) || die "backup status timestamp is in the future"
(( age_seconds <= max_age_hours * 3600 )) || die "latest verified backup is stale"

log "readiness and backup freshness checks passed"
