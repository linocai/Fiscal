# P23 · AI 质量闭环

状态：**本地 Automated Verified**；backend、fresh PostgreSQL、迁移往返、双端测试/签名 Release 均通过。未部署、未迁移生产、未调用真实 AI Provider、未进行真机验收。

## 已验证的本地契约

- `20260811_0023` 为 additive migration：初始 parse / 最终确认 / 字段 diff，质量事件、策略历史、确定性学习规则；旧提案不回填，响应为 `historical_unavailable`。
- PostgreSQL trigger 拒绝修改/删除 `ai_quality_events`，并拒绝改写已有提案的 `raw_input` 或首次 parse snapshot。
- 新模型/提示词候选只能登记脱敏 shadow corpus 的 SHA-256、样本数、全通过聚合结果与 evaluator version；不存语料原文、不会触发 Provider。缺少该记录的 candidate replacement 返回 `ai_shadow_evaluation_required`。
- `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p23_fresh` 的 P8/P23 定向回归：`34 passed`。覆盖原始快照、人工修改 diff、事件顺序、两次稳定证据后才出现 merchant/category、title/account、source-context alias 规则，以及指标 `total = pending + terminal_outcomes`。
- disposable `fiscal_p23_fresh`：fresh upgrade 到 `20260811_0023`、`0023 → 0022 → head`、offline SQL 均成功；SQL 含三张新表与两条不可变 trigger。
- fresh `fiscal_p23_full` PostgreSQL 14：全量 `pytest -q` 通过（收集 `251 tests`）；最终 `fiscal_p23_final` 也在 shadow gate 提交后的 HEAD 重跑全量通过。两库都已显式删除；不保留测试库。
- fresh `fiscal_p23_shadow`：shadow gate 定向 API/P8 回归 `15 passed`，`0023 → 0022 → head` 成功后已删除。
- Backend static：`ruff check src/fiscal_api …` 与 `pyright` 均通过。
- Apple：`xcodegen generate`；`FiscalmacOS` `101 tests / 19 suites`（含 P23 指标分母与 explicit-confirmation payload）通过。独立 DerivedData 下 iOS generic Release 与 macOS Release 都完成；`codesign --verify --deep --strict` 双端通过，macOS 为 Developer ID `HX73DFL88G`。首次 shared DerivedData 重跑的 lock 未改变源码或产物，已改为串行独立路径验证。

## 下一步与边界

- 本地门已结束；下一步是受控生产前备份、0022→0023 影子迁移/数据指纹、精确 commit 部署、生产冒烟和 Mac/Kurisu 真机验收，需用户明确授权。
- 任何真实候选模型/提示词替换还需单独允许向当前 Provider 发送脱敏 shadow corpus；只登记 corpus SHA-256、样本数、聚合结果和 evaluator version，不保存语料或凭据。如本次不替换模型/提示词，可不执行该外部调用，但不得声称候选已验证。
- 不制造财务流水作为 QA。真机 AI 链路仅允许创建可清理提案/质量事件；若需确认成正式流水或执行 undo，必须再有明确用户数据输入。
