# P16 v1.2.0 前端全量审查修复验收

日期：2026-07-17
输入：`archive/frontend-audit-2026-07-17.md`（41 项：H1–H4 / M1–M15 / L1–L19 / D1–D3）
版本：`MARKETING_VERSION` 1.1.0 → 1.2.0，`CURRENT_PROJECT_VERSION` 9 → 10。

## 门禁结果

- `swift test`（FiscalKitTests，通过 `xcodebuild -scheme FiscalmacOS test`）：**78 passed / 0 failed**，14 个 Suite。
  - 说明：施工前发现一处 **既有** 基线失败 `FiscalKitP8Tests.proposalContract`——其 JSON 夹具缺少 P13 起新增的必填键 `AIProposalDTO.target`。这不是审查 41 项之一，但会使每批次「swift test 全绿」门禁失效，故修复了该夹具（仅测试文件、加 `"target":"transaction"`，零业务改动）。
- `xcodebuild` iOS App target（FiscaliOS，generic iOS Simulator）：Debug + Release **BUILD SUCCEEDED**。
- `xcodebuild` macOS App target（FiscalmacOS，platform=macOS）：Debug + **签名 Release**（Developer ID）**BUILD SUCCEEDED**，framework 与 .app 均完成 codesign。
- 新增 P16 单测：`P16InfrastructureTests`（M14/M15/L15/L17）、`P16HorizontalTests`（M12/L5）、`P16TransactionTests`（H4 changeKind + validateReferences）。

## 批次施工与提交

| 批次 | 覆盖项 | 提交 |
|---|---|---|
| B1 死代码 | D1 D2 D3 | `refactor(p16-b1)` |
| B2 基础设施 | M14 M15 L15 L16 L17 | `fix(p16-b2)` |
| B3 横向模式 | M12 L10 L13 · M6 M11 · H2 M4 L3 L4 L5 | `fix(p16-b3)` |
| B4 逐模块 | H4 M1 M2 M3 L7 L11 L12 L14 · H1 M5 M7 L9 · H3 M8 M9 · M10 M13 L1 L6 L8 · L2 L18 L19 | `fix(p16-b4)` |
| B5 收口 | 版本号 + 双端门禁 + 记录 | 本次 |

每批次收口 `swift test` 通过；含 View 改动的 B1/B3/B4 及 B5 收口均跑了 iOS + macOS App target 构建。

## 疑似项核实结论（先核实再修）

- **M13 编辑手动现金流丢备注 — 成立，已修。** 后端 `services/cash_flow.py:update` 经 `_apply_draft` 全量替换，`CashFlowReplace.note` 默认 `None`（`api/p13_schemas.py:CashFlowDraft`），客户端 `CashFlowEditorSheet` 无备注框且 `seed()` 不透传 `item.note` → 编辑一次即清空备注。补了备注框 + `seed()` 透传 + `save()` 回写。
- **L1 分期编辑器强解包 — 成立（理论崩溃），已加固。** `InstallmentPurchaseReplacement` 契约要求非空 UUID；信用消费业务上必有账户/分类，但改为守卫式解包（缺失时用确定性占位并在 `request()` 拦截保存），杜绝 nil 崩溃。
- **L2 OCR 行排序 — 成立，已修。** `abs(Δy) > 0.02` 容差比较不满足严格弱序，`sorted(by:)` 未定义（dense 小字可能错序/debug 断言）。改为按每行顶端锚点做确定性行聚类后行内左到右排序。
- **L7 新建还款超额校验被跳过 — 成立，已修。** `cyclesForRepayment(retaining:)` 只对编辑保留账期，新建预选账期（如已结清账期）可能落在 `cycleOptions` 外，使 `performSave` 的 `let cycle = cycleOptions.first{...}` 短路、整条 `if` 为假、超额校验被跳过。改为账期缺失时明确拦截保存。
- **L8 系统现金流编辑器静默改状态 — 成立，已修。** 后端 `update_system` 写入 `override.status = request.status.value`（`services/cash_flow.py`），而编辑器强制 `item.status == .completed ? .completed : .confirmed`，会把 `.expected` 项静默升为 `.confirmed`。改为 `markCompleted` 布尔 + 未完成时保留原状态。
- **L9 已取消报销单仍可编辑/作废回款 — 不成立，不修。** 后端 `services/reimbursements.py`：`receipt_lifecycle`（第 655、661–670 行）显式允许在 **已取消（未归档）** 报销单上「作废回款」，只拦截「恢复回款」（第 674 行）与矩阵编辑（第 265–277 行「presentation fields remain correctable」）。客户端菜单已精确对齐：作废回款可用、已取消时隐藏恢复回款、`matrixFrozen = editing?.cancelledAt != nil`。行为与状态机一致，非缺陷。
- **L14 分页 isLoadingMore 竞态窗口 — 成立，已修（未降观察项）。** 确认被取消旧请求的 `defer { isLoadingMore = false }` 会清掉新请求置的 `true`。虽有去重/generation 兜底不致数据错乱，但改为请求归属 token：只有当前拥有分页槽的请求才清 flag，成本极低、彻底消窗。
- **L17 `TransactionDTO` decode(Optional) — 成立（稳健性），已改。** 后端 `p3_schemas.TransactionResponse` 中相关键当前恒序列化（required-nullable 或带默认值仍输出），故 `decodeIfPresent` 是零行为变更的加固；不同于报销 `requiredNullableKeys` 那种「键消失应报错」的刻意契约，交易侧无对应测试要求。
- **L19 负债页 `DebtReport.cycles` 全量无 UI 使用 — 核实清楚。** 后端 `services/reporting.py:200-208` 确实向 `DebtReport.cycles` 填入全部账期，但客户端 UI 仅按账户展示各自 `next_due_cycle`（`DebtAccountRow.cycles` 计算属性 ≤1 元素）。故 `account.cycles.filter{...}.prefix(4)` 是空操作，已删 `prefix(4)`；报表级 `DebtReport.cycles` 保留解码（无害，为将来下钻留口），本期不补 UI（属功能扩展，非缺陷）。

## 裁决项决策（按 plan 默认执行，供用户翻案）

- **D3 总览 fixture 预览集 — 删（默认执行）。** 已核实 live 首页由 `IOSReportingOverviewScreen` / `MacReportingOverviewScreen` 渲染真实数据；删除 `IOSOverviewScreen` / `MacOverviewScreen` / `PreviewSupport/OverviewFixtures` 及仅其引用的 `SpendCard`/`CategoryBar`/`AccountRow`/`ActivityRow`，并顺带删除随之无消费者的预览域类型 `OverviewSnapshot`/`CategorySpend`/`AccountSummary`/`RecentActivity`/`FinancialDirection`（保留核心 `Money`）。**保留** 被真实总览复用的 `EmptyInline` 与 public `ConnectionBadge`。连带删除两条仅测这些夹具的 P1 测试（`derivesCashNet`、`presentationStates`）。若用户想保留为「离线预览」脚手架，可从 git 历史恢复。
- **L14 是否降观察项 — 顺手修（未降级）。** 见上，token 修复成本低且彻底。
- **L19 现金流日期钉死 Asia/Shanghai — 记录不修（默认）。** `CashFlowModel` 日期用 Asia/Shanghai 与 DatePicker 本地时区在东八区内无实害；仅当日后统一全局时区策略时一并处理。

## 高危区（金额/记账写入路径）验证

H4 / M5 / M7 / L6 / L7 均为金额或记账写入路径。已完成：

- **静态与单测：** H4 `changeKind` 引用清理与 `validateReferences` 方向/账户类型校验有针对性单测（`P16TransactionTests`）；M7 元/分统一复用经既有 P6 测试覆盖的 `ReimbursementClaimEditor.validatedAmount`/`yuanText`（`600.01`↔`60001`）；金额解析边界（`CNYAmountParser`）既有 P2 测试覆盖。
- **契约核实：** L6 转账入账补齐与编辑器 `EditorSheet:451` 同款「非空且不同账户」校验；L7 超额校验不再被账期缺失短路；M5「确认保存」加 `!valid` 且非法金额文本使预览失效，与 mac `macActionBar` 对齐。

> 待用户完成：H4 手动切换各类型组合确认 Picker 无残留错误引用、写入方向正确；M5/M7 回款与报销单同一金额单位无 100 倍偏差；L6 现金流转账入账缺/同账户被拦；L7 新建还款超额被拦——即 plan 要求的「手动走一遍真实 posting/回款/还款/入账路径」。本会话为非交互环境，未做真机/模拟器交互与截图，沿用既有 phase 惯例交用户最终目视/真机验收后再 tag。

## 遗留 / 交用户验收

- 双端 run + 主流程 + 各修复点截图巡检、以及高危金额路径的真实写入手动核对，留用户在真机/模拟器完成（与 P12–P15「用户最终目视/真机验收后 tag」一致）。
- v1.2.0 tag 待用户验收后打。
