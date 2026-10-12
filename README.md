# Fiscal

Fiscal is a private, single-user personal-finance ledger. The native iOS/macOS client (Build 51) is retired; the active operating surface is the remote MCP gateway backed by the existing FastAPI/PostgreSQL ledger and its minimal TOTP approval/discovery Web pages. Product scope and the pause point live in [`PROJECT_PLAN.md`](PROJECT_PLAN.md); release and archive records live under [`archive/`](archive/).

## Repository map

- `MCP/` — remote MCP gateway (JSON-RPC over HTTP/stdio, TOTP sessions, operation approvals) deployed on HZ.
- `Backend/` — FastAPI, SQLAlchemy, Alembic, PostgreSQL, the unified ledger, and `ops/` deployment tooling.
- `Web/` — Agent discovery, TOTP approval pages (required by MCP) and the Web console.
- `archive/` — historical audits, design sources, plans, release contracts, QA results, and screenshots.
- `AGENTS.md` — repository-specific engineering rules and verification gates.
- `PROJECT_PLAN.md` — current product position, invariants, risks, and next authorized work.

## Toolchain

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

## Native applications (retired)

The native iOS/macOS client was retired on 2026-10-12. Its full source is preserved at the immutable tag `native-app-final` (`git checkout native-app-final -- App`); the frozen Build 51 release artifacts are archived outside the repository as recorded in [`archive/plans/2026-10-12-native-app-retirement.md`](archive/plans/2026-10-12-native-app-retirement.md).

## Infrastructure

See [`Backend/ops/README.md`](Backend/ops/README.md) for local PostgreSQL and staging, and [`Backend/ops/production/README.md`](Backend/ops/production/README.md) for the isolated HZ native deployment, migration, rollback, backup/restore and monitoring workflow.

## Release evidence

- Last native release (V2.4.0 Build 51): [`archive/releases/v2.4.0/RELEASE_STATE.md`](archive/releases/v2.4.0/RELEASE_STATE.md).
- Historical contracts and QA: [`archive/README.md`](archive/README.md).

## 当前运行方式

原生 App 已退役并移出仓库（tag `native-app-final`）。日常账单导入、校验、提交和分析统一通过 `https://mcp.fiscal.linotsai.top/mcp` 完成；MCP 通过 TOTP Session 调用现有 Backend/PostgreSQL 账本。Web 站点提供 Agent discovery、公开接入说明和 TOTP 批准页（MCP 鉴权链路必需），网页控制台继续保留。云端收口见 [`archive/plans/2026-10-11-fiscal-pause_archive_execution.md`](archive/plans/2026-10-11-fiscal-pause_archive_execution.md)，仓库退役与本地归档位置见 [`archive/plans/2026-10-12-native-app-retirement.md`](archive/plans/2026-10-12-native-app-retirement.md)。
