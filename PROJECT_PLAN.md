# Fiscal · PROJECT_PLAN

> 控制面版本：v1.5.0 ｜ 更新：2026-08-22（Asia/Shanghai）｜ 状态：**v1.5.0 (24) 源码收口完成，停止在发布包生成之前。P30–P34、F0–F4 与 F5-A 的既有实现/审查证据保留；正式 iOS/macOS root 已切至 V15，旧视觉层已删除，最终离线回退源码已收敛。按用户指令不再启动长验证或追加审查；release package、签名、公证、tag/push 与生产部署均未执行。**

## 1. 目标、边界与现状

- **v1.5.0 目标**：以 clean-room 方式完整替换 iOS 与 macOS 原生 SwiftUI 表现层，交付“过去 / 现在 / 已知未来”的一致事实体验；macOS 为账簿脊柱，iOS 为决策台。视觉、文案、状态语法和可访问性以 `Fiscal 前端设计启动/` 为基线；字段、金额、状态、动作、错误和接口以后端与本计划为准。
- 交付包括 P30–P34 服务端契约、全业务的 v1.5 原生入口、商户/历史、当前快照、时间轴、月报/年报/导出及旧 View 一次性切换。P35 Widget/Spotlight 可顺延 v1.5.x（D10）。
- 不做预算、建议、评分、预测、多币种、多人、银行连接器、通用附件、AI 财务聊天或离线写入队列；不引入 React、Tailwind、shadcn 或 Web UI。
- v1.4.0 已发布；其旧 View 不是视觉或交互模板。当前工作区已有用户的暂存目录迁移，施工不得重置、覆盖、混入或重新整理该批改动。

## 2. 权威与不可变规则

| 优先级 | 来源与执行规则 |
| --- | --- |
| 1 | 本计划、用户已批准 D1–D10、`AGENTS.md`；冲突时停止并更新本计划，不自行发明产品行为。 |
| 2 | v1.5 后端 schema/service；未改造能力沿用当前 Backend。客户端不自算会计真相、状态跃迁、去重或报表。 |
| 3 | `archive/plans/v1.4-v1.5-backlog.md#4-v15--事实展现升级`；本计划将其 P30–P34 收敛为可施工门。 |
| 4 | `Fiscal 前端设计启动/`：颜色、排版、组件、平台布局、交互意图和视觉验收；原型中与契约冲突的字段/行为一律替换。 |
| 5 | `archive/audits/frontend-v1.5-design-backend-conflicts-2026-08-14.md`：缺口、风险和批准决定的依据；本计划是唯一当前控制面。 |

- 金额始终为 CNY `Int64` minor units；输入只经 `CNYAmountParser` 一次转为分，最多两位小数，禁止浮点。业务日、筛选边界、用户可见导出日期均为 `Asia/Shanghai`，API 时间戳为 UTC。
- R1 preview 不等于 commit：预览必须显示服务端真实影响和版本；任一输入（包括非法文本）变更立即作废预览并禁止提交。R2 冲突接管整个决策面，重新 GET/预览后才可决定。R3 提议、导入、预览、预计事项三重标识为未定。R4 archive 不等于 delete。R5 部分完成必须说明完成、当前状态和剩余项。
- 所有异步 load/preview 用 generation 守卫；取消分支同样不得覆盖新状态。所有 iOS sheet 内显示错误；所有禁用控件保留可见原因。加载、空、离线陈旧、校验错、服务错、冲突、归档只读、危险预览、成功凭证、部分完成分别建模和验收。

## 3. 已冻结的产品与技术决定

1. D1：严格 `P30-A→P30-B→P30-C→P31→P32→P33→P34`，逐门验证与 QA 落盘后才可 F0；不做 v1.4 换皮。D2：加密只读离线快照，离线写入禁用且解释。
2. D3：AI 自动执行退役，迁移置关闭，读取为 false，旧启用写入返回 `ai_auto_execute_retired`；提议永远人工确认。
3. D4：常规 UI 只归档/恢复；D5：派生报销现金流金额跟随事实，只能改有限显示字段。
4. D6：补 transaction revision/provenance 只读；D7：分类合并/拆分先有服务端 preview、映射和原子提交。
5. D8：分类直接原子保存 + 凭证，失败即全部未修改；D9：本地 PDF 离开/后台/取消即停止并清理。
6. macOS 为脊柱+检查器，iOS 为今日决策台+账目库；共享状态令牌、各自原生布局。账户默认仅昵称，重名时才最小化显示 `last_four`。
7. 无客户端 stale 阈值，只有离线快照时间；冲突返回当前版本、可安全刷新资源/差异和稳定原因码，否则要求重新决定。

## 4. 目录、模块与切换策略

- **只可复用的非视觉边界**：`APITransport`、`AccessKeyStore`、加密 `OfflineSnapshotStore`、`DataRevisionStore`、认证与其传输实现；V15 只经自己的 typed adapter 使用它们。View 禁止直连旧 `Data/`、DTO、`Features/*`、root、`FiscalDesign` 或旧状态/导航；仅可用中立金额、`CNYAmountParser`、Shanghai 日期和 V15 adapter。
- **新代码唯一落点**：`App/Sources/FiscalKit/V15/`：`Foundation/`=DI、契约、并发/field/capability/preview/conflict/receipt/offline；`DesignSystem/`=令牌和控件；`Shared/`=状态表面、fixture/gallery；`Features/<domain>/{iOS,macOS}`=页面/VM；`AppShell/`=并行预览路由。`App/Apps/*/V15*Shell.swift` 只承载并行注入。
- 每阶段以 `rg` 证明无旧视觉/模型/root import 或复制 View body；设计 HTML 只作视觉证据，绝不嵌入/WebView/翻译。F0–F4 仅由 fixture/gallery/测试启动且不改 root；F5 才原子接根并删除旧层。源清单变更先 `cd App && xcodegen generate`；只还原 scheme 噪声，绝不触碰用户目录迁移。
- 改动 `App/project.yml` 或源文件清单后执行 `cd App && xcodegen generate`；只还原生成的 scheme 噪声，绝不还原用户的目录迁移。

## 5. P30–P34 后端契约门（先行施工）

| Phase | 已验证契约与证据 |
| --- | --- |
| P30-A/B/C | **Independent Review Verified，终审 0 findings**：facts/future、capability/409/receipt/revision、报销 candidates/reasons；证据 `archive/releases/v1.5.0/qa/p30/p30-{a,b,c}-results.md`。 |
| P31 | **Independent Review Verified**：merchant、交易 history/provenance、分类 transform preview→commit、Archive；`archive/releases/v1.5.0/qa/p31/results.md`。 |
| P32 | **Independent Review Verified**：唯一首页 `reports/facts` 与 revision-bound 四 scope；`archive/releases/v1.5.0/qa/p32/results.md`。 |
| P33 | **Independent Review Verified**：future、信用、报销、分期与 Provider，无双算/幽灵；`archive/releases/v1.5.0/qa/p33/results.md`。 |
| P34 | **Independent Review Verified**：月年报、同 revision 下钻、报告 PDF/CSV；`archive/releases/v1.5.0/qa/p34/results.md`。 |

新增响应只追加；mutation 依其端点使用 UUID `Idempotency-Key`、`expected_version`、稳定错误和 P22 receipt/scope。certainty 固定 `exact_due / confirmed / expected / scheduled`；内部转账不改总现金，`after_confirmed_outflow` 不扣 expected/scheduled/预计回款。

## 6. 审计缺口可追溯性

- B01–B04、B07–B08 和 C01–C17 已分别由 P30–P34 收口：F1 不伪造检查器、预览、报告、离线写入、排序并发或 capability；报销灰按钮与所有未来/preview 流程仍只在 F3 实作并回归。

## 7. Clean-room Apple 施工阶段与依赖

**通用顺序**：每个阶段均为 Builder → Independent Review → Builder 修复/复测 → Review；只有终审 **0 findings** 才能解锁下一阶段。每轮 QA 写入 `archive/releases/v1.5.0/qa/frontend/f{n}-results.md`，含 commit-free changed paths、fixture、命令、截图、已知限制和 `rg` clean-room 结果。F0–F4 不删、不改接旧 root；F5 前不得并行启动后续 Feature Builder。

| Block | 依赖、独占所有权与施工切片 | 退出门（含两端差异） |
| --- | --- | --- |
| **F0-A/B/C（Independent Review Verified）** | `Foundation` typed P30–P34 boundary、令牌/十态控件、11-fixture Gallery 与并行壳均终审 0；证据 `archive/releases/v1.5.0/qa/frontend/f0-results.md`。 | 158 FiscalKit tests、Gallery UI、75 PNG、双端/Gallery build 与 clean-room 通过；真实设备 VoiceOver 是发布门。 |
| **F1 contract audit（Independent Review Verified）** | 已有 typed transport/offline/CNY、session/master-data/ledger/merchant 与 Gallery 边界；Feature 不得直连旧 repository/DTO/root。 | F2 仅可补本阶段 typed **read**，不改 DI、写入或 F1 Feature。 |
| **F1-A 启动、连接与事实录入（Independent Review Verified）** | auth/system、主数据/账期只读与五类交易录入；Shanghai/CNY、field issue、幂等与离线禁写均收口。 | 三审 0；详 `qa/frontend/f1-results.md`。 |
| **F1-B 账目库与交易检查器（Independent Review Verified）** | typed 账目 keyset/detail/history/provenance；iOS 搜索库、macOS 过去脊柱+检查器；能力按服务器、未知读回、409 重读。 | 三审 0；详 F1 QA。 |
| **F1-C 主数据与商户（Independent Review Verified）** | typed 主数据/商户、归档/排序/transform/mapping；无 DELETE/伪 archive，重名才最小 `last_four`。 | 七审 0；详 F1 QA。 |
| **F2 现在与决策面（Independent implementation review verified；历史 macOS runtime 曾 deferred，F5-A 已关闭）** | 唯一首页为 revision-bound facts/四 scope；详 §7.1 与 `qa/frontend/f2-results.md`。 | `F2C-MAC-UI-AUTOMATION` 历史上曾 deferred；F5-A Builder 的十个 exact macOS gate 已 23/0 全部 closed，并经 reviewer independent full mac Gallery 27/0 确认，不再是 publish blocker。 |
| **F3 已知未来与高风险领域（F3-A/B1/B2/C/D/E/F/G Independent implementation review verified；历史 macOS runtime 曾 deferred，F5-A 已关闭）** | **独占** `Features/{Timeline,CashFlow,Credit,Installments,Reimbursements,Reconciliation,AI,StatementImport}/**`；各块先扩 `Foundation` typed adapter，再做 Feature。详 §7.2。 | 严格 `A→B1→B2→C→D→E→F→G` 已终审；历史 deferred F3 macOS gates 已在 F5-A exact 23/0 闭环并由 reviewer full 27/0 独立确认，不再是 publish blocker。 |
| **F4 分析、报告与数据安全（Independent Review Verified；历史 F4C macOS runtime 曾 deferred，F5-A 已关闭）** | F1+P31/P34；F4-A typed Reports seam、F4-B Backend revision-binding 与 Apple export UI、F4-C encrypted Archive 均已终审。详细契约与证据见 [F4 执行记录](archive/plans/v1.5.0-f4-execution.md) 和 [`f4-results.md`](archive/releases/v1.5.0/qa/frontend/f4-results.md)。严格 `F4-A→F4-B→F4-C`。 | `F4C-MAC-UI-AUTOMATION` 历史上与既有九 gate 同为 deferred；十 gate 已由 F5-A Builder exact 23/0 全部 closed，reviewer independent full mac 27/0，均不再是 publish blocker。正式 root 与发布动作仍锁定。 |
| **F5 唯一切换与源码收口（pre-package stop）** | 两正式 root 已原子切至 V15；旧视觉/UI test 层已删除；生产 Today 离线状态改为动态读取共享 revision/offline boundary；QA RootSmoke 的最终错误/离线路径不再伪造离线标记，而是先建立真实只读缓存再断网回退。版本已升为 `1.5.0 (24)`，源码整理为可提交状态。 | 按用户指令停止在 release package 之前：不再追加长验证/审查，不 archive/export，不签名、公证、tag/push 或部署。既有 VoiceOver/实体设备事项仍属后续人工发布门。 |

### 7.1 F2 已验收索引

F2-A typed facts、F2-B iOS Today 均 Independent Review Verified；F2-C 三栏 macOS 已获 implementation/test-design 终审 0。真实 macOS UI automation 曾三次 0/0（`testmanagerd` enabling automation timeout）而延期；该历史 gate 已由 F5-A Builder exact runtime 23/0 闭环，reviewer independent full mac Gallery 27/0 确认，不再是 publish blocker。固定事实契约、所有审查链、12 张 F2-C 图、恢复精确命令与禁止范围均在 `archive/releases/v1.5.0/qa/frontend/f2-results.md`；F3 不得改 F2。

### 7.2 F3 串行施工计划（规划冻结）

详细契约、body/token/key/receipt/readback、fixture 和截图矩阵见 [F3 执行记录](archive/plans/v1.5.0-f3-execution.md)。其结论是：先扩 schema-shaped `Foundation` adapter，Feature 不得 raw transport/旧层/root；预览输入、dismiss/cancel、expiry、409、unknown、分页/刷新和离线一律可见且有 generation 防护；有 `available_actions` 才按其 reason 禁用，无此字段不伪造 capability。

| 块 | 独占与解锁条件 |
| --- | --- |
| **F3-A（Independent implementation review verified；历史 `F3A-MAC-UI-AUTOMATION` 曾 deferred，F5-A 已 closed）** | `Features/Timeline/**`：仅 `future-events` 7/30/60/90、account、opaque cursor、revision 409 和安全只读 locator；不自算、不写。证据见 `qa/frontend/f3-results.md`；历史 deferred macOS runtime 已在 F5-A exact 23/0 闭环，并由 reviewer full 27/0 确认。 |
| **F3-B1（Independent implementation review verified；历史 `F3B1-MAC-UI-AUTOMATION` 曾 deferred，F5-A 已 closed） / F3-B2（Independent implementation review verified；历史 `F3B2-MAC-UI-AUTOMATION` 曾 deferred，F5-A 已 closed）** | `Credit/**` schedule preview/token/commit 与 `Installments/**` 五态、unknown display-only、purchase/plan/settlement/reverse/cancel lifecycle 均已终审；F3-B2 四轮审查链以第四审 0 findings 收口；两 gate 均不再是 publish blocker。 |
| **F3-C（Independent implementation review verified；历史 `F3C-MAC-UI-AUTOMATION` 曾 deferred，F5-A 已 closed）** | `Reimbursements/**`：审查链 `2×P1+2×P2 → 2×P2 → 1×P2 → 0 findings` 已终审；最终真实 iOS **12/0**、双端 Release/Gallery、15 张 macOS 图与 clean-room 证据保留。F5-A exact 23/0 与 reviewer full 27/0 已关闭其 macOS runtime，不再是 publish blocker。 |
| **F3-D/E/F/G（Independent implementation review verified；历史 macOS runtime 曾 deferred，F5-A 已 closed）** | F3-G 七轮链 `4×P1+1×P2 → 1×P2 → 2×P2 → 1×P1+1×P3 → 1×P1+1×P2 → 1×P1 → 0 findings` 已终审；model 19/0、固定 UDID iOS 8/0、macOS UI BFT、四 Release、SnapshotTool/16 图证据已保留。历史 `F3G-MAC-UI-AUTOMATION` 与其余 F3 gate 已在 F5-A exact 23/0 闭环并由 reviewer independent full mac 27/0 确认，不再是 publish blocker。 |

每块 Builder→独立审查→修复/复测→终审 0 才能解锁下一块；完成后才可追加 `archive/releases/v1.5.0/qa/frontend/f3-results.md`。每块需 decode/model race tests、真正 iOS/macOS XCUITest（不可以 SnapshotTool/模型替代）、xcodegen、双端 Release/Gallery build、SnapshotTool 实跑、`git diff --check` 与 clean-room/root 搜索。截图是离线合成数据，覆盖浅/深、AX3/5、Reduce Motion、长内容、loading/empty/error/retry/offline/conflict/unknown；历史 `F2C-MAC-UI-AUTOMATION` 已在 F5-A exact 23/0 闭环并经 reviewer full 27/0 确认，不再是 F5/publish blocker。

## 8. 强制验收与测试矩阵

- **证据**：P30/P31–P34 如 §5；F0–F5 只写 `archive/releases/v1.5.0/qa/frontend/f{n}-results.md`，按轮记录 changed paths、fixture、命令、风险、截图和 clean-room `rg`，Plan 只替换状态/下一步。
- **契约/数据**：每个 response/error/409/capability/cursor/revision/preview/receipt 都有 decode+fixture；金额经 `CNYAmountParser` minor units、业务日/显示为 Shanghai、timestamp UTC。后端仍以 Ruff/Pyright/fresh-PostgreSQL/Alembic/Archive/idempotency/守恒门收口。
- **Apple/视觉**：每批 xcodegen、针对性 FiscalKit tests、iOS+macOS build；阶段收口加真实点击 XCUITest。每屏对照高保真但不复刻 HTML，并留 iPhone、mac 紧凑/舒适、浅深、AX3–5、VoiceOver、Reduce Motion、长内容/金额/分页证据；iOS 44pt、mac 28px+扩展点击区，状态不只靠颜色。
- **并发/高风险**：任何预览输入/dismiss/cancel、分页/刷新 race、跨端 409、response-unknown、离线只读、月底均自动覆盖；F3 另守报销灰按钮双端 E2E（loading/empty/error/retry、field reasons、invalid→valid、preview/conflict/success）。

## 9. 切换、回滚与发布门

- 施工期只创建 additive Backend migration 与并行 V15 View；不在生产数据库做 down migration，不删除旧前端，直到 F5 双端 smoke 通过。每次 migration 都可从备份恢复到隔离新库验证；Archive 新关系先通过往返验证。
- 切换后如发现前端故障，回滚到 v1.4.0 已发布 App/commit；新增 API 保持 additive。D3/D5 这类已批准业务收窄如需回退，以新的前向修复和用户批准处理，禁止盲目回滚数据库 head。
- 发布前：干净已提交 revision、生产备份、影子 migration/Archive/财务守恒、精确 head 部署、production smoke、备份恢复、macOS+iOS 签名包的总览/历史/时间轴/月报导出/报销验收、release manifest/tag/push 全部通过。生产部署、备份、迁移、真实数据验收均须当时另获用户授权。
- 用户网页操作清单（仅发布门获授权后）：在 [Fiscal 生产入口](https://fiscal.linotsai.top) 以真实但不进入截图/日志的数据完成总览、报销、报告导出与恢复后的只读核对；本计划阶段无需网页操作。

## 10. 完成定义与当前下一步

- v1.5.0 完成仅当：P30–P34 事实契约与迁移/Archive/守恒全绿；所有既有领域都有 V15 原生入口；旧视觉层已删除；双端正确呈现设计状态语法；报销无解释灰按钮的缺陷被 E2E 防回归；报告/CSV/PDF/下钻使用同一服务端口径；生产和签名设备门完成。
- **当前停止点：发布包生成之前。** 源码版本为 `1.5.0 (24)`，正式 V15 root、旧层删除与最终离线回退均已落盘；本轮不再运行长测试、独立审查或构建。后续只有在用户再次授权时，才从当前干净源码 revision 生成并签名 iOS/macOS 发布包，再执行 tag/push 与生产部署。
