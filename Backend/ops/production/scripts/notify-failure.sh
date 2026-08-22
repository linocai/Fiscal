#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_fiscal_env
[[ $# -eq 1 ]] || die "one systemd unit name is required"

FISCAL_ALERT_WEBHOOK_URL="${FISCAL_ALERT_WEBHOOK_URL:-}" \
  exec /usr/bin/python3 "$SCRIPT_DIR/notify-failure.py" "$1"
