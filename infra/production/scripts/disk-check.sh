#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_fiscal_env
[[ "$(id -u)" -eq 0 ]] && prepare_state_directories

path="${FISCAL_DISK_PATH:-/var/lib/postgresql}"
warning="${FISCAL_DISK_WARNING_PERCENT:-75}"
failure="${FISCAL_DISK_FAILURE_PERCENT:-85}"
[[ -e "$path" ]] || die "disk check path does not exist"
[[ "$warning" =~ ^[0-9]+$ && "$failure" =~ ^[0-9]+$ ]] || die "invalid disk thresholds"
(( warning > 0 && warning < failure && failure <= 100 )) || die "disk thresholds are inconsistent"

used="$(df -P -- "$path" | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
[[ "$used" =~ ^[0-9]+$ ]] || die "unable to read disk usage"

state="healthy"
if (( used >= failure )); then
  state="failure"
elif (( used >= warning )); then
  state="warning"
fi

if [[ "$(id -u)" -eq 0 ]]; then
  write_operation_json "$FISCAL_OPERATIONS_DIR/latest-disk.json" \
    "{\"state\":\"$state\",\"checked_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"used_percent\":$used,\"warning_percent\":$warning,\"failure_percent\":$failure}"
fi

[[ "$state" != "failure" ]] || die "disk usage reached the failure threshold"
log "disk state=$state used_percent=$used"
