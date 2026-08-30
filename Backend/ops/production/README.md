# Fiscal native production operations

> The files in this directory remain the HZ source/default loopback topology.
> The authorized Fiscal-only move to the NB NPM edge uses the narrowly scoped
> overlay and cutover contract in [`nb/README.md`](nb/README.md).

These assets implement the frozen P11 topology for the dedicated Fiscal virtual host on Ubuntu 24.04, PostgreSQL 16, Nginx and systemd. They are installation inputs, not a remote installer: nothing in this directory connects to HZ or changes a server unless an operator deliberately copies the files there and invokes an `--apply` path locally.

The existing HZ sites are out of scope. Do not edit their Nginx files, databases, users, document roots or services. Fiscal uses only `fiscal.linotsai.top`, loopback port `8010`, its own PostgreSQL database/roles and the paths below. Port `8000` belongs to LinoFinance and must remain untouched.

## Ordered first installation

Run each dry path first. The safe first-install sequence is host prerequisites, secret editing, database roles, inactive systemd unit installation, deferred committed release deployment, first operator import, local API start/health, then DNS/TLS/Nginx cutover.

### 1. Bootstrap only the Fiscal host paths and toolchain

`bootstrap-host.sh` verifies that Ubuntu's existing Python, Node.js, PostgreSQL client and Nginx tools are present. Node.js is required only for the pinned Pyright deployment gate; the production API does not run on Node. The bootstrap does not run `apt`, edit an existing Nginx site or change PostgreSQL configuration. Its apply path creates locked `fiscal` and `fiscal_migrator` OS identities, Fiscal-only directories, and an isolated uv environment:

```sh
sudo Backend/ops/production/scripts/bootstrap-host.sh
sudo Backend/ops/production/scripts/bootstrap-host.sh --apply
```

For an existing host that only needs immutable-release access repaired, use the
separate narrow mode. It only creates the dedicated `fiscal_release` group,
adds `fiscal` and `fiscal_migrator`, and verifies that the production environment
file remains `root:fiscal` mode `0640`; it does not install dependencies, touch
`/opt`, or start services:

```bash
sudo Backend/ops/production/scripts/bootstrap-host.sh --release-access --apply
```

The default is exactly uv `0.11.16` at `/opt/fiscal/tools/uv/bin/uv`. Installation uses `https://mirrors.aliyun.com/pypi/simple/` with a 60-second network timeout. `FISCAL_UV_BIN` and the pinned version are explicit environment controls, not a dependency on a global `uv` command.

### 2. Edit secrets locally on HZ

The host bootstrap installs `production.env.example` only when `/etc/fiscal/fiscal.env` does not exist; reruns preserve it. Replace every `CHANGE_ME` value directly on the server. Generate the independent token pepper with at least 32 random bytes, for example `python3 -c 'import secrets; print(secrets.token_urlsafe(32))'`. Generate a different application database password of at least 32 characters and put the percent-encoded value in `FISCAL_DATABASE_URL`.

Do not paste secrets into Git, shell arguments, deployment manifests, support logs or screenshots. Never print the completed environment file.

### 3. Bootstrap the dedicated PostgreSQL database and roles

PostgreSQL must listen only on loopback and use peer authentication for matching local OS/database role names. The bootstrap creates:

- `fiscal_owner`: NOLOGIN owner capability limited to the Fiscal database;
- `fiscal_migrator`: local peer LOGIN inheriting the owner role for Alembic DDL;
- `fiscal_release`: dedicated OS group shared only by `fiscal` and
  `fiscal_migrator` for read/execute access to immutable release trees. It does
  not grant access to `/etc/fiscal/fiscal.env`, which remains `root:fiscal`.
- `fiscal_app`: password LOGIN receiving DML/sequence privileges, no DDL, CREATEDB, CREATEROLE, replication or superuser privilege.

The apply path reads the same application password used in `FISCAL_DATABASE_URL` once from standard input. It never accepts it as an argument:

```sh
sudo Backend/ops/production/scripts/bootstrap-database.sh
sudo Backend/ops/production/scripts/bootstrap-database.sh --apply
```

The second command prompts without echo. Paste the same independently generated value used in `FISCAL_DATABASE_URL`; it does not enter shell history or process arguments. The script is idempotent for roles/grants but intentionally restricted to the database named `fiscal`.

Default privileges are owned by `fiscal_migrator`, so new Alembic tables grant only SELECT/INSERT/UPDATE/DELETE to `fiscal_app`. Backup and restore commands retain local `postgres` authority but the API service cannot use either peer identity.

### 4. Install systemd assets without starting them

The deployment expects its unit to exist, but the production API intentionally cannot start before an active operator exists. Install and validate the units without enabling or starting anything:

```sh
sudo install -o root -g root -m 0644 Backend/ops/production/systemd/*.service /etc/systemd/system/
sudo install -o root -g root -m 0644 Backend/ops/production/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
systemctl cat fiscal-api.service >/dev/null
```

### 5. Deploy the first committed release without starting it

The first installation must use `--defer-start`. This still runs release verification, a verified backup, Alembic as `fiscal_migrator`, and the atomic `current` switch; it deliberately skips restart and health because no active operator exists yet:

```sh
sudo Backend/ops/production/scripts/deploy.sh --source /path/to/Fiscal --defer-start
sudo Backend/ops/production/scripts/deploy.sh --source /path/to/Fiscal --defer-start --apply
```

`--defer-start` is rejected once `/opt/fiscal/current` exists and cannot be combined with `--public-smoke`. Every later deployment must use the ordinary restart/health path.

### 6. Initialize the personal access passphrase

Before the first API start, set the personal passphrase through the recovery CLI.
It reads standard input only, prints no passphrase or access key, and creates
credential generation 1. Keep the value in the approved password manager; it
is the recovery secret for every device.

```sh
printf '%s\n' "$NEW_PASSPHRASE" | sudo -u fiscal sh -c \
  'set -a; . /etc/fiscal/fiscal.env; set +a; cd /opt/fiscal/current/Backend; \
   exec .venv/bin/python -m fiscal_api.cli.access initialize'
```

### 7. Start locally and prove readiness

Only after passphrase initialization succeeds, start the API and verify the dedicated loopback port:

```sh
sudo systemctl start fiscal-api.service
sudo systemctl status fiscal-api.service
curl --fail --show-error http://127.0.0.1:8010/api/v1/health/ready
```

### 8. Bootstrap HTTP, obtain the certificate, then switch to TLS

Do not enable the complete TLS file before its certificate exists. After DNS points to HZ, enable only the Fiscal HTTP bootstrap site; it serves ACME challenges and returns 503 for every other Fiscal request. It does not touch the default site or any existing HZ vhost:

```sh
sudo install -d -o root -g root -m 0755 /var/www/letsencrypt
sudo install -o root -g root -m 0644 \
  Backend/ops/production/nginx/fiscal-bootstrap-http.conf \
  /etc/nginx/sites-available/fiscal-bootstrap-http.conf
sudo ln -s /etc/nginx/sites-available/fiscal-bootstrap-http.conf \
  /etc/nginx/sites-enabled/fiscal.conf
sudo nginx -t
sudo systemctl reload nginx
sudo certbot certonly --webroot -w /var/www/letsencrypt -d fiscal.linotsai.top
```

After certbot succeeds, install the complete site and atomically replace only the Fiscal symlink. Nginx keeps its already loaded HTTP config if validation fails; do not reload until `nginx -t` passes:

```sh
sudo install -o root -g root -m 0644 \
  Backend/ops/production/nginx/fiscal.conf /etc/nginx/sites-available/fiscal.conf
sudo ln -s /etc/nginx/sites-available/fiscal.conf \
  /etc/nginx/sites-enabled/.fiscal.conf.next
sudo mv -Tf /etc/nginx/sites-enabled/.fiscal.conf.next \
  /etc/nginx/sites-enabled/fiscal.conf
sudo nginx -t
sudo systemctl reload nginx
```

If validation fails, point only `/etc/nginx/sites-enabled/fiscal.conf` back to the bootstrap file before investigating. Nginx exposes public liveness and authenticated API routes; readiness stays loopback-only. Uvicorn and PostgreSQL must not have public listeners, and UFW remains limited to the existing SSH policy plus HTTP/HTTPS.

## Release deployment

`deploy.sh` accepts only a committed Git revision and rejects staged, unstaged, missing, or untracked files inside its `Backend` source tree. With no `--apply` it prints a plan and changes nothing. Production releases materialize only that verified `Backend` tree; Apple app sources and historical QA artifacts never enter `/opt/fiscal/releases`. Its apply path:

1. archives the committed revision into a new immutable release;
2. runs Ruff, Pyright and the default backend tests without production DB access;
3. installs locked production dependencies;
4. creates and verifies a pre-migration backup;
5. runs `alembic upgrade head` explicitly as the least-privilege local `fiscal_migrator` peer role;
6. creates and verifies a current-head backup (the pre-migration dump remains for recovery);
7. atomically switches `/opt/fiscal/current`, restarts the API and checks local readiness/backup freshness.

Review first, then apply on the server:

```sh
sudo Backend/ops/production/scripts/deploy.sh --source /path/to/Fiscal
sudo Backend/ops/production/scripts/deploy.sh --source /path/to/Fiscal --apply
```

Before the first deployment from the `App/` + `Backend/` repository layout, reinstall every
tracked service and timer from `Backend/ops/production/systemd/`, then run
`sudo systemctl daemon-reload`. The deploy preflight rejects legacy units that still point to
the old lowercase application directory; this prevents the API and scheduled operations from
breaking after the release symlink switches to the case-sensitive `Backend/` directory.

These commands are for subsequent releases after `current` and an active operator exist. Add `--public-smoke` only after DNS, certificate and Nginx cutover are real. API startup never runs migrations, and subsequent releases must never use `--defer-start`.

Application rollback is deliberately conservative:

```sh
sudo /opt/fiscal/current/Backend/ops/production/scripts/rollback.sh --revision 0123456789ab
sudo /opt/fiscal/current/Backend/ops/production/scripts/rollback.sh --revision 0123456789ab --apply
```

It switches only when the target release and live database have exactly the same Alembic head. If they differ, do not run `alembic downgrade`; restore the verified pre-migration dump into a new database, validate it, and deliberately switch the connection.

## Access passphrase (P20 final state)

The API accepts only current-generation personal access keys. On an installed
macOS or iPhone build, open Settings → 账户与同步 and enter the passphrase to
call `POST /auth/session`; the resulting access key is stored in the system
Keychain. Changing the passphrase (which needs the old value) bumps credential
generation and immediately revokes all previous access keys.

Server-side fallback / recovery (the only forgot-passphrase path) reads the passphrase from standard input and never prints or logs it:

```sh
# One-time set, if the mac-app path is unavailable (creates the credential, generation 1):
printf '%s\n' "$NEW_PASSPHRASE" | sudo FISCAL_ENV_FILE=/etc/fiscal/fiscal.env \
  /opt/fiscal/current/Backend/.venv/bin/python -m fiscal_api.cli.access initialize

# Forgot-passphrase recovery: force a new passphrase and revoke all access keys (generation+1):
printf '%s\n' "$NEW_PASSPHRASE" | sudo FISCAL_ENV_FILE=/etc/fiscal/fiscal.env \
  /opt/fiscal/current/Backend/.venv/bin/python -m fiscal_api.cli.access reset-passphrase
```

Run these under the systemd unit's environment (the app role plus
`FISCAL_TOKEN_PEPPER` and `FISCAL_PASSPHRASE_KDF_ITERATIONS`). After a reset,
every device must reconnect with the new passphrase. Device-token
authentication is permanently absent and an Alembic downgrade across that
boundary is guarded.

## Backup and restore drill

The backup service creates a custom-format `pg_dump`, validates its archive, writes a SHA-256 manifest and retains 14 local days by default. The restore drill checks that manifest, restores into a disposable database, matches Alembic head, verifies canonical tables and rejects orphan postings, then always drops the drill database.

Run both manually before enabling timers:

```sh
sudo systemctl start fiscal-backup.service
sudo systemctl status fiscal-backup.service
sudo systemctl start fiscal-restore-verify.service
sudo systemctl status fiscal-restore-verify.service
```

Successful non-secret facts are written under `/var/lib/fiscal/operations`; dumps remain mode `0600` under `/var/lib/fiscal/backups`. A local dump is not disaster recovery. P11 acceptance separately requires a tested encrypted off-host copy or a confirmed cloud snapshot policy with 90-day retention. Select that provider and record a real restore result without committing its credentials.

## Timers, disk and notification

Enable timers only after manual gates pass:

```sh
sudo systemctl enable --now fiscal-backup.timer
sudo systemctl enable --now fiscal-restore-verify.timer
sudo systemctl enable --now fiscal-health-check.timer
sudo systemctl enable --now fiscal-disk-check.timer
systemctl list-timers 'fiscal-*'
```

Defaults are daily backup, weekly isolated restore, readiness/backup freshness every five minutes, and disk usage every fifteen minutes. Disk state warns at 75% and fails at 85%. The alert receiver is a generic HTTPS JSON webhook configured only in `/etc/fiscal/fiscal.env`; every operational service uses `OnFailure`. An empty or incompatible receiver is an explicit acceptance blocker—journald alone is not notification.

Inspect structured application and operation logs without printing the environment file:

```sh
journalctl -u fiscal-api.service --since today
journalctl -u fiscal-backup.service -u fiscal-restore-verify.service --since today
journalctl -u fiscal-health-check.service -u fiscal-disk-check.service --since today
```

Do not add request headers or environment values to Nginx/systemd log formats. Configure journald retention and verify the existing Nginx logrotate policy before cutover.

## Acceptance evidence

P11 production acceptance still requires operator-run evidence: PG16 migration and full test suite, safe key rotation and old-key rejection, rate-limit behavior, API/PG restart persistence, one real backup restore, off-host recovery, secret scan, HTTPS smoke, alert delivery, and iOS/macOS settings evidence. These files prepare those operations; their presence is not proof that HZ has been changed or tested.
