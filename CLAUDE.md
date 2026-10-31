# Fiscal — Claude 项目经验

项目事实与约束以 `AGENTS.md` 为准；本文件只记 Claude 接手后摸出的坑。

## 本地端到端（真实 Backend + MCP service）

- 一次性库：`createdb -h 127.0.0.1 <name>`，`FISCAL_DATABASE_URL=postgresql+asyncpg://linotsai@127.0.0.1:5432/<name> uv run alembic upgrade head`（在 `Backend/` 下）。用完 `dropdb`。
- 后端用 `create_app(settings=Settings(environment="test", ...), readiness_check=...)` + `TestClient`，test 环境任意 Bearer 可用。MCP 的 `HttpFiscalBackendAdapter(base_url="http://testserver/api/v1", batch_path="/import-batches", client=<把 TestClient 包成 async request 的薄壳>)`。
- 批次提交走 `get_settings()`（读环境变量），必须设 `FISCAL_IMPORT_CONFIRMATION_SECRET`（≥32 字节）且与 MCP 的 `HMACConfirmationVerifier` 同一秘密，否则 503 `confirmation_unconfigured`。
- 写入窗口：`TotpSessionRegistry` 批准 session 后，write_window 要用下一个 30 秒时间步的验证码（同一时间步只接受一次）。
- 后端分期等资格判断用真实时钟（今天）；pytest 的 conftest 把时钟钉在 2026-07-15，脚本里不会。

## 门禁

- MCP 目录没有 ruff 配置，`ruff check`/`format --check` 在基线上就有 1 个 F401 和 15 个文件格式差异；验收时与基线比较，不新增即可。ruff 可用 `Backend/.venv/bin/ruff`。
