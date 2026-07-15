# Fiscal P1 Verification Results

Date: 2026-07-14 (Asia/Shanghai)

## Outcome

P1's repository, backend, infrastructure definitions, shared Apple foundation, and native iOS/macOS overview baseline are implemented. Backend and Apple build gates pass, and a normally signed iOS Simulator build has completed a real authenticated request to the local FastAPI process.

The user approved the overall iOS/macOS visual direction on 2026-07-15. The iOS screenshot exposes a known shell defect: the hidden system `TabView` bar remains visible underneath the custom glass tab bar on iOS 26. By user direction, P2 must begin by replacing this layered navigation approach with one custom tab bar and explicit content switching.

P1 remains open only for the registry/network-dependent PostgreSQL and container-image checks.

## Toolchain

- Xcode 26.6
- Swift 6.3.3 with Swift 6 strict concurrency
- Minimum deployment: iOS 26 and macOS 26
- Python 3.14 project environment managed by uv
- PostgreSQL 17 definitions

## Backend

Passed from `backend/`:

- `uv lock --check`
- `uv sync --frozen --offline`
- `uv run --frozen ruff format --check .`
- `uv run --frozen ruff check .`
- `uv run --frozen pyright` — 0 errors
- `uv run --frozen pytest` — 14 passed
- `uv run --frozen alembic upgrade head --sql` — empty P1 baseline containing only Alembic version bookkeeping

Real HTTP checks against the application factory passed for liveness, readiness, missing token, invalid token, and valid token. Request IDs and the structured error envelope were observed. The readiness seam was mocked only because the PostgreSQL container image could not be pulled.

## Apple applications

- iOS generic Simulator build passed.
- macOS Swift tests passed: 4 tests.
- The signed iOS Simulator app stored its bootstrap token through Keychain, called the local API, received HTTP 200 from `/api/v1/system/status`, and rendered the connected state.
- P1 financial values remain presentation-only fixtures and are not persisted.

Visual evidence:

- `screenshots/ios-overview-connected.png` — real connected state
- `screenshots/ios-overview.png` — offline state
- `screenshots/macos-overview.png` — macOS overview baseline

## Infrastructure

- Local PostgreSQL Compose configuration passed static rendering.
- Staging API/PostgreSQL/Caddy Compose configuration passed static rendering.
- Docker Desktop daemon was started successfully.

Blocked externally:

- Docker Hub anonymous-token TLS handshake timed out, so PostgreSQL 17 image startup and the non-root API image build could not be completed.
- No VPS host, DNS target, or deployment credentials were provided; no remote mutation was attempted.

## Remaining acceptance

1. Retry the real PostgreSQL readiness and migration checks when Docker Hub connectivity is available.
2. Retry the API container build and non-root runtime check.
3. Close P1 before beginning P2 business persistence.
4. Start P2 by fixing the iOS double-tab-bar shell defect before adding account/category screens.
