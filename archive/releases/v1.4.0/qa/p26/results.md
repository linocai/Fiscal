# P26-A · Synthetic Statement Provider Attempts

状态：**Automated Verified**（受限 P26-A）；未部署、未连接生产 Provider 或外部网络。

## 范围与隐私边界

- `POST /api/v1/statement-imports/{id}/provider-attempts` 仅支持固定的
  `synthetic_statement` adapter。它不使用 `URLSession`、HTTP client、Provider 配置或密钥；adapter
  只接收已保存的脱敏 page/row evidence，并返回本地空候选的合成结果。
- 启动请求以 `expected_version`、evidence SHA-256、逐页/行 preview 摘要、脱敏版本/计数和 UUID
  `Idempotency-Key` 绑定。相同 key 的同一请求稳定 replay；请求内容或批次不同则拒绝。
- 出站 allowlist 只有 `schema_version`、`currency`、page 的页号/类型/脱敏文本、row 的页号/行号/脱敏文本/归一化坐标。
  PDF bytes、页面图像、URL、文件名、document hash、身份字段、密钥及任何原文均不进入 provider request。
- 服务端再次以确定性规则拒绝未脱敏的账号/卡号、姓名/地址/客户号标记值、手机号、邮箱和身份证格式。严格 result schema
  仅允许受证据行引用证明的候选字段；document 与 uncertain field 为固定安全枚举。
- authorization、出站 request、validated result 为 append-only provider snapshots；source row references 有独立表并由 Archive
  自动纳入及还原。无 PDF/image 字段或候选/账本写入。operation log 仅含 attempt/count/stable error code。
- 429/5xx、timeout、取消和非法 result 仅将 batch/attempt 变为可重试的 `failed`，不保存 validated candidate snapshot，且不创建 transaction/posting。

## 自动验证（2026-08-12）

- `uv run ruff check src/fiscal_api/api/p26_schemas.py src/fiscal_api/services/statement_imports.py tests/test_p26_statement_provider_postgres.py` → **passed**。
- `uv run pyright src/fiscal_api/api/p26_schemas.py src/fiscal_api/services/statement_imports.py` → **0 errors**。
- `FISCAL_TEST_DATABASE_URL='postgresql+asyncpg://linotsai@/fiscal_p26_verify?host=/tmp' uv run pytest -q tests/test_p24_statement_import_postgres.py tests/test_p26_statement_provider_postgres.py` → **7 passed**。覆盖 outgoing allowlist/redaction、预览 binding、idempotency/replay、429 stable failure/retry、非法 schema、零 ledger/posting、snapshot/source-ref Archive dry-run 与 fresh-target restore。
- `FISCAL_TEST_DATABASE_URL='postgresql+asyncpg://linotsai@/fiscal_p26_full2?host=/tmp' uv run pytest -q` → **259 passed**（fresh PostgreSQL；仅有既有 TestClient deprecation warning）。该门建立在独立提交 `3a57f5d` 已修复的 P21 fixture 之上，P10/P21 不再是阻断项。
- Apple seam：`xcodebuild test -project App/Fiscal.xcodeproj -scheme FiscalmacOS -configuration Debug -derivedDataPath /tmp/fiscal-p26-test-derived CODE_SIGNING_ALLOWED=NO` → **108 tests / 20 suites passed**；macOS 与 iOS Simulator Debug build 均 **BUILD SUCCEEDED**。

## 已知验证边界

- P26-A 不会调用真实 provider，也不包含 P28 导入工作台、候选确认/账本投递、真实 PDF 或生产操作。
- 真实 provider transport、受控凭证和模型选择仍须由后续门另行批准；旧 authorization 永不因 Archive restore 或 retry 自动重用。
