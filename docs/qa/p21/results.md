# P21 核对点与 Attention — QA 记录

实施提交：`5c77992`（领域/API/migration 契约）、`ea95a62`（Attention 派生、双端界面、深链与 QA）。

## 范围与不变量

- 核对点是按 `as_of`（UTC instant，业务日期按 `Asia/Shanghai`）重算的派生读模型；金额均为 minor units。
- 创建核对点不会写入 ledger、posting 或账户余额；只有差额为零时状态为 `reconciled`。后补/编辑正式流水会重新计算并可使旧核对点变为 `open`。
- 正式余额调整继续使用既有明确的 `is_balance_adjustment` 分类，并从消费报告隔离；P21 未写入或回填任何历史数据。
- Attention 由现有来源实时派生，忽略仅写入有到期时间的独立 dismissal，不复制各来源状态机。

## 自动验证（2026-08-11）

- `uv run ruff format --check .`、`uv run ruff check .`、`uv run pyright`：通过。
- PostgreSQL P21 API/模式测试：`2 passed`；覆盖核对点创建、按时点重算、后补流水导致重开、无 ledger 写入及 Attention 的到期忽略。fresh PostgreSQL 全量 suite 通过；默认 suite 为 `142 passed, 97 skipped`。
- Alembic：在 disposable PostgreSQL 上 `base -> head -> 20260811_0020 -> head` 通过；离线 SQL 含 P21 两张新增表。没有尝试 P20 的不可逆降级。
- macOS `FiscalKitTests`：`89 tests in 18 suites passed`，包含 P21 DTO/深链契约。
- macOS Release：通过，Developer ID 签名为 `Developer ID Application: ZheYuan Cai (HX73DFL88G)`，universal（arm64/x86_64）。
- iOS Release（generic iPhoneOS）：通过，已签名。

## 仍需人工/发布门

- 未执行生产迁移、部署或写入任何真实余额。生产迁移前必须获取并验证备份，先在影子/隔离库演练 0021，再执行迁移与回归。
- 实体验收仍需 Mac 与 Kurisu：连接生产、输入真实对账余额、核验零差额与非零差额、Attention 深链/忽略到期，以及信用账期历史。真实余额不写入此记录。
- P20 既有离机备份与告警演练风险仍独立存在，未由 P21 改动。
