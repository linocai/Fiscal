# P22 · 数据自主与一致性框架

状态：**Automated Verified + Archive Shadow Verified**；`ai_settings` seed 与 credit GET 隐式写入缺口均已修复并通过 fresh shadow 复验。**生产仍为 `4686e449 / 20260811_0021`；因 SSH banner timeout 尚未执行 0022 迁移/部署、QA mutation 或 macOS + Kurisu 物理验收**。不打 tag/push。

## 已冻结契约

- Fiscal Archive v1 使用独立 12–128 字符密码、Scrypt（N=32768, r=8, p=1）和 AES-256-GCM；manifest 作为 AEAD AAD，payload 为压缩后的规范 JSON。随机 salt 为 16 bytes、nonce 为 12 bytes。
- manifest 固定记录 archive/API schema、UTC 导出时间、`Asia/Shanghai`、CNY、Alembic/data revision、实体计数、payload SHA-256、AI 原文选择与 provider 需重新配置。access credential/key、provider key/config、环境和日志不进入 payload；AI 原文默认替换为明确 marker。
- restore 只能先 dry-run，再写空隔离数据库；严格检查 head、实体/字段集合、计数、PK/FK、金额摘要。fresh head 唯一允许的非业务行是精确 canonical `ai_settings` migration seed（时间字段忽略）；任何改动的 seed、auth/access 数据、其他表行或非零 `data_revision` 都在写入前拒绝。恢复后以 PostgreSQL 实测 count、orphan、posting signed/absolute totals、派生账户余额和交易报表 fingerprint 对照源库。不存在合并或覆盖路径。
- `data_revision` 在真实正式 mutation 的同一事务中原子递增一次；preview、认证、read-only POST、校验失败、rollback 和幂等 replay 都不递增。响应仅在成功 receipt 时给出 revision/scopes；路由矩阵锁定 scope allowlist。
- credit GET 只投影当前账期：未物化 regular cycle 使用 account+账期 UUIDv5 与确定 UTC 元数据；list/get/pagination/deep-link 均不锁、不 flush、不 commit。随后的正式交易才以同 ID 物化，并获得唯一 formal-mutation receipt。
- 双端 foreground/scene-active 查询当前 revision；receipt 有 scope 时精确刷新，外部/Archive epoch 的未知 scope 保守全量刷新。poll 在本机写入期间以起始 baseline 避免旧响应覆盖新 receipt。
- 最近只读快照和主交易未提交草稿写入同一把本机 Keychain AES key 加密的 Application Support payload；URL/key/时间/内容均在 AEAD payload 内。仅真实 transport failure 可读 snapshot；任何 live 2xx 清离线状态。快照最多 128 条、16 MiB，单响应最多 1 MiB；无离线 mutation/队列/重放。主录入在 snapshot 离线态禁用正式提交，仅允许显式保存、恢复后人工提交且保留 idempotency key。
- 导出入口目前为受支持的 operator CLI 与 runbook：[archive-runbook.md](archive-runbook.md)。**App 内双端导出 UI deferred**，不得称用户可直接从 iOS/macOS 导出；受保护 API 仅供受信客户端使用。

## 本地验证

- Backend: `ruff format --check src tests`、`ruff check src tests`、`pyright` 均通过。
- PostgreSQL P22 定向：`8 passed`（含四并发 revision、Archive roundtrip、错误密码/篡改、完整行 duplicate PK/orphan FK preflight、canonical fresh-seed replace、改动 seed/nonzero revision/其他正式表行写前拒绝、CLI stdin、既有文件预留前拒绝、export/write 失败清理 partial，以及解密 payload 验证 AI raw 默认排除/显式保留）。
- PostgreSQL credit-read repair：P4/P5/P20/P21/P22 组合 `43 passed`；新 API 契约直接验证 GET 前后 `credit_cycles` IDs 与 revision 不变、投影 deep-link 稳定，正式 credit purchase 只增加一次 revision 并物化相同 ID。P4 覆盖投影/物化 `created_at`/`updated_at` 一致与 UUID tie-breaker 分页同 PostgreSQL 顺序。
- Fresh PostgreSQL `fiscal_p22_credit_fresh`：`pytest --junitxml=/private/tmp/fiscal-p22-credit-read-fresh.xml`，JUnit `249 tests / 0 failures / 0 errors / 0 skipped`。
- Alembic disposable `fiscal_p22_migration`：`20260811_0022`→`20260811_0021`→head 成功；offline SQL 含 `data_revision` create/seed。
- Apple: `xcodegen generate`；`FiscalmacOS` 的 `FiscalKitTests` 为 `101 tests / 19 suites` 通过；`FiscaliOS` generic iOS Release build 成功；`FiscalmacOS` Release build 成功，产物经 `codesign --verify --deep --strict` 验证。

## 生产门与风险

- 精确 shadow source：`887ca22`；新验证的迁移前备份 `fiscal-20260811T111306Z.dump`，SHA-256 `deba8fb6ebdc879ff2235cc061fdedc8953b74a6e57e2bc2b72479215e245b8d`，checksum 与 `pg_restore --list` 通过。
- fresh A/B `20260811T111423Z`：A 由 0021 恢复后升至 0022，B 由 base 升至 0022；Archive export、dry-run（`relationship_errors=0`）与 apply 均通过。双方严格一致：`data_revision=0`、transactions/postings=`184/201`、posting signed/absolute totals=`-974676/18632242`、orphans=`0`、credit cycles=`23`，账本/报表/派生指纹一致。export、dry-run 及比较前后的全表计数、revision 与 credit-cycle ID 快照证明检查本身零写入。
- 比较证据脚本曾分别因 `/root` 读权限和 Decimal JSON 序列化退出；两次均在证据输出层，并由前后快照证明未改变 A/B。移入受控 workspace 并使用 `default=str` 后比较成功。
- 生产部署前的三轮有限探测均为 TCP/22 可达但 SSH banner 超时，未进入远程 shell；因此 deploy、0022 migration、QA mutation 和设备验收都未开始。SSH 恢复后必须先重做只读 current/head/service/counts re-anchor，再继续已授权步骤。
- 禁止对现库覆盖或 merge；生产门通过后才可安排 macOS 与 Kurisu 真机/签名 Release 验收。
