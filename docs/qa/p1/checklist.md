# Fiscal P1 QA Checklist

## Scope and architecture

- [x] `PROJECT_PLAN.md` remains the authority and P1 does not enter P2/P3.
- [x] No formal Account, Category, Transaction, Posting, credit, reimbursement, or AI persistence exists.
- [x] Preview financial data is isolated from live repositories and production configuration.
- [x] Minimum deployment targets are iOS 26 and macOS 26.
- [x] Swift 6 strict concurrency is enabled; no old-system compatibility branches were added.

## Backend

- [x] A clean environment can install dependencies from the committed lock file.
- [ ] PostgreSQL 17 starts from the local Compose definition.
- [ ] Alembic upgrades an empty database to head and a second upgrade is harmless.
- [x] `/api/v1/health/live` succeeds without touching the database.
- [ ] `/api/v1/health/ready` succeeds with PostgreSQL and returns 503 when PostgreSQL is unavailable.
- [x] `/api/v1/system/status` succeeds with the configured device token.
- [x] Missing and invalid tokens produce different stable 401 error codes.
- [x] Error responses and normal responses carry `X-Request-ID`.
- [x] Logs do not reveal tokens or credentials.
- [x] Decimal/CNY and UTC/business-date helpers have automated tests.
- [x] pytest, Ruff format/check, and configured type checks pass.

## Infrastructure

- [x] Local and staging Compose files pass configuration validation.
- [ ] The API image builds without embedding secrets.
- [x] Health checks, persistent PostgreSQL volume, and restart policy are present.
- [x] Caddy template terminates HTTPS and does not expose private configuration.
- [x] Missing required staging configuration fails clearly.
- [x] P11-only backup, monitoring, rate-limit, and token-lifecycle claims are absent.

## Shared Apple foundation

- [x] iOS and macOS use the same API client, system repository, error mapping, token store abstraction, and connection model.
- [x] Live device tokens are stored in Keychain, not source or `UserDefaults`.
- [x] API URL is selected through build configuration.
- [x] Money uses `Decimal`; no financial value travels through `Double`.
- [ ] Unit tests use Swift Testing where appropriate and pass under both schemes.
- [x] Unauthorized, offline, malformed response, server failure, and Keychain failure have distinct user-facing states.

## iOS 26 visual baseline

- [x] The 390×844 reference presentation matches the visual contract's density and hierarchy.
- [x] Header and AI badge are present.
- [x] Monthly spend card and four-category breakdown are present.
- [x] Available balance/account card is present.
- [x] Monthly cash-flow card is present.
- [x] Uncategorized banner is present when required.
- [x] Four recent transactions display semantic colors and tags correctly.
- [x] Floating glass tab shell and centered primary action respect safe areas.
- [x] Hit targets are at least 44 points.
- [x] Other phase destinations are clearly marked as unavailable, not fake implementations.
- [ ] Empty, loading, offline, unauthorized, error, and long-content states were inspected.
- [ ] Dynamic Type and Reduce Motion received a baseline check.

## macOS 26 visual baseline

- [x] The 940×700 reference window matches the visual contract's density and hierarchy.
- [x] The 110-point glass sidebar and top toolbar are present.
- [x] Four summary cards are present.
- [x] Recent-transactions table is readable and aligned.
- [x] Account overview and future-cash-flow mini card are present.
- [ ] A narrower window does not overlap or clip key amounts.
- [x] Other phase destinations are clearly marked as unavailable.
- [ ] Empty, loading, offline, unauthorized, error, and long-content states were inspected.
- [ ] Keyboard focus, Dynamic Type where applicable, and Reduce Motion received a baseline check.

## Real integration

- [ ] Both apps show connection status from the real `/api/v1/system/status` endpoint.
- [ ] Local API, stopped API, stopped database, valid token, and invalid token were exercised.
- [x] Staging HTTPS was exercised when VPS credentials and DNS were available; otherwise the exact external blocker is recorded.
- [x] No URL, token, or secret is hard-coded in a committed production source file.

## Screenshots and handoff

- [x] `docs/qa/p1/screenshots/ios-overview.png` exists.
- [x] `docs/qa/p1/screenshots/macos-overview.png` exists.
- [ ] Narrow/long-content evidence is retained where useful.
- [x] Screenshots were compared manually with `design_handoff_fiscal_app/`.
- [x] Build and test commands/results are recorded.
- [x] `git diff --check` passes and only expected changes remain.
- [ ] User completed the P1 visual review before P2 begins.
