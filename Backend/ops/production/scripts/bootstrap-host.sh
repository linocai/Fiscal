#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

apply=false
release_access=false
while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    --release-access) release_access=true ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

uv_version="${FISCAL_UV_VERSION:-0.11.16}"
uv_root="/opt/fiscal/tools/uv"
aliyun_index="https://mirrors.aliyun.com/pypi/simple/"

if [[ "$release_access" == true && "$apply" != true ]]; then
  log "dry-run release access bootstrap"
  log "would create fiscal_release and add only fiscal plus fiscal_migrator"
  log "would verify /etc/fiscal/fiscal.env remains root:fiscal mode 0640"
  log "no packages, users, files or services were changed"
  exit 0
fi

if [[ "$release_access" != true && "$apply" != true ]]; then
  log "dry-run host bootstrap"
  log "would create dedicated fiscal and fiscal_migrator OS identities and Fiscal-only directories"
  log "would install uv $uv_version into $uv_root using the Aliyun PyPI mirror with a 60-second timeout"
  log "would install production.env.example only when /etc/fiscal/fiscal.env is absent"
  log "no packages, users, files or services were changed"
  exit 0
fi

require_root
ensure_release_access() {
  for command in groupadd usermod id getent stat; do
    command -v "$command" >/dev/null || die "required host command is missing: $command"
  done
  for account in fiscal fiscal_migrator; do
    getent passwd "$account" >/dev/null || die "$account is missing; run bootstrap-host.sh --apply first"
  done

  local environment_metadata
  environment_metadata="$(stat -c '%U:%G %a' /etc/fiscal/fiscal.env)"
  [[ "$environment_metadata" == "root:fiscal 640" ]] || \
    die "/etc/fiscal/fiscal.env must remain root:fiscal mode 0640"

  if ! getent group fiscal_release >/dev/null; then
    groupadd --system fiscal_release
  fi
  for account in fiscal fiscal_migrator; do
    if ! id -nG "$account" | tr ' ' '\n' | grep -qx fiscal_release; then
      usermod --append --groups fiscal_release "$account"
    fi
    id -nG "$account" | tr ' ' '\n' | grep -qx fiscal_release || \
      die "$account was not added to fiscal_release"
  done

  [[ "$(stat -c '%U:%G %a' /etc/fiscal/fiscal.env)" == "$environment_metadata" ]] || \
    die "/etc/fiscal/fiscal.env metadata changed unexpectedly"
}

if [[ "$release_access" == true ]]; then
  ensure_release_access
  log "release access bootstrap complete; no other host state was changed"
  exit 0
fi

[[ "$uv_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid uv version"
for command in groupadd useradd usermod id getent install runuser pg_dump pg_restore psql nginx python3; do
  command -v "$command" >/dev/null || die "required host command is missing: $command"
done
/usr/bin/python3 -m venv --help >/dev/null 2>&1 || die "python3-venv is required"

if ! getent passwd fiscal >/dev/null; then
  useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin fiscal
fi
if ! getent passwd fiscal_migrator >/dev/null; then
  useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin fiscal_migrator
fi
ensure_release_access

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
