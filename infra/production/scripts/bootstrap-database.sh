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

if [[ "$apply" != true ]]; then
  log "dry-run database bootstrap"
  log "would create fiscal_owner (NOLOGIN), fiscal_migrator (peer LOGIN) and fiscal_app (DML-only LOGIN)"
  log "would create only the fiscal database, lock down public schema creation and configure app default privileges"
  log "would read the fiscal_app password once from standard input; no password was read and no state was changed"
  exit 0
fi

require_root
load_fiscal_env
getent passwd fiscal_migrator >/dev/null || die "run bootstrap-host.sh --apply first"
database="${FISCAL_BACKUP_DATABASE:-fiscal}"
[[ "$database" == "fiscal" ]] || die "database bootstrap is restricted to the dedicated fiscal database"

if [[ -t 0 ]]; then
  printf 'Fiscal application database password: ' >&2
fi
IFS= read -r -s app_password || die "unable to read the application database password"
[[ ${#app_password} -ge 32 ]] || die "application database password must contain at least 32 characters"
[[ "$app_password" != *$'\r'* && "$app_password" != *$'\n'* ]] || die "invalid password input"
[[ -n "$app_password" ]] || die "application database password is required"
[[ -t 0 ]] && printf '\n' >&2

run_as_postgres psql --dbname=postgres --no-psqlrc --quiet <<SQL
\set ON_ERROR_STOP on
\prompt '' app_password
$app_password
SELECT 'CREATE ROLE fiscal_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'fiscal_owner') \gexec
SELECT 'CREATE ROLE fiscal_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'fiscal_migrator') \gexec
SELECT 'CREATE ROLE fiscal_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'fiscal_app') \gexec
ALTER ROLE fiscal_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
ALTER ROLE fiscal_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
ALTER ROLE fiscal_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  PASSWORD :'app_password';
GRANT fiscal_owner TO fiscal_migrator;
SQL
unset app_password

if ! run_as_postgres psql --dbname=postgres --no-psqlrc --tuples-only --no-align \
  --command="SELECT 1 FROM pg_database WHERE datname = 'fiscal'" | grep -qx 1; then
  run_as_postgres createdb --owner=fiscal_owner --encoding=UTF8 --template=template0 fiscal
fi

run_as_postgres psql --dbname=fiscal --no-psqlrc --quiet <<'SQL'
\set ON_ERROR_STOP on
REVOKE ALL ON DATABASE fiscal FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE fiscal TO fiscal_migrator;
GRANT CONNECT ON DATABASE fiscal TO fiscal_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO fiscal_owner;
GRANT USAGE ON SCHEMA public TO fiscal_app;
ALTER DEFAULT PRIVILEGES FOR ROLE fiscal_migrator IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fiscal_app;
ALTER DEFAULT PRIVILEGES FOR ROLE fiscal_migrator IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO fiscal_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO fiscal_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO fiscal_app;
SQL

run_as_migrator psql --dbname=fiscal --no-psqlrc --tuples-only --no-align \
  --command='SELECT current_user' | grep -qx fiscal_migrator || die "migrator peer authentication failed"
log "database bootstrap complete with separate owner, migrator and application privileges"
