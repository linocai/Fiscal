#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

apply=false
label=""
while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    --label)
      shift
      [[ $# -gt 0 ]] || die "--label requires a non-secret device label"
      label="$1"
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$label" ]] || die "--label is required"
if [[ "$apply" != true ]]; then
  log "dry run only; would import one operator token from standard input"
  log "no token was read and no state was changed"
  exit 0
fi

require_root
load_fiscal_env
[[ -x /opt/fiscal/current/backend/.venv/bin/python ]] || die "no deployed Fiscal release exists"
cd /opt/fiscal/current/backend

FISCAL_ENVIRONMENT=production \
FISCAL_DATABASE_URL="${FISCAL_DATABASE_URL:?missing application database URL}" \
FISCAL_TOKEN_PEPPER="${FISCAL_TOKEN_PEPPER:?missing token pepper}" \
FISCAL_TOKEN_PEPPER_VERSION="${FISCAL_TOKEN_PEPPER_VERSION:-1}" \
  exec runuser --user=fiscal --preserve-environment \
  -- /opt/fiscal/current/backend/.venv/bin/python -m fiscal_api.cli.device_tokens \
  bootstrap-operator --label "$label"
