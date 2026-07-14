# Fiscal

Fiscal is a private, single-user personal-finance application for iOS 26 and macOS 26. The repository is currently implementing the P1 engineering and visual foundation defined in [`PROJECT_PLAN.md`](PROJECT_PLAN.md).

## Repository map

- `backend/` — FastAPI, SQLAlchemy, Alembic, PostgreSQL access, and P1 system endpoints.
- `apple/` — native SwiftUI iOS/macOS applications and shared `FiscalKit`.
- `infra/` — local PostgreSQL and VPS staging deployment scaffolding.
- `docs/architecture/` — phase-level implementation contracts.
- `docs/qa/` — acceptance checklists, results, and screenshots.
- `design_handoff_fiscal_app/` — read-only visual contract; it is not production code.

P1 deliberately contains no formal account, category, transaction, posting, credit, reimbursement, or AI persistence. Financial figures on the overview are isolated presentation fixtures until later phases deliver the relevant ledger services.

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

## Infrastructure

See [`infra/README.md`](infra/README.md) for local PostgreSQL, staging HTTPS, migration, and rollback commands. P1 does not claim production backup/restore, monitoring, rate limiting, or token lifecycle management; those remain P11 work.

## P1 acceptance

- Contract: [`docs/architecture/p1-contracts.md`](docs/architecture/p1-contracts.md)
- Checklist: [`docs/qa/p1/checklist.md`](docs/qa/p1/checklist.md)
- Screenshots: `docs/qa/p1/screenshots/`

P2 must not begin until the P1 build gates pass and the user approves the native iOS/macOS visual baseline.
