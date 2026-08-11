# P22 · 数据自主与一致性框架

状态：**Automated Verified（本地）**；**Production / macOS + Kurisu 物理验收未授权、未执行**。P22 只形成可回退本地提交，不部署、不迁移生产、不打 tag/push。

## 已冻结契约

- Fiscal Archive v1 使用独立 12–128 字符密码、Scrypt（N=32768, r=8, p=1）和 AES-256-GCM；manifest 作为 AEAD AAD，payload 为压缩后的规范 JSON。随机 salt 为 16 bytes、nonce 为 12 bytes。
- manifest 固定记录 archive/API schema、UTC 导出时间、`Asia/Shanghai`、CNY、Alembic/data revision、实体计数、payload SHA-256、AI 原文选择与 provider 需重新配置。access credential/key、provider key/config、环境和日志不进入 payload；AI 原文默认替换为明确 marker。
- restore 只能先 dry-run，再写空隔离数据库；严格检查 head、实体/字段集合、计数、PK/FK、金额摘要。恢复后以 PostgreSQL 实测 count、orphan、posting signed/absolute totals、派生账户余额和交易报表 fingerprint 对照源库。不存在合并或覆盖路径。
- `data_revision` 在真实正式 mutation 的同一事务中原子递增一次；preview、认证、read-only POST、校验失败、rollback 和幂等 replay 都不递增。响应仅在成功 receipt 时给出 revision/scopes；路由矩阵锁定 scope allowlist。
- 双端 foreground/scene-active 查询当前 revision；receipt 有 scope 时精确刷新，外部/Archive epoch 的未知 scope 保守全量刷新。poll 在本机写入期间以起始 baseline 避免旧响应覆盖新 receipt。
- 最近只读快照和主交易未提交草稿写入同一把本机 Keychain AES key 加密的 Application Support payload；URL/key/时间/内容均在 AEAD payload 内。仅真实 transport failure 可读 snapshot；任何 live 2xx 清离线状态。快照最多 128 条、16 MiB，单响应最多 1 MiB；无离线 mutation/队列/重放。主录入在 snapshot 离线态禁用正式提交，仅允许显式保存、恢复后人工提交且保留 idempotency key。
- 导出入口目前为受支持的 operator CLI 与 runbook：[archive-runbook.md](archive-runbook.md)。**App 内双端导出 UI deferred**，不得称用户可直接从 iOS/macOS 导出；受保护 API 仅供受信客户端使用。

## 本地验证

- Backend: `ruff format --check src tests`、`ruff check src tests`、`pyright` 均通过。
- PostgreSQL P22 定向：`7 passed`（含四并发 revision、Archive roundtrip、错误密码/篡改、完整行 duplicate PK/orphan FK preflight、空库未写、CLI stdin、既有文件预留前拒绝、export/write 失败清理 partial，以及解密 payload 验证 AI raw 默认排除/显式保留）。
- Fresh PostgreSQL `fiscal_p22_fresh`：`pytest --junitxml=/tmp/fiscal-p22-fresh.xml`，JUnit `245 tests / 0 failures / 0 errors / 0 skipped`。
- Alembic disposable `fiscal_p22_migration`：base→`20260811_0022`→`20260811_0021`→head 成功；offline SQL 含 `data_revision` create/seed。
- Apple: `xcodegen generate`；`FiscalmacOS` 的 `FiscalKitTests` 为 `101 tests / 19 suites` 通过；`FiscaliOS` generic iOS Release build 成功；`FiscalmacOS` Release build 成功，产物经 `codesign --verify --deep --strict` 验证。

## 生产门与风险

生产仍需用户针对 P22 明确授权后，先在受控备份上做隔离 Archive dry-run/apply、数据库与应用 smoke、再决定切换；禁止对现库覆盖或 merge。之后才可执行 P22 production migration/deploy，最后安排 macOS 与 Kurisu 真机/签名 Release 验收。
