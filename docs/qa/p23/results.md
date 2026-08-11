# P23 · AI 质量闭环

状态：**本地 Automated Verified（backend A/B）**；未部署、未迁移生产、未调用真实 AI Provider、未进行真机验收。

## 已验证的本地契约

- `20260811_0023` 为 additive migration：初始 parse / 最终确认 / 字段 diff，质量事件、策略历史、确定性学习规则；旧提案不回填，响应为 `historical_unavailable`。
- PostgreSQL trigger 拒绝修改/删除 `ai_quality_events`，并拒绝改写已有提案的 `raw_input` 或首次 parse snapshot。
- `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p23_fresh` 的 P8/P23 定向回归：`34 passed`。覆盖原始快照、人工修改 diff、事件顺序、两次稳定证据后才出现 merchant/category、title/account、source-context alias 规则，以及指标 `total = pending + terminal_outcomes`。
- disposable `fiscal_p23_fresh`：fresh upgrade 到 `20260811_0023`、`0023 → 0022 → head`、offline SQL 均成功；SQL 含三张新表与两条不可变 trigger。
- fresh `fiscal_p23_full` PostgreSQL 14：全量 `pytest -q` 通过（收集 `251 tests`），随后已显式删除；不保留测试库。
- Backend static：`ruff check src/fiscal_api …` 与 `pyright` 均通过。
- Apple：`xcodegen generate`；`FiscalmacOS` `101 tests / 19 suites`（含 P23 指标分母与 explicit-confirmation payload）通过。独立 DerivedData 下 iOS generic Release 与 macOS Release 都完成；`codesign --verify --deep --strict` 双端通过，macOS 为 Developer ID `HX73DFL88G`。首次 shared DerivedData 重跑的 lock 未改变源码或产物，已改为串行独立路径验证。

## 下一步与边界

- 待完成 Apple 单测、iOS/macOS Release build、完整 fresh PostgreSQL suite，之后才更新本记录状态。
- 本期只允许本地 disposable PostgreSQL；生产 backup/shadow/deploy、真实 provider 写入、生产 migration 与 Mac/Kurisu 门均需后续明确授权。
