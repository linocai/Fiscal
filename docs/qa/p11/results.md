# Fiscal P11 QA Results

Date: 2026-07-16

Status: local engineering gates passed; HZ isolated deployment and public acceptance remain in progress.

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

## HZ gates still open

- Apply the committed release to the dedicated Fiscal user/database/port without changing existing HZ workloads.
- Execute one current-schema backup and isolated restore drill on PostgreSQL 16.
- Prove API/PostgreSQL restart persistence, production rotation and old-key rejection.
- Confirm an encrypted off-host copy or cloud snapshot policy with 90-day retention.
- Configure and test a real alert receiver; journald alone is not accepted.
- Add the `fiscal.linotsai.top` A record, obtain its certificate, run HTTPS smoke tests and capture dual-platform production Settings evidence.

P12 historical migration has not started.
