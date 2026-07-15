# Fiscal

Fiscal is a private, single-user personal-finance application for iOS 26 and macOS 26. P1 established the engineering and visual foundation, P2 account/category master data passed user acceptance, and P3 unified-ledger construction is complete pending visual acceptance under [`PROJECT_PLAN.md`](PROJECT_PLAN.md).

## Repository map

- `backend/` — FastAPI, SQLAlchemy, Alembic, PostgreSQL access, system endpoints, master data, and the unified ledger.
- `apple/` — native SwiftUI iOS/macOS applications and shared `FiscalKit`.
- `infra/` — local PostgreSQL and VPS staging deployment scaffolding.
- `docs/architecture/` — phase-level implementation contracts.
- `docs/qa/` — acceptance checklists, results, and screenshots.
- `design_handoff_fiscal_app/` — read-only visual contract; it is not production code.

P3 introduces manual CNY income, expense, and transfer transactions backed by server-generated account impacts. Credit statement cycles, repayments, installments, reimbursements, reports, and AI persistence remain later phases. Financial figures on the overview stay isolated presentation fixtures until their reporting slices replace them.

## Toolchain

- Xcode 26.6
- Swift 6.3.3 in Swift 6 language mode with complete strict concurrency
- Minimum iOS 26 / macOS 26
- Python 3.12 managed by `uv`
- PostgreSQL 17
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

P1 endpoints:

```sh
curl http://127.0.0.1:8000/api/v1/health/live
curl http://127.0.0.1:8000/api/v1/health/ready
curl -H 'Authorization: Bearer development-device-token-change-me' \
  http://127.0.0.1:8000/api/v1/system/status
```

The default token is local-development-only. Staging and production reject that default and require an external secret of at least 32 characters.

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

The debug API base URL is `http://127.0.0.1:8000`, with local-network transport enabled only for development. Override `FISCAL_API_BASE_URL` with an HTTPS endpoint through build settings for staging and release. Provide `FISCAL_DEVICE_TOKEN` as a Run-scheme environment value only for the first bootstrap; the app transfers it to this-device-only Keychain storage.

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

See [`infra/README.md`](infra/README.md) for local PostgreSQL, staging HTTPS, migration, and rollback commands. P1 does not claim production backup/restore, monitoring, rate limiting, or token lifecycle management; those remain P11 work.

## Phase contracts and acceptance

- P1 contract/results: [`docs/architecture/p1-contracts.md`](docs/architecture/p1-contracts.md), [`docs/qa/p1/results.md`](docs/qa/p1/results.md)
- P2 contract/checklist/results: [`docs/architecture/p2-contracts.md`](docs/architecture/p2-contracts.md), [`docs/qa/p2/checklist.md`](docs/qa/p2/checklist.md), [`docs/qa/p2/results.md`](docs/qa/p2/results.md)
- P3 contract/checklist/results: [`docs/architecture/p3-contracts.md`](docs/architecture/p3-contracts.md), [`docs/qa/p3/checklist.md`](docs/qa/p3/checklist.md), [`docs/qa/p3/results.md`](docs/qa/p3/results.md)

The user approved the native iOS/macOS visual direction before P2. Each phase still requires real API integration, dual-platform screenshots, automated gates, and explicit acceptance before the next business slice begins.
