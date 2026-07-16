# Fiscal P11 Contracts

Date: 2026-07-16

Status: frozen for construction

## Scope and production topology

- P11 makes the existing single-user system safe to operate and recover. It does not migrate historical LinoFinance data; that remains P12.
- The HZ server uses its existing Ubuntu 24.04, PostgreSQL 16 and Nginx stack. Fiscal runs as a dedicated unprivileged `fiscal` user from `/opt/fiscal/releases/<revision>` with an atomic `/opt/fiscal/current` symlink and a hardened systemd unit.
- Fiscal receives its own database, roles, loopback API port and HTTPS virtual host. Existing `lf.linotsai.top`, `ln.linotsai.top`, homepage and static sites are out of scope and must not be modified.
- The intended production hostname is `fiscal.linotsai.top`. Deployment may be prepared before DNS exists, but no certificate or public cutover is claimed until its A record points to `118.178.122.194`.
- PostgreSQL and Uvicorn listen only on loopback. UFW continues to expose only SSH, HTTP and HTTPS. Nginx is the sole public application edge.

## Device-key identity and lifecycle

- Fiscal still has no user/login system. A device key authenticates one installation; it is not an account or an end-to-end encryption key.
- New keys contain at least 256 bits of randomness. The database stores only an HMAC-SHA256 digest made with an independent server-side pepper plus a short non-secret fingerprint. Raw keys are returned once and never written to database rows, logs, process arguments, backups or tracked files.
- A key is `pending`, `active` or `revoked`, is versioned, and records label, role, creation, activation, bounded last-use, expiry/revocation and replacement relationships.
- Roles are `device` and `operator`. A normal device can inspect, rotate or remove only itself. An operator key may list, issue or revoke other device keys. The first operator and emergency recovery keys are issued only by a local VPS CLI reading secrets from standard input.
- Rotation is two-phase. Preparing a successor leaves the old key active. The client writes the one-time successor to Keychain and proves possession through activation; only then does the server atomically activate the successor and revoke its predecessor.
- A pending key can call only activation. Invalid, malformed, expired and revoked keys all receive the same non-disclosing `invalid_device_token` response. The last active operator cannot be revoked through the API.
- Local/test may retain an explicit legacy static-token mode for deterministic tests. Staging/production require database-backed keys, a pepper of at least 32 random bytes and at least one active key; the legacy environment token is forbidden after cutover.

## Rate limiting and proxy trust

- The single-process API applies bounded in-memory token buckets: authenticated reads 120/minute, writes 30/minute, AI requests 10/minute and failed authentication 10/minute per source. A rejection returns `429`, `Retry-After` and stable `rate_limit_exceeded` semantics.
- Nginx supplies an independent coarse edge limit and request-body limit. OCR images remain on-device, so the API does not need a large upload allowance.
- The API trusts forwarded client information only from the loopback Nginx proxy. P11 does not claim DDoS protection.

## Production secrets and encryption boundary

- Database credentials, token pepper and AI provider key live only in `/etc/fiscal/fiscal.env`, owned by root and readable by the `fiscal` group. They never enter releases, Git, backups, CLI arguments or Apple bundles.
- TLS protects data in transit between Apple clients and Nginx. PostgreSQL storage and backups rely on server/cloud storage controls; application data is readable by the service to calculate reports and send selected text to the configured AI provider.
- Therefore Fiscal is not end-to-end encrypted and exposes no control claiming otherwise. Settings describes the real transport, storage, AI and Keychain boundaries.

## Backup, recovery and migrations

- The initial operational target is RPO 24 hours and RTO 2 hours. PostgreSQL receives a daily custom-format `pg_dump`, SHA-256 manifest and `pg_restore --list` validation, retained locally for 14 days.
- A backup stored only on the VPS is not disaster recovery. Production acceptance also requires a verified encrypted off-host copy or a confirmed cloud snapshot policy; its provider and 90-day retention are recorded without storing credentials in the repository.
- A restore drill creates an isolated temporary database, restores the newest backup, verifies Alembic head and canonical table/row invariants, records duration/result in a non-secret operations status file, then removes the drill database. P11 must execute one real drill before acceptance.
- Deployments never migrate implicitly during API startup. The order is tests, record current revision, verified pre-migration backup, `alembic upgrade head` with a migrator role, atomic release switch, service restart and local/public smoke tests.
- Application rollback switches the release only when schema-compatible. Production never runs an automatic in-place Alembic downgrade; an incompatible failure restores the pre-migration dump into a new database and switches the connection deliberately.

## Health, monitoring and truthful status

- Public liveness proves only that the process answers. Readiness remains local/monitor-only and proves database reachability. Protected operational status reports current app revision, database/Alembic state, current device metadata, rate-limit policy, latest verified backup/restore facts and disk state.
- Systemd timers perform local health, stale-backup, restore-drill and disk checks. Disk warning/failure thresholds are 75%/85%. Failures must reach a real notification channel before P11 acceptance; journald alone is evidence, not notification.
- Apple Settings shows facts returned by the server and facts derived locally from the last successful sync. It never invents a backup, encryption, token-rotation or VPS state.

## Acceptance boundary

- P11 passes only after a real PostgreSQL migration and full suite, safe key rotation, old-key rejection, rate-limit proof, API/PostgreSQL restart persistence, verified backup restore, production-secret scan, HTTPS smoke test and dual-platform settings evidence.
- P11 does not begin P12 migration and does not alter or remove any existing HZ workload.
