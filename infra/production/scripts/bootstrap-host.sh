#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

apply=false
while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

uv_version="${FISCAL_UV_VERSION:-0.11.16}"
uv_root="/opt/fiscal/tools/uv"
aliyun_index="https://mirrors.aliyun.com/pypi/simple/"

if [[ "$apply" != true ]]; then
  log "dry-run host bootstrap"
  log "would create dedicated fiscal and fiscal_migrator OS identities and Fiscal-only directories"
  log "would install uv $uv_version into $uv_root using the Aliyun PyPI mirror with a 60-second timeout"
  log "would install production.env.example only when /etc/fiscal/fiscal.env is absent"
  log "no packages, users, files or services were changed"
  exit 0
fi

require_root
[[ "$uv_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid uv version"
for command in useradd getent install runuser pg_dump pg_restore psql nginx python3; do
  command -v "$command" >/dev/null || die "required host command is missing: $command"
done
/usr/bin/python3 -m venv --help >/dev/null 2>&1 || die "python3-venv is required"

if ! getent passwd fiscal >/dev/null; then
  useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin fiscal
fi
if ! getent passwd fiscal_migrator >/dev/null; then
  useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin fiscal_migrator
fi

install -d -o root -g fiscal -m 0755 /opt/fiscal /opt/fiscal/releases /opt/fiscal/tools
install -d -o root -g fiscal -m 0750 /etc/fiscal /var/lib/fiscal/operations
install -d -o root -g postgres -m 0770 /var/lib/fiscal/backups

if [[ ! -e /etc/fiscal/fiscal.env ]]; then
  install -o root -g fiscal -m 0640 \
    "$SCRIPT_DIR/../production.env.example" /etc/fiscal/fiscal.env
else
  log "preserving existing /etc/fiscal/fiscal.env"
fi

if [[ ! -x "$uv_root/bin/python" ]]; then
  /usr/bin/python3 -m venv "$uv_root"
fi
"$uv_root/bin/python" -m pip install \
  --disable-pip-version-check \
  --index-url "$aliyun_index" \
  --timeout 60 \
  "uv==$uv_version"

installed_version="$($uv_root/bin/uv --version | awk '{print $2}')"
[[ "$installed_version" == "$uv_version" ]] || die "installed uv version does not match $uv_version"
chown -R root:fiscal /opt/fiscal/tools
find /opt/fiscal/tools -type d -exec chmod 0755 {} +
log "host bootstrap complete; edit /etc/fiscal/fiscal.env before database bootstrap"
