#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly FISCAL_ENV_FILE="${FISCAL_ENV_FILE:-/etc/fiscal/fiscal.env}"
readonly FISCAL_BACKUP_DIR="${FISCAL_BACKUP_DIR:-/var/lib/fiscal/backups}"
readonly FISCAL_OPERATIONS_DIR="${FISCAL_OPERATIONS_DIR:-${FISCAL_OPERATIONS_STATUS_DIRECTORY:-/var/lib/fiscal/operations}}"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

load_fiscal_env() {
  [[ -r "$FISCAL_ENV_FILE" ]] || die "environment file is not readable: $FISCAL_ENV_FILE"
  # shellcheck disable=SC1090
  source "$FISCAL_ENV_FILE"
  [[ "${FISCAL_ENVIRONMENT:-}" == "production" ]] || die "production environment is required"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "this operation must run as root"
}

require_apply() {
  [[ "${1:-}" == "--apply" ]] || {
    log "dry run only; no state was changed"
    log "re-run with --apply after reviewing the command and production contract"
    exit 0
  }
}

run_as_postgres() {
  runuser --user=postgres -- "$@"
}

run_as_migrator() {
  runuser --user=fiscal_migrator -- "$@"
}

prepare_state_directories() {
  install -d -o root -g postgres -m 0770 "$FISCAL_BACKUP_DIR"
  install -d -o root -g fiscal -m 0750 "$FISCAL_OPERATIONS_DIR"
}

write_operation_json() {
  local target="$1"
  local body="$2"
  local temporary
  temporary="$(mktemp "$FISCAL_OPERATIONS_DIR/.status.XXXXXX")"
  printf '%s\n' "$body" >"$temporary"
  chmod 0640 "$temporary"
  chown root:fiscal "$temporary"
  mv -f "$temporary" "$target"
}
