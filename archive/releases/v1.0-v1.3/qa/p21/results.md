# P21 核对点与 Attention — QA 记录

实施提交：`5c77992`（领域/API/migration 契约）、`ea95a62`（Attention 派生、双端界面、深链与 QA）、`97d2ccd`（失败迁移运行的运维异常 Attention）、`4686e44`（冷启动直达核对页时加载账户）。

## 范围与不变量

- 核对点是按 `as_of`（UTC instant，业务日期按 `Asia/Shanghai`）重算的派生读模型；金额均为 minor units。
- 创建核对点不会写入 ledger、posting 或账户余额；只有差额为零时状态为 `reconciled`。后补/编辑正式流水会重新计算并可使旧核对点变为 `open`。
- 正式余额调整继续使用既有明确的 `is_balance_adjustment` 分类，并从消费报告隔离；P21 未写入或回填任何历史数据。
- Attention 由现有来源实时派生（核对差额/首次核对、待分类、AI、现金流、报销、信用账期及失败迁移运行），忽略仅写入有到期时间的独立 dismissal，不复制各来源状态机。

## 自动验证（2026-08-11）

- `uv run ruff format --check .`、`uv run ruff check .`、`uv run pyright`：通过。
- PostgreSQL P21 API/模式测试：`2 passed`；覆盖核对点创建、按时点重算、后补流水导致重开、无 ledger 写入及 Attention 的到期忽略。fresh PostgreSQL 全量 suite 通过；默认 suite 为 `142 passed, 97 skipped`。
- Alembic：在 disposable PostgreSQL 上 `base -> head -> 20260811_0020 -> head` 通过；离线 SQL 含 P21 两张新增表。没有尝试 P20 的不可逆降级。
- macOS `FiscalKitTests`：`89 tests in 18 suites passed`，包含 P21 DTO/深链契约。
- macOS Release：通过，Developer ID 签名为 `Developer ID Application: ZheYuan Cai (HX73DFL88G)`，universal（arm64/x86_64）。
- iOS Release（generic iPhoneOS）：通过，已签名。

## 生产与实体设备验证（2026-08-11）

- 生产迁移先创建并校验 custom-format backup：`fiscal-20260811T092359Z.dump`（checksum 与 `pg_restore --list` 均通过）。生产快照在新的隔离 shadow 库由 `20260811_0020` 升至 `20260811_0021`；交易、posting、账户余额指纹与报告 fingerprint 均未改变。服务契约仅创建随后清理的临时零差额 checkpoint，交易/posting 计数不变。
- 首次生产部署来自精确提交 `97d2ccd893b1d4445167ead28c7a1d0ee3536358`；迁移后再发布客户端冷启动修复 `4686e4492482a060fd9080eed16b74bbfccebd69`。当前 release 为 `/opt/fiscal/releases/4686e4492482`，Alembic head 为 `20260811_0021`。
- 第二次发布的 verified post-migration backup 为 `fiscal-20260811T093839Z.dump`（299,698 bytes）。API service active，loopback ready 与 public live 均为 200；受保护 API 的未认证 smoke 为 401。生产守恒查询：transactions `184`、postings `201`、孤儿 posting `0`、checkpoint `0`、dismissal `0`。
- macOS 与实体 iPhone **Kurisu** 均安装同一已签名 `1.3.0 (21)` Release。冷启动 `fiscal://reconciliation` 后，两端均以生产凭证取得 `200`：`accounts`、`reconciliation/checkpoints`、`reconciliation/diagnosis`、`reconciliation/attention`。macOS 实际界面显示“快速核对”；Kurisu 经 `devicectl` 安装并启动。
- 生产未输入真实余额，也未创建 checkpoint、dismissal、ledger、posting 或余额调整。这不是测试数据缺失的替代品：用户需要在核对时自行给出真实时点余额；该写入验收保留为 P21 的用户数据动作。

## 仍需人工/发布门

- 真实账户余额输入后的零差额/非零差额 checkpoint、Attention 忽略到期与信用账期历史，需要用户选择账户及给出真实余额后验收；不得由工程人员代填。
- P20 既有离机备份与告警演练风险仍独立存在，未由 P21 改动。

## 2026-08-12 回归复核

- `test_p21_checkpoint_is_derived_and_attention_is_dismissible` 的数据固定在 2026-08；测试现仅将 `fiscal_api.services.reconciliation.utc_now` 固定为 `2026-08-11T12:00:00Z`，使其固定的次日 expiry 表达原有的有效忽略契约。生产端的过期校验未改，仍拒绝 `expires_at <= utc_now()`。
- 新鲜 PostgreSQL：P21 API/schema 定向测试 **2 passed**；完整后端 suite **256 passed**。每次验证库均在命令结束后删除。
