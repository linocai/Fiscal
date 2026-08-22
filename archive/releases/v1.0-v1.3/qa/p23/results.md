# P23 · AI 质量闭环

状态：**Automated / Production / Physical Device Verified**；最终 manifest committed HEAD 已 same-head 部署，待重锚、tag/push。

## 本地自动门

- `20260811_0023` 为 additive migration：原始输入/首次 parse snapshot/最终确认与 diff、不可变质量事件、策略历史、确定性规则和脱敏 shadow-evaluation gate。旧提案不回填，API 为 `historical_unavailable`。
- fresh PostgreSQL 14：全量 `pytest -q` 收集并通过 `251 tests`；P8/P23 定向 `34 passed`；fresh、`0023 → 0022 → head` 与 offline SQL 通过，disposable 库均已删除。Ruff 与 Pyright 通过。
- macOS `FiscalKitTests` 为 `101 tests / 19 suites`；独立 DerivedData 的 iOS/macOS Release 都通过 `codesign --verify --deep --strict`，macOS 为 Developer ID `HX73DFL88G`。
- 生产 Unix-socket migration URL 的 `%2F` ConfigParser 边界转义修复及真实 URL 回归分别提交为 `8173e03`、`be664f8`；不解码或改变 asyncpg principal/数据库。

## 生产、影子与恢复

- 只读重锚为 `5330b42 / 20260811_0022 / revision 2 / transactions-postings-orphans 184/201/0`、服务 active；已验证生产前备份。候选源码由 `git bundle ... HEAD` 导入，未使用裸 SHA bundle。
- 失败影子不复用：采用 P22 的受控恢复模式（`postgres pg_restore --file=- --no-owner --no-privileges | fiscal_migrator psql --single-transaction`），以 `fiscal_migrator` 同一 principal 预检 owner/read/CREATE。全新影子升级至 0023 后，revision、transactions、postings、accounts、credit cycles、reconciliation 和全部 50 条原 AI 提案的 count/hash 均未漂移。
- 旧 50 条 proposal 的 initial/final snapshot 都为 NULL；policy 默认为关闭、无 policy 行。影子中无网络 synthetic provider 经正式 `AIService` 完成 `parsed → ignored`，指标为 total/historical/parsed/ignored/terminal=`51/50/1/1/51/0`，没有 AI 财务流水；DELETE quality event 被 immutable trigger 拒绝。影子已删除；真实候选 Provider shadow 本期明确跳过。
- 精确 `be664f84c67d36bcddd3cf1f1430879fbac7fc68` 已部署为 `20260811_0023`；service active/readiness 通过，生产 revision=`2`、transactions/postings/orphans=`184/201/0`、accounts/cycles/reconciliation=`7/23/0`、AI proposals=`50/50 historical`、automation=false/policies=0。质量与提案不可变 trigger 均存在。
- post-deploy verified dump `fiscal-20260811T132006Z.dump` 于 `2026-08-11T13:21:03Z` 隔离恢复成功。生产 quality event 是 append-only，未作不可清理 QA 写；以 Keychain stdin 管道的只读 authenticated GET 确认 `/data-revision`、AI settings、quality metrics、strategy、learning rules、legacy proposals 均为 HTTP 200。

## 设备与发布边界

- Kurisu 安装并启动了独立 iOS Release，macOS 独立 Developer ID Release 通过签名校验、安装并启动；两者为 `1.3.0 (21)`。macOS 旧包可恢复地保留为 `/Applications/Fiscal-pre-p23-backup.app`。
- 不制造正式财务流水，不调用外部 Provider，不伪造生产 AI 样例。真实 Provider / 新模型或提示词替换仍须另行授权脱敏 corpus。
- 用户已取消七天观察；最终 manifest HEAD 已 same-head deploy，重锚、clean 与 tag/push 后，P23 即标记为 Released。异地备份 provider 与真实告警接收器仍是 carried risk。
