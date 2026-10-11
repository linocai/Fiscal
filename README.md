# Fiscal

Fiscal is a private, single-user personal-finance ledger. The native iOS/macOS client is frozen at Build 51; the active operating surface is the remote MCP gateway backed by the existing FastAPI/PostgreSQL ledger and its minimal TOTP approval/discovery Web pages. Product scope and the pause point live in [`PROJECT_PLAN.md`](PROJECT_PLAN.md); release and archive records live under [`archive/`](archive/).

## Repository map

- `App/` — native SwiftUI iOS/macOS applications and shared `FiscalKit`.
- `Backend/` — FastAPI, SQLAlchemy, Alembic, PostgreSQL, the unified ledger, and `ops/` deployment tooling.
- `archive/` — historical audits, design sources, plans, release contracts, QA results, and screenshots.
- `AGENTS.md` — repository-specific engineering rules and verification gates.
- `PROJECT_PLAN.md` — current product position, invariants, risks, and next authorized work.

## Toolchain

- Xcode 27+
- Swift 6.3.3 in Swift 6 language mode with complete strict concurrency
- Minimum iOS 27 / macOS 27
- Python 3.12 managed by `uv`
- PostgreSQL 16+ in production (the full local migration suite is also exercised on PostgreSQL 14)
- Docker Compose v2 for local/staging infrastructure

## Backend

Start PostgreSQL from the repository root:

```sh
docker compose -f Backend/ops/compose.local.yml up -d postgres
```

Then initialize and run the API:

```sh
cd Backend
cp .env.example .env
uv sync --frozen
uv run --frozen alembic upgrade head
uv run --frozen uvicorn fiscal_api.main:app --reload
```

Foundation endpoints:

```sh
curl http://127.0.0.1:8000/api/v1/health/live
curl http://127.0.0.1:8000/api/v1/health/ready
curl -H 'Authorization: Bearer YOUR_CURRENT_ACCESS_KEY' \
  http://127.0.0.1:8000/api/v1/system/status
```

The default token is local-development-only. Staging and production reject static tokens, require an independent pepper of at least 32 bytes, and use the personal access-passphrase/access-key model. P20 records whether a live deployment has fully exited the legacy transition layer in [`archive/releases/v1.0-v1.3/qa/p20/results.md`](archive/releases/v1.0-v1.3/qa/p20/results.md); do not infer that from this repository.

Run backend gates:

```sh
cd Backend
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
cd App
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

The debug API base URL is `http://127.0.0.1:8000`, with local-network transport enabled only for development. Release builds use `https://fiscal.linotsai.top`. A production client receives a generated access key after the user verifies the personal access passphrase; it stores that opaque key in Keychain. Do not use the local integration key as a production credential.

With the local integration API running and seeded, run the authenticated iOS navigation/data acceptance tests on an available simulator:

```sh
xcodebuild \
  -project Fiscal.xcodeproj \
  -scheme FiscaliOS \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  test
```

The shared scheme injects a local-only access-key fixture for UI tests; it is
never a production credential.

## Infrastructure

See [`Backend/ops/README.md`](Backend/ops/README.md) for local PostgreSQL and staging, and [`Backend/ops/production/README.md`](Backend/ops/production/README.md) for the isolated HZ native deployment, migration, rollback, backup/restore and monitoring workflow.

## Release evidence

- Current signed release and local-install manifest: [`archive/releases/v2.2.0/build41/RELEASE_STATE.md`](archive/releases/v2.2.0/build41/RELEASE_STATE.md).
- Prior signed release: [`archive/releases/v2.2.0/RELEASE_STATE.md`](archive/releases/v2.2.0/RELEASE_STATE.md) (build 40).
- Prior full QA history: [`archive/releases/v1.5.0/qa/frontend/f5-results.md`](archive/releases/v1.5.0/qa/frontend/f5-results.md).
- Historical contracts and QA: [`archive/README.md`](archive/README.md).

## 当前运行方式

原生 App 已冻结并作为历史发布物归档。日常账单导入、校验、提交和分析统一通过 `https://mcp.fiscal.linotsai.top/mcp` 完成；MCP 通过 TOTP Session 调用现有 Backend/PostgreSQL 账本。Web 站点只保留 Agent discovery、公开接入说明和 TOTP 批准页，是 MCP 鉴权链路的支撑页面。归档和云端收口边界见 [`archive/plans/2026-10-11-fiscal-pause_archive_execution.md`](archive/plans/2026-10-11-fiscal-pause_archive_execution.md)。
