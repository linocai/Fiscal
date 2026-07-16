# Fiscal P11 QA Results

Date: 2026-07-16

Status: HZ deployment and HTTPS cutover passed; final operational and dual-platform acceptance evidence remains in progress.

## Delivered locally

- Database-backed device keys with HMAC-SHA256 digest storage, operator/device roles, pending/active/revoked lifecycle, optimistic versions, last-operator protection and stdin-only first-operator bootstrap.
- Two-phase rotation across server and Apple Keychain, including lost-response recovery, old-key preservation and one-time transferred-token activation for a new iPhone or Mac.
- Bounded single-worker read/write/AI/failed-auth rate limits with stable `429` and `Retry-After` behavior.
- Protected security and operations status. Backup, isolated restore and disk facts are read only from bounded root-owned JSON records; missing records render as unavailable rather than fabricated success.
- Modern iOS/macOS Settings presentation for VPS, sync/security boundaries, device lifecycle, backup/restore/disk facts and accurate “remove this device key” semantics. No login/logout or fake end-to-end encryption control exists.
- Native Ubuntu 24.04/PostgreSQL 16/Nginx/systemd assets using dedicated port `8010`, service/database roles, immutable releases, deferred first start, dry-run bootstraps, fixed uv `0.11.16`, Aliyun package mirror, backups, restore drills, disk/health timers and an ACME-before-TLS cutover.

## Automated verification

- Backend Ruff format/check: passed.
- Backend Pyright strict: 0 errors.
- Empty PostgreSQL 14.22 migration from base through `20260716_0010`: passed.
- Alembic schema drift check: no new upgrade operations.
- Full PostgreSQL-backed backend suite: 186 passed; one upstream Starlette/httpx deprecation warning.
- Apple macOS Swift suite: 69 tests in 11 suites passed, including five P11 device-security cases.
- iOS 26 and macOS 26 Release builds: passed with Swift 6; both resolved the production API URL to `https://fiscal.linotsai.top`.
- Production shell assets: all Bash syntax and default dry-run paths passed; first-install/deferred-start and incompatible option guards passed.
- Tracked-tree secret scan found placeholders only; no real production token, database password, pepper or AI key is committed.

## HZ production evidence

- Release `e31fc23258b8dec726fc725eb8fb9f3e1e0906de` is active under `/opt/fiscal/releases`; the live database is at Alembic `20260716_0010`.
- Dedicated `fiscal`/`fiscal_migrator` OS users, `fiscal_owner`/`fiscal_migrator`/`fiscal_app` database roles, root-owned environment state and the separate `fiscal` database are installed.
- Fiscal listens only on `127.0.0.1:8010`; PostgreSQL remains loopback-only and UFW still exposes only 22/80/443.
- `fiscal.linotsai.top` resolves to `118.178.122.194`. The ECDSA certificate is valid through 2026-10-14; HTTP redirects to HTTPS, public liveness returns 200, readiness remains denied publicly, unauthenticated protected routes return 401 and a real Keychain-backed operator request returns 200.
- The first `Primary Mac` operator is active; its raw key exists only in the local macOS Keychain and the database stores its digest/fingerprint.
- A real production two-phase rotation stored the candidate in the Keychain pending slot before activation, promoted it after activation, returned 200 with the successor and 401 with the revoked predecessor.
- A systemd-run custom-format backup completed with checksum/archive validation. An isolated restore drill completed in two seconds at the deployed Alembic head and passed canonical-table/orphan checks. Disk status is healthy at 25% against 75%/85% thresholds.
- Backup, weekly restore, five-minute health and fifteen-minute disk timers are enabled. API restart and repeated release restarts preserved authentication.
- LinoFinance, LinoN, Nginx and PostgreSQL remained active; their public health endpoints passed and ports 8000/8001 were unchanged.
- Production deploy gates passed on HZ for each final release: Ruff format/check, Pyright and 99 database-independent tests (87 PostgreSQL tests intentionally skipped in the no-production-DB test gate). Full PostgreSQL-backed coverage remains the 186-test local gate above.

## Gates still open

- Confirm an encrypted off-host copy or cloud snapshot policy with 90-day retention; active HBR agents alone do not prove Fiscal coverage or restoration.
- Configure and test a real alert receiver; journald alone is not accepted.
- Capture iOS and macOS production Settings evidence.
- Restart the shared PostgreSQL cluster only in an approved maintenance window, then recheck Fiscal and LinoFinance. P11 did not disrupt the shared database merely to satisfy a checkbox.

P12 historical migration has not started.
