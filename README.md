# Fiscal

Fiscal is a private, single-user personal-finance application for iOS 26 and macOS 26. P1–P10 cover the unified ledger, credit cycles, installments, reimbursements, reports, AI/OCR capture, and the finished dual-platform daily-use experience described in [`PROJECT_PLAN.md`](PROJECT_PLAN.md). P11 production security and HZ operations are in progress.

## Repository map

- `backend/` — FastAPI, SQLAlchemy, Alembic, PostgreSQL access, system endpoints, master data, and the unified ledger.
- `apple/` — native SwiftUI iOS/macOS applications and shared `FiscalKit`.
- `infra/` — local PostgreSQL and VPS staging deployment scaffolding.
- `docs/architecture/` — phase-level implementation contracts.
- `docs/qa/` — acceptance checklists, results, and screenshots.
- `design_handoff_fiscal_app/` — read-only visual contract; it is not production code.

The current product uses one canonical CNY ledger across accounts, credit cycles, installments, reimbursements and reports. iOS remains list-first and chart-free with one custom bottom bar; macOS uses dense native tables, inspectors and report visualizations. P10 adds uncategorized batch handling, advanced search/filtering, device-local recording preferences, short read-only caching, semantic dark mode and filtered CSV export.

## Toolchain

- Xcode 26.6
- Swift 6.3.3 in Swift 6 language mode with complete strict concurrency
- Minimum iOS 26 / macOS 26
- Python 3.12 managed by `uv`
- PostgreSQL 16+ in production (the full local migration suite is also exercised on PostgreSQL 14)
- Docker Compose v2 for local/staging infrastructure

## Backend

Start PostgreSQL from the repository root:

```sh
docker compose -f infra/compose.local.yml up -d postgres
```

Then initialize and run the API:

```sh
cd backend
cp .env.example .env
uv sync --frozen
uv run --frozen alembic upgrade head
uv run --frozen uvicorn fiscal_api.main:app --reload
```

Foundation endpoints:

```sh
curl http://127.0.0.1:8000/api/v1/health/live
curl http://127.0.0.1:8000/api/v1/health/ready
curl -H 'Authorization: Bearer development-device-token-change-me' \
  http://127.0.0.1:8000/api/v1/system/status
```

The default token is local-development-only. Staging and production reject static tokens, require an independent pepper of at least 32 bytes, and authenticate HMAC-digested database device keys.

Run backend gates:

```sh
cd backend
uv lock --check
uv sync --frozen --offline
uv run --frozen ruff format --check .
uv run --frozen ruff check .
uv run --frozen pyright
uv run --frozen pytest
uv run --frozen alembic upgrade head --sql
```

## Apple applications

Generate the Xcode project and run the two build gates:

```sh
cd apple
xcodegen generate
xcodebuild \
  -project Fiscal.xcodeproj \
  -scheme FiscaliOS \
  -destination 'generic/platform=iOS Simulator' \
  build
xcodebuild \
  -project Fiscal.xcodeproj \
  -scheme FiscalmacOS \
  -destination 'platform=macOS,arch=arm64' \
  test
```

The debug API base URL is `http://127.0.0.1:8000`, with local-network transport enabled only for development. Release builds use `https://fiscal.linotsai.top`. Provide `FISCAL_DEVICE_TOKEN` as a Run-scheme environment value only for the first trusted Mac bootstrap; later devices can paste an operator-issued pending key into Settings and activate it directly into this-device-only Keychain storage.

With the local integration API running and seeded, run the authenticated iOS navigation/data acceptance tests on an available simulator:

```sh
xcodebuild \
  -project Fiscal.xcodeproj \
  -scheme FiscaliOS \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  test
```

The shared scheme uses the local-only `integration-device-token`; it must match the test API process and is not a production credential.

## Infrastructure

See [`infra/README.md`](infra/README.md) for local PostgreSQL and staging, and [`infra/production/README.md`](infra/production/README.md) for the isolated HZ native deployment, migration, rollback, backup/restore and monitoring workflow.

## Phase contracts and acceptance

- P1 contract/results: [`docs/architecture/p1-contracts.md`](docs/architecture/p1-contracts.md), [`docs/qa/p1/results.md`](docs/qa/p1/results.md)
- P2 contract/checklist/results: [`docs/architecture/p2-contracts.md`](docs/architecture/p2-contracts.md), [`docs/qa/p2/checklist.md`](docs/qa/p2/checklist.md), [`docs/qa/p2/results.md`](docs/qa/p2/results.md)
- P3 contract/checklist/results: [`docs/architecture/p3-contracts.md`](docs/architecture/p3-contracts.md), [`docs/qa/p3/checklist.md`](docs/qa/p3/checklist.md), [`docs/qa/p3/results.md`](docs/qa/p3/results.md)
- P4–P9 contracts and results remain under `docs/architecture/` and `docs/qa/`.
- P10 contract/checklist/results: [`docs/architecture/p10-contracts.md`](docs/architecture/p10-contracts.md), [`docs/qa/p10/checklist.md`](docs/qa/p10/checklist.md), [`docs/qa/p10/results.md`](docs/qa/p10/results.md)
- P11 contract/checklist/results: [`docs/architecture/p11-contracts.md`](docs/architecture/p11-contracts.md), [`docs/qa/p11/checklist.md`](docs/qa/p11/checklist.md), [`docs/qa/p11/results.md`](docs/qa/p11/results.md)

The user approved the native iOS/macOS visual direction before P2. Each phase still requires real API integration, dual-platform screenshots, automated gates, and explicit acceptance before the next business slice begins.
