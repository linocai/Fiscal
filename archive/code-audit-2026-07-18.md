# Fiscal 独立代码审计（2026-07-18，v1.2.3 / Build 12）

> 审计人：Fable 5 主会话亲自执行（未进工作流、未派 agent）。
> 范围：v1.2.0（P16 修复发版）之后的全部变更——P17 信用账期/现金流/分期统一（含生产迁移 `20260718_0015`）、P18 报表/总览统一、AI 稳定性修复——前后端 diff 逐块细读；另复核 P16 发版时跳过 review 的高危修复现状。
> 基线：FiscalKitTests 83/83 通过（xcodebuild, FiscalmacOS scheme）；审计只读，未改任何产品代码（xcodebuild 触发的两个 xcscheme 格式降级已还原）。

## A. 确定 bug（建议修）

### A1【中】iOS 云连接刷新用错报表实例
[apple/Apps/iOS/IOSRootView.swift:248](../apple/Apps/iOS/IOSRootView.swift) `refreshCloudContent` 仍调 `reports.loadAll()`。P18 把报表拆成 overview / spending 两个 `ReportingModel` 实例后：
- **overview 实例完全没被刷新**——粘贴设备密钥连上云端后，总览 tab 要等用户切走再切回（.task 重跑）才恢复；
- `loadAll()` 在 spending 实例上同时跑 `loadOverview`+`loadSpending`，两个 load 并发竞写同一个 `phase`/`refreshMessage`——overview 请求的结果可能把消费报表屏的状态覆盖成错误的 empty/通知，还多打一个无用请求。
其余所有变更路径（TransactionsModel/InstallmentModel/ReimbursementModel/AIProposalModel）都已迁移到 `ReportingInvalidationCoordinator.refresh()`，只有这一处漏网。修法：改调 coordinator（或 `overview.loadOverview()` + `reports.loadSpending()`），顺手删除已无正当调用方的 `loadAll()`。

### A2【低】ReportingScreens 死代码，内含破坏性死按钮
[apple/Sources/FiscalKit/Features/ReportingScreens.swift:802-810](../apple/Sources/FiscalKit/Features/ReportingScreens.swift) `accountRows` 全仓无调用方。其按钮 `model.lens = .cashFlow` 会触发 lens didSet 清掉用户当前打开的下钻，随后 `loadDrillDown` 被 `guard lens == .spending` 拦截 no-op——若日后恢复引用即成「点了没反应还关我明细」的真 bug。`drillDownRows` 中所有 `lens == .cashFlow` 分支（818/834/846/849 行）因此不可达。P16 已清过一轮死代码（D1-D3），P18 重写又留下同类残留，建议删除。

### A3【低】`IOSReportsScreen.initialLens` 成摆设
[apple/Sources/FiscalKit/Features/ReportingScreens.swift:250-252](../apple/Sources/FiscalKit/Features/ReportingScreens.swift) `_ = initialLens`。`IOSMoreDestination.reports(lens)` 的 lens 参数全链路无效。当前调用方只传 `.spending` 无实害，属误导性接口残留；报表已单一化就把参数删掉。

## B. 结构性风险（确定存在，触发依赖使用方式）

### B1【中低】账户编辑器换账期是两段式非原子写
[apple/Sources/FiscalKit/Features/MasterDataModels.swift](../apple/Sources/FiscalKit/Features/MasterDataModels.swift) `applyScheduleChange`：先打 `schedule-change` 端点（服务器已生效、版本已 bump），再 `get` + `update` 补写 draft 其余字段。第二步失败时返回 false，UI 报「保存失败」——但账期变更其实已落库，同次编辑的名称/额度改动丢失；编辑器里还握着旧版本 account，重试会先撞版本冲突。低概率但发生时对用户极困惑。建议：第二步失败时给出「账期已生效，其余修改未保存」的明确提示，或后端把 draft 并进 schedule-change 一个事务。

### B2【低】「平账」排除按分类名字符串匹配
[backend/src/fiscal_api/services/reporting.py](../backend/src/fiscal_api/services/reporting.py) `EXCLUDED_CATEGORY_NAMES = {"平账"}`（含后代传播）。三个脆弱点：① 用户把该分类改名，排除静默失效，消费/现金流报表悄悄膨胀；② 任何恰好叫「平账」的普通分类连同后代被从所有报表和下钻里隐藏（drill_down 对其直接返回空页）；③ debt 口径不排除，信用账户上的平账流水会进负债。P18 QA 记录了该语义为验收契约，短期可接受；长期建议改为分类上的显式 `is_balancing` 标志 + 改名保护。

### B3【低】换账期对逾期账期的边界语义与报错可读性
[backend/src/fiscal_api/services/credit.py](../backend/src/fiscal_api/services/credit.py) `_change_schedule` 的 rebase 范围是「未结清账期」，**包含已出账、已逾期**的账期（P17 文档明确如此，属设计决定）：逾期债务的到期日会被重排，逾期状态可能消失，而预览只报数量不报到期日影响。另外还款整体跟随 replacement 账期、消费按业务日期散落，两者错位时由 `validate_credit_invariants` 兜底拒绝——数据安全，但用户看到的是 `credit_cycle_overpaid` 这类无法自解的报错。P17 测试未覆盖：逾期账期重排、invariant 冲突路径、replacement==自身、旧账期删除。建议补测试 + 预览响应带到期日变化摘要。

## C. 复核结论（无需行动）

- **P16 高危修复全部完好**：H4（changeKind 清引用 + validateReferences）、M5/M7（报销 valid 门控、元/分统一）、L6/L7（转账入账校验、还款账期守卫）、M14/M15（缓存 generation + 解码后入缓存）、L15（`+`→`%2B`，作用于 percentEncodedQuery，无误伤）。
- **P17 分期一体化入口扎实**：先预览后保存的请求相等性守卫（请求内嵌整个 purchase draft，任何字段变化都强制重预览）、幂等键复用（purchase 与 plan 同 key，replay 一致）、`resetForNextEntry` 轮换 key、失败按 `shouldRotateCreateKeyAfterFailure` 轮换。
- **P17 现金流合并条目前端处理正确**：多账期条目分流到 `CreditCashFlowGroupSheet` 逐期还款（part.cycleID + part.remainingMinor），单账期条目直进还款编辑器；credit_cycle 只读投影双端闭环（服务端 409 + 前端不渲染编辑入口双保险）。
- **P17 生产迁移过程可信**：备份→影子库演练→部署→对账（119 笔流水、投影负债与现金流一致）均有记录；迁移删除 credit_cycle 覆盖是有记录的产品决定。
- **后端新端点**（schedule-change ×2、installment-purchases ×2）都在 `require_device_token` 之下；普通账户 update 对已用账期的 schedule 字段有 `credit_schedule_in_use` 拦截，专用端点是唯一变更路径。
- **AI 修复**（GLM 按 hostname 关 thinking、快捷指令去 image 参数）小而干净。
- 其余小改（CashFlowModel activeGeneration、协调器迁移、CreditScreens 参数化入口）无问题。

## D. 工程收尾状态（非代码问题）

1. **main 落后 12 个 commit**：v1.2.1–v1.2.3 全部只在 `codex/v1.2.1-credit-cashflow` 分支上，生产后端也是从该分支部署的；main 还停在 v1.2.0。需要决定合回时机。
2. **tag 缺口**：仓库只有 v1.2.0、v1.2.1；当前已是 1.2.3 (Build 12)，v1.2.2/v1.2.3 未打 tag。
3. **P18 验收未闭环**：`docs/qa/p18/results.md` 状态「实体 iPhone 启动验收待完成」。
4. `/Applications` 积累 4 个备份包（build9/build10/build11/pre-overview-hotfix），可按保留策略清理旧的。

## 附：审计中排查过、确认无问题的点

迁移 `20260718_0015` 的约束闭环与 downgrade 守卫；`schedule_for_statement`/`credit_schedule` 两种模式的日期推导（含跨年）；分组现金流 id 稳定性（单账期沿用 `credit_cycle:{id}`）；overview `credit_due_events` 聚合排序；`_excluded_category_ids` 的后代传播终止条件；`CreditCycleProjectionSheet` 的加载/失败分支；`InstallmentModel.createPurchase` 后的四路刷新；AccountDraft 对非信用 kind 编码 `cycle_mode: null` 与 DB 约束的匹配。
