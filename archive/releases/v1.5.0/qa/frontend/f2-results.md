# F2-A — Independent Review Verified（第四审 0 findings）

日期：2026-08-15（Asia/Shanghai）

## 范围与契约核对

- 唯一当前事实入口为 `GET /api/v1/reports/facts?window_days=1...90`；完整保留 meta/window、四张卡、future totals、known future events，以及 completeness 的 `last_reconciled_at` 与 `uncategorized_transaction_amount_minor`。
- `GET /api/v1/reports/facts/drill-down` 按后端实际 schema 精确解码 `cash_account`、`credit_cycle`、`reimbursement_outstanding`、`completeness_issue` 四种 union。未知 `item_type` 没有 payload escape hatch，固定降级为不可打开的只读说明。
- `GET /api/v1/reconciliation/attention` 精确解码 `source_type/id`、三档 severity、金额/时间、说明、建议、deep link 与 actions；F2-A 未实现也未请求 ignore 或任何写端点。
- 409 `report_facts_scope_changed` 记录 expected/current data revision、`safe_to_reload` 和 `/api/v1/reports/facts`；它会作废 facts/scope/cursor/link inspector，只有 facts 重新读取成功才解除锁定。

## 实现与边界

- 新增 `V15TodayReadModel`：facts refresh、Attention refresh、scope open/next page、request generation、关闭 inspector 取消归属、opaque cursor 原样转交、局部 next-page failure、离线 snapshot `as_of`、409 接管和安全 link allowlist。
- 唯一可执行的 linked read 是本地 facts inspector、`fiscal://accounts/{UUID}` 的已验证账户读取和 `fiscal://transactions/{UUID}` 的已验证账目读取。恶意 scheme/path/query/UUID、未知 Attention source/action，及 credit/reimbursement/cash-flow/reconciliation/import/AI/migration 目的地均不请求、只给可读说明。
- 为匹配当前已验证的后端必填 schema，最小更新既有 `V15FixtureLibrary` 的 completeness fixture，补 `last_reconciled_at` 与 `uncategorized_transaction_amount_minor`；没有改 F0 行为或视觉层。
- 本块无 SwiftUI View、Gallery route、正式 root、写端点或旧 Overview 接入；F2-B/C、F3+ 仍未启动。

## Changed paths

- `App/Sources/FiscalKit/V15/Foundation/{V15Contracts,V15Services,V15State}.swift`
- `App/Sources/FiscalKit/V15/Features/Today/V15TodayReadModel.swift`
- `App/Sources/FiscalKit/V15/Shared/Fixtures/F2AFixtures.swift`
- `App/Tests/FiscalKitTests/V15/F2ATests.swift`
- `App/Sources/FiscalKit/V15/Shared/Fixtures/V15FixtureLibrary.swift`（仅上述 schema fixture 补齐）

## Builder verification

- `cd App && xcodegen generate`
- `xcodebuild ... FiscalmacOS ... -derivedDataPath /tmp/fiscal-f2a-r2 test -only-testing:FiscalKitTests/F2ATests`：**7/7** 通过。覆盖完整/空/错误/离线、四 union、extreme `Int64`、opaque cursor、local page failure、409 reload、refresh/close race、unknown row/attention/link、恶意 URI、零写入和 Shanghai display 边界。
- `xcodebuild ... FiscalmacOS ... -derivedDataPath /tmp/fiscal-f2a-full-r2 test -only-testing:FiscalKitTests`：**209/209**、**28 suites** 通过。
- `xcodebuild ... FiscaliOS -configuration Release -destination 'generic/platform=iOS Simulator' ... build`：通过。
- `xcodebuild ... FiscalmacOS -configuration Release -destination 'platform=macOS' ... build`：通过。
- clean-room/root 搜索与 `git diff --check`：通过；F2-A 源码未引用旧 Overview、future-events、raw `APITransport`、旧 Feature/root 或 `FiscalDesign`。`PROJECT_PLAN.md` 为 102 行 / 17,988 bytes。

## 留待 Independent Review

- F2-A 尚无视觉 View；真实点击 XCUITest、iPhone/macOS visual matrix、AX/Reduce Motion、PNG 与 SnapshotTool 是 F2-B/C 取得页面后再做的门，不能由本读模型冒充。
- 真实后端网络/权限与真机 VoiceOver 仍是后续发布验收项；本块 fixture 不含账户尾号、凭证或真实数据。

## 首次 Independent Review 修复（2×P2）

- 后端 `ReconciliationService.list_attention` 的全部十种当前生成来源均已逐项回填到 fixture：8 个可 dismiss 类型为 enabled `ignore`，两类 statement-import 为 disabled `ignore` 并保留服务端 reason/message；`reconciliation_missing` 是 info 且链接为 `fiscal://reconciliation/accounts/{id}`，`uncategorized_transaction` 是 info、无金额并唯一允许读取 transaction。F2-A 只展示 capability 的不可执行原因，未实现 ignore，也不会请求写端点；其余真实/未知 Attention 目标安全降级为零请求说明。
- 409 reload gate 现在优先于 facts/scope/link 的缺失或普通错误判断；`openScope`（两种入口）、分页、facts row、attention 和 linked read 在 gate 存在时均保留相同 `requiresFactsReload` 状态且零请求。只有成功刷新到新 facts revision 才解锁；刷新失败仍锁定。
- 新增断言覆盖十种 Attention 的服务端排序/字段/action、真实 reconciliation 安全降级、真实 uncategorized transaction GET、409 后重复 scope/page/link/attention 的零请求、失败 refresh 保持锁定及新 revision refresh 后恢复 scope。

## 首审修复验证

- `xcodebuild ... FiscalmacOS ... -derivedDataPath /private/tmp/fiscal-f2a-reviewfix-r3 test -only-testing:FiscalKitTests/F2ATests`：**8/8** 通过。
- `xcodebuild ... FiscalmacOS ... -derivedDataPath /private/tmp/fiscal-f2a-reviewfix-full test -only-testing:FiscalKitTests`：**210/210**、**28 suites** 通过。
- `xcodebuild ... FiscaliOS -configuration Release -destination 'generic/platform=iOS Simulator' ... build`：通过。
- `xcodebuild ... FiscalmacOS -configuration Release -destination 'platform=macOS' ... build`：通过。
- 已重跑 xcodegen、clean-room 搜索与 `git diff --check`；F2-A 仍未接入旧 Overview/future-events/旧 Feature/root 或任何 write endpoint。F2-B/C、F3+ 和正式 root 均继续锁定。

## 第二次 Independent Review 修复（1×P1、1×P2）

- facts typed read 增加仅用于 `reports/facts` 的强类型 `reloadIgnoringCache` policy。普通刷新保留既有 cache 策略；发生 `report_facts_scope_changed` 后，model 保存后端 `current_data_revision/latest_revision` 的最高 required revision，下一次 refresh 必须绕过 GET cache。低于 required revision 的响应不进入 facts、不会清 gate；读取失败同样保留 gate。稳定的 `facts_reload_required` reason 供后续页面显示。
- Today 的生产离线状态不再在 init 时冻结；默认每次读取 `services.offlineSnapshotAt`（revision store），测试用显式 provider override。受控 transport 在 await 后标记 snapshot 的回退场景证明：init 为 online 的 model 会立即转为 offline，并展示 facts snapshot 的真实 `as_of`；普通线上读取仍不是 offline。
- 增加 42（普通 cache）→409（current 43）→强制 facts 仍 42（继续锁）→强制 facts 43（解锁）的请求 policy/调用序列断言，以及动态 offline snapshot 测试；首审的 Attention 和所有入口 409 gate 覆盖保持不变。

## 二审修复验证

- `xcodebuild ... FiscalmacOS ... -derivedDataPath /private/tmp/fiscal-f2a-review2-r2 test -only-testing:FiscalKitTests/F2ATests`：**10/10** 通过。
- `xcodebuild ... FiscalmacOS ... -derivedDataPath /private/tmp/fiscal-f2a-review2-full test -only-testing:FiscalKitTests`：**212/212**、**28 suites** 通过。
- `xcodebuild ... FiscaliOS -configuration Release -destination 'generic/platform=iOS Simulator' ... build`：通过。
- `xcodebuild ... FiscalmacOS -configuration Release -destination 'platform=macOS' ... build`：通过。
- xcodegen、clean-room 搜索与 `git diff --check`：通过。没有改全局 APITransport、DI、写端点、视觉、F2-B/C、F3+ 或正式 root。

## 第三次 Independent Review 修复（1×P2）

- `refresh()` 不再因 forced facts 的旧 revision 或无效 meta 提前返回：facts 仍保持 `facts_reload_required` gate，而同一轮 Attention 结果在独立 generation 所有权下正常落为 loaded、failed 或 cancelled→idle；旧 Attention 不可覆盖较新 refresh。
- 受控 409 recovery 覆盖 revision 42 < required 43、invalid facts、Attention 读取失败与取消，以及随后 revision 43 解锁；另加延迟旧 Attention 与新 refresh 的竞争断言，证明新请求拥有最终 phase/data。

## 三审修复验证

- `cd App && xcodegen generate`：通过。
- `xcodebuild ... FiscalmacOS ... -derivedDataPath /private/tmp/fiscal-f2a-review3-r2 test -only-testing:FiscalKitTests/F2ATests`：**11/11** 通过。
- `xcodebuild ... FiscalmacOS ... -derivedDataPath /private/tmp/fiscal-f2a-review3-full test -only-testing:FiscalKitTests`：**213/213**、**28 suites** 通过。
- `xcodebuild ... FiscaliOS -configuration Release -destination 'generic/platform=iOS Simulator' ... build`：通过。
- `xcodebuild ... FiscalmacOS -configuration Release -destination 'platform=macOS' ... build`：通过。
- `git diff --check` 与 clean-room 搜索：通过；唯一 `overview/future-events` 命中为 F2 测试的禁止断言。无写 endpoint、raw transport、旧 Feature/root 或 `FiscalDesign` 引用。F2-B/C、F3+ 与正式 root 继续锁定。
- 首次全库尝试因共享临时 DerivedData 耗尽本机磁盘而中断；确认无运行中 Xcode/Swift 任务并清理获批准的可再生缓存后，以全新路径重跑并通过，非代码失败。

## 第四次 Independent Review（0 findings）

- 四轮链：首审 2×P2（Attention 真实 schema/409 gate）、二审 1×P1 + 1×P2（强制 fresh facts 与动态 offline snapshot）、三审 1×P2（旧/无效 facts 与 Attention generation 落态）、第四审 **0 findings**。
- F2-A 已获 Independent Review Verified。Builder 证据保留为定向 **11/11**、全 FiscalKit **213/213（28 suites）**，以及 iOS/macOS Release build 均通过；不因本轮文档收口重复执行构建。
- 残余风险不变：真实后端鉴权/网络联调、真实设备 VoiceOver 与视觉矩阵须在后续页面和发布验收中完成；本块仍无视觉 View、写 endpoint 或正式 root。F2-B 可启动；F2-C、F3+ 与正式 root 继续锁定。

## F2-B — Builder Verified，待 Independent Review

日期：2026-08-15（Asia/Shanghai）

### 实现与边界

- 新增 iOS-only `V15TodayView`：snapshot/as-of、Shanghai/CNY 口径、按 severity→日期稳定排序的 Attention（文字、符号与颜色）、平静态、精简 known future 和四张 facts 卡。长金额或 AX5 时卡片改为单列全宽，保证单行可读。
- cards 进入同一 `data_revision` 的只读 scope sheet；四种 typed item 可打开只读 inspector，未知 item/attention/link 均安全降级且不发请求。sheet 内覆盖 loading、empty、partial/page error、retry、close；409 后只可刷新 facts，fixture 断言该刷新为强制 uncached revision 43。
- offline 显示 snapshot 时间并保持只读；没有写 endpoint、旧 Overview/Views、future timeline、正式 root 或 F2-C macOS 视觉。macOS 分支保留空实现，仅为共享编译，不构成 F2-C。

### Changed paths 与 fixture routes

- `App/Sources/FiscalKit/V15/Features/Today/iOS/V15TodayView.swift`
- `App/Sources/FiscalKit/V15/Shared/Fixtures/F2BFixtures.swift`
- `App/Sources/FiscalKit/V15/AppShell/V15GalleryShell.swift`
- `App/Tests/V15GalleryUITests/F2BGalleryUITests.swift`
- Gallery routes：`today`、`today-calm`、`today-empty-scopes`、`today-facts-error`、`today-scope-error`、`today-page-error`、`today-conflict`、`today-offline`、`today-unknown-attention`、`today-long`。

### Builder verification

- `cd App && xcodegen generate`：通过。
- 定向 `FiscalKitTests/F2ATests`：**11/11**；全 `FiscalKitTests`：**213/213（28 suites）**。
- `V15GalleryiOS` 的真实 `F2BGalleryUITests`：**4/4**（79.657s）；实际点击四张 facts 卡与 scope、pagination/page error、409→forced reload、已知/未知 attention、sheet close/error/retry，并断言 AX/只读状态。
- 正式 `FiscaliOS` 与 `FiscalmacOS` Release build、`V15GalleryiOS`、`V15GallerymacOS`、`V15GallerySnapshotTool` build：均通过。
- 通过 `xcresulttool` 导出并逐张目检 7 张附件：`screenshots/f2/f2b-ios-{light-normal,scope-readonly-inspector,scope-page-error,conflict-reloaded,unknown-attention,dark-ax5-offline-long-amount,scope-error}.png`；覆盖浅色、深色、AX5、offline、409、scope error 和长金额。
- clean-room `rg` 与 `git diff --check`：通过；F2-B 未引用 raw transport、旧 Overview/future-events、旧 Feature/root、`FiscalDesign` 或写方法。

### 留待 Independent Review

- 需逐项复核 F2-A read-model 的 revision/409、unknown 零请求、scope cursor、offline/read-only、VoiceOver 顺序与截图证据；真实后端鉴权/网络及真机 VoiceOver 仍为发布验收。
- F2-C、F3+ 和正式 root 继续锁定。

## F2-B 首次 Independent Review 修复（4×P2）— Builder Verified，待第二次 Independent Review

日期：2026-08-15（Asia/Shanghai）

- `facts.future` 新增紧凑的“未来口径”区块，只呈现 typed facts 的 exact/confirmed/expected/scheduled 流入流出与 `after_confirmed_outflow_minor`；零值明确展示，不调用 `future-events`，不构造 F3 时间轴或客户端预测。
- 离线横幅改为 `model.offlineAsOf`（facts `meta.as_of`）优先，仅在尚未取得 facts 时回退保存时间；fixture 令两时间不同，UI 断言且截图显示事实截止 `2026年8月16日 00:01`，不是保存时间 `2026年8月12日 00:00`。
- `V15TodayReadModel` 仅在已解析的 account/transaction allowlist link 上保存本次 locator；失败 sheet 的“重试”以同一 locator 重新读取，generation、close、unsafe link、F3 destination 和新请求均不能被旧请求覆盖或留下可执行输入。新增模型覆盖失败→重试成功、close/cancel、新请求竞争与 unsafe 零请求。
- F2-B 增加 `today-unknown-scope`（unknown drill item 携带 unsafe fact link）与 `today-linked-retry` fixture。真实 UI 打开 unknown scope row 后只显示只读说明、可关闭、无保存或可执行动作；linked transaction 首次失败后在 sheet 内重试成功。

### Changed paths、routes 与证据

- 本轮额外改动：`App/Sources/FiscalKit/V15/Features/Today/V15TodayReadModel.swift`、`App/Sources/FiscalKit/V15/Shared/Fixtures/F2AFixtures.swift`、`App/Tests/FiscalKitTests/V15/F2ATests.swift`，以及既有 F2-B iOS view/fixtures/UI tests。
- 新增 routes：`today-zero-future`、`today-linked-retry`、`today-unknown-scope`；原有 `today-offline` 继续提供不同的保存时间与 facts as-of。
- 新/更新截图：`f2b-ios-{future-totals-zero-dark-ax5,offline-facts-as-of,linked-read-retry,unknown-scope-item}.png`；合计 11 张 F2-B PNG，均由最新 **6/6** UI run 导出并经 `view_image` 目检。

### 修复验证

- `cd App && xcodegen generate`：通过。
- `FiscalKitTests/F2ATests`：**12/12**；全 `FiscalKitTests`：**214/214**。
- `V15GalleryiOS` 的真实 `F2BGalleryUITests`：**6/6**。覆盖四 cards/scope、pagination/409、known/unknown attention、future zero+dark AX5、facts-as-of offline、failed→retry linked read、unknown scope row、sheet close/error/retry。
- 正式 `FiscaliOS` / `FiscalmacOS` Release、Gallery iOS/macOS 与 SnapshotTool build：通过；`V15GallerySnapshotTool` 以 Xcode Debug framework path 实跑，导出 34 张既有 Gallery PNG。F2-C 未启动，因此该 macOS 工具实跑不声称 F2 Today 视觉证据。
- clean-room `rg` 与 `git diff --check`：通过；唯一 `future-events` 命中为禁止引用的测试/注释，没有旧 Overview、raw transport、写方法、旧 Feature/root 或 `FiscalDesign` 依赖。

### 留待第二次 Independent Review

- 复核 4×P2 的 typed future 字段口径、offline facts-as-of 优先级、retry locator 生命周期/generation、unknown scope 的零请求与附件；真实后端鉴权/网络、真机 VoiceOver 和 F2-C macOS 视觉仍未完成。
- F2-C、F3+ 与正式 root 继续锁定。

## F2-B 第二次 Independent Review 修复（1×P2）— Builder Verified，待第三次 Independent Review

日期：2026-08-15（Asia/Shanghai）

- P2 根因：Attention 图标继承 Dynamic Type 文字缩放，却被 22pt 宽度框限制；AX5 下可能压入正文。改为固定 18pt 视觉 glyph、44×44pt badge/24×44pt chevron，并在所有 Accessibility size 切换为“badge + severity + chevron”首行、文案次行的纵向布局。文字保留 layout priority，VoiceOver 仍只读合并后的 severity、说明与行动提示。
- 真实 UI 覆盖 11 条 AX5 Attention 路径：normal fixture 的 10 条 critical/warning/info（包含短/长说明）在浅色逐条可达且可点击；深色复验三档，另在深色 AX5 验 unknown critical 安全降级。相同 View 的 non-AX 路径保留横排；固定 badge 既不裁切也不会与正文重叠，所有 row 仍使用 platform 44pt hit area。
- 新增并目检 `f2b-ios-attention-ax{3-light,5-light,5-dark}-all-severities.png`；复拍且目检 AX5 `f2b-ios-{future-totals-zero-dark-ax5,offline-facts-as-of,dark-ax5-offline-long-amount}.png`。离线截图仍明确显示 facts `as_of` 的 2026年8月16日 00:01，而非保存时间。

### 本轮验证

- `cd App && xcodegen generate`：通过。
- `FiscalKitTests/F2ATests`：**12/12**；全 `FiscalKitTests`：**214/214**。
- `V15GalleryiOS` 真实 `F2BGalleryUITests`：**7/7**；包括 11 条 AX5 Attention 可达/label 断言及既有 cards/scope/pagination/409、offline、future、retry、unknown 和 sheet error 路径。
- 正式 `FiscaliOS` / `FiscalmacOS` Release、Gallery iOS/macOS、SnapshotTool build：通过；SnapshotTool 以 Debug framework path 实跑并导出 **34** 张 Gallery PNG。
- `git diff --check` 与 F2 clean-room 搜索：通过；没有 raw transport、旧 Overview/Feature/root、`FiscalDesign`、写 endpoint 或 F3 future-events 调用。F2-C、F3+ 与正式 root 继续锁定。

### 留待第三次 Independent Review

- 复核 AX5 Visual/VoiceOver 顺序、44pt hit area 与截图，以及此前 F2-B future/offline/retry/unknown 的边界；真实后端鉴权/网络和真机 VoiceOver 仍属于发布验收。

## F2-B — Independent Review Verified（第三审 0 findings）

日期：2026-08-15（Asia/Shanghai）

- 三轮审查链已收口：首次 **4×P2**（facts future、offline facts-as-of、linked-read retry、unknown scope 安全降级）→第二次 **1×P2**（AX 图标与正文重叠）→第三次 **0 findings**。F2-B 获 Independent Review Verified。
- Builder 最终证据：真实 `F2BGalleryUITests` **7/7**；定向 `FiscalKitTests/F2ATests` **12/12**；全 `FiscalKitTests` **214/214**；xcodegen、正式 iOS/macOS Release、Gallery iOS/macOS 与 SnapshotTool build 均通过，SnapshotTool 实跑 **34** 张 PNG。
- 截图证据为 `screenshots/f2/f2b-*.png` 共 **14** 张，包含浅/深、AX3/AX5、long amount、future totals、offline facts-as-of、409、scope error/page error、linked retry、unknown attention/scope item；第三审复核所需 AX5 future/offline 和 Attention 截图均已 `view_image` 目检。
- 真实后端鉴权/网络联调、真机 VoiceOver 和 F2-C macOS 视觉仍是后续/发布验收；F2-C Builder 现可启动，F3+ 与正式 root 继续锁定。

## F2-C — Builder implementation complete / UI automation deferred

日期：2026-08-15（Asia/Shanghai）

### 实现、范围与证据

- 新增 macOS-only 三栏 Today：Today/四事实镜头索引、按 severity/日期的 Attention 与已知未来脊柱、只读检查器；复用 F2-A `data_revision`、scope、409 gate、offline 和 allowlist，不接写端点或 F3/F4 页面。紧凑窗口的金额行改为正文下方独占行，避免长金额挤成逐字竖排。
- 新增 F2-C fixture route、SnapshotTool 场景及独立 `V15GallerymacOSUITests` target/scheme；真实测试代码覆盖 scope、分页、scope error/retry、409→刷新、unknown、安全检查器关闭及键盘刷新。它不是 iOS UI test 的替代或别名。
- Changed paths：`V15/Features/Today/macOS/V15TodayMacView.swift`、`V15/Shared/Fixtures/F2CFixtures.swift`、`V15/AppShell/V15GalleryShell.swift`、`Tests/V15GallerySnapshotTool/V15GallerySnapshotTool.swift`、`Tests/V15GallerymacOSUITests/F2CMacGalleryUITests.swift`、`project.yml` 及生成 project/scheme、此 QA 与 `screenshots/f2/f2c-macos-*.png`；无 Backend、正式 root、旧 View、写 endpoint 或 F3+ 改动。
- 本轮 `cd App && xcodegen generate`、F2-A 定向 **12/12**、正式 iOS/macOS Release、Gallery iOS/macOS、SnapshotTool build 均通过；SnapshotTool 以 `DYLD_FRAMEWORK_PATH=/tmp/fiscal-f2c-ax/Build/Products/Debug` 实跑。全 FiscalKit 本轮启动后未进入业务测试，约两分钟后仅终止本轮命令树，未记作通过（此前 Builder 证据 214/214 不替代本轮）。
- `screenshots/f2/f2c-macos-*.png` 共 12 张，已目检 comfortable/compact、light/dark、AX5 long amount、offline、409、scope error、unknown；它们仅是视觉证据，**不能替代真实 macOS UI 自动化验收**。
- 最终 clean-room `rg` 未命中旧 Overview/future-events、raw transport、写/ignore 入口或 AX harness 残留；`git diff --check` 通过，`PROJECT_PLAN.md` 为 102 行 / 18,330 bytes。

### Deferred gate — `F2C-MAC-UI-AUTOMATION`

- BFT 已成功；独立 macOS UI 自动化三次均 **0 个业务测试**：初跑、串行禁并发重跑，以及 SIGKILL 用户卡死约 7 小时的 `testmanagerd` 后以同一 DerivedData `build-for-testing → test-without-building` 重跑；最后一次仍为 `Timed out while enabling automation mode`。最新 xcresult：`/tmp/fiscal-f2c-macui-bft/Logs/Test/Test-V15GallerymacOS-2026.08.15_12-15-12-+0800.xcresult`（新 `testmanagerd` PID 64713、runner PID 64714）。
- 排查确认 `AXIsProcessTrusted()` 为 true，但 AX windows 持续为 0；CGWindow 可见真实窗口而 ScreenCapture 拒绝。未将截图、SnapshotTool 或读模型作为 UI automation 替代。用户已批准本阶段先跳过，**但它仍是 F5/publish 前 blocker**。
- 用户重启并恢复 macOS automation/权限环境后，先运行：`cd App && xcodebuild -project Fiscal.xcodeproj -scheme V15GallerymacOS -destination 'platform=macOS' -derivedDataPath /tmp/fiscal-f2c-macui-bft -parallel-testing-enabled NO test-without-building -only-testing:V15GallerymacOSUITests/F2CMacGalleryUITests`。`/tmp/fiscal-f2c-macui-bft` 可再生；若不存在，先以同一 scheme/destination/path 执行 `build-for-testing`。在这之前 F2-C 可进入实现 Independent Review，但不可声称 UI 自动化已通过。

## F2-C 初审修复（2×P2）— implementation repair complete / UI automation deferred，awaiting second Independent Review

日期：2026-08-15（Asia/Shanghai）

- P2 refresh：macOS view 现由唯一 `refreshCurrentLens()` 捕获当前镜头。facts 成功刷新、gate 已清且镜头为四个 scope 之一时，以新 `data_revision` 重开该 scope；失败或仍需 reload 时保留错误/409 gate。普通 Cmd-R 与 409 reload 共用此路径；`scopePhase == .idle` 仅显示“选择/重新读取”说明，绝不画 loading skeleton。F2-A 受控断言同时核对 revision 43、loaded scope 和请求不带旧 cursor；macOS UI test 保留刷新后必须出现新 scope row 的断言，待原自动化门恢复执行。
- P2 future：macOS Today 新增只读 `facts.future` totals，字段、金额方向、zero 文案和“服务端当前窗口；不计入当前现金”均与 iOS 相同；不请求 `future-events`。zero-future 画廊 fixture 同时使用空 Attention，以便在紧凑窗口真实呈现零口径；long/AX5 使用独立金额行及缩放下限，避免逐字竖排。
- 修复涉及 `V15TodayMacView.swift`、`F2BFixtures.swift`（仅 zero-future gallery 的空 Attention）、`F2CFixtures.swift`、`F2ATests.swift`、`F2CMacGalleryUITests.swift`、`V15GallerySnapshotTool.swift`、12 张 `screenshots/f2/f2c-macos-*.png`、本 QA 与主 Plan；无 Backend、正式 root、旧 View、写 endpoint 或 F3+ 改动。

### 本轮验证与限制

- `cd App && xcodegen generate`：通过；正式 `FiscaliOS` Release 和 `FiscalmacOS` Release：通过；`V15GalleryiOS`、`V15GallerymacOS`、`V15GallerySnapshotTool` build：通过。SnapshotTool 以 `/tmp/fiscal-f2c-repair/Build/Products/Debug` 的 framework path 实跑，输出恰 12 张 F2-C PNG。
- 已以 `view_image` 逐项复核 normal light、zero-future dark compact、long light/AX5 dark compact、409 light/dark；zero totals、极长金额横向可读及真实 409 reload gate 均可见。其余 offline、scope error、unknown 的浅/深图同批生成保留。
- 本轮 macOS `FiscalKitTests/F2ATests` 在编译后未进入业务测试即卡住，已仅终止本轮命令树；xcresult 为 `/tmp/fiscal-f2c-repair/Logs/Test/Test-FiscalmacOS-2026.08.15_13-00-48-+0800.xcresult`，未记作 12/12 或全 FiscalKit 通过。`FiscaliOS` scheme 的 TestAction 仅含 `FiscalUITests`，不能作为 FiscalKit 替代，故未篡改 scheme/target。此前 214/214 仅为既有基线，不替代本次重跑。
- `F2C-MAC-UI-AUTOMATION` 原延期门保持不变：未重跑 macOS UI 冷启动、未用截图/模型冒充真实点击验收。发布前按上节精确恢复命令复跑；本次新增 test-runner 重试也应在环境恢复后先跑 `FiscalKitTests/F2ATests` 及全 `FiscalKitTests`。

## F2-C 第二次 Independent Review 修复（1×P2）— implementation repair complete / UI automation deferred，awaiting third Independent Review

日期：2026-08-15（Asia/Shanghai）

- P2 lens ownership：`refreshCurrentLens()` 不再在 `await model.refresh()` 前捕获 scope。刷新成功、gate 清除后才读取**当前** sidebar lens：Today 直接停留在 Today，当前四 scope 才以新 revision 重新打开。刷新间切换 cash→credit 时，后续只重开 credit；若之后选回 Today，则不制造 scope read。已有 model `scopeGeneration` 使刷新后的 read 与用户后续选择竞争时由最新选择获胜，避免 cash row 落在 credit 标题下。
- 新增纯策略 `V15TodayMacRefreshPolicy` 与 `F2CMacTodayPolicyTests`，覆盖当前 credit/cash、Today 与非法 future scope；延期的真实 macOS UI test 新增 conflict refresh 后立即切 credit 的断言，要求仅有 credit title/row。现有 test 同时保留失败、409 与 scope 重开路径，待 automation 恢复执行。
- 本轮 `xcodegen`、正式 `FiscaliOS`/`FiscalmacOS` Release、Gallery iOS/macOS、SnapshotTool build 通过；SnapshotTool 以 `/tmp/fiscal-f2c-repair/Build/Products/Debug` 实跑并保持 12 张 F2-C PNG。刷新竞态不在静态截图中可见，故未以旧图宣称行为验收。
- 定向 `FiscalKitTests/F2ATests` + `F2CMacTodayPolicyTests` 尝试一次后仍未进入业务测试，已仅终止本轮命令树；xcresult：`/tmp/fiscal-f2c-repair/Logs/Test/Test-FiscalmacOS-2026.08.15_13-10-09-+0800.xcresult`。不计作测试通过；`F2C-MAC-UI-AUTOMATION` 延期及其发布前恢复命令均不变。F3+、正式 root 继续锁定。

## F2-C 第三次 Independent Review 修复（1×P2：延期 UI 测试有效性）— implementation repair complete / UI automation deferred，awaiting fourth Independent Review

日期：2026-08-15（Asia/Shanghai）

- 实现未变；只修测试有效性。新增仅 Gallery transport 使用的 `today-refresh-lens-race`：cash scope 先稳定产生 revision-42 409，第二次 uncached facts refresh 固定延迟 750ms 后才给 revision 43。生产 read model 与网络路径没有 delay、hook 或测试分支。
- spine 的真实 `factsPhase.loading` 现在有 AX identifier；scope row 按实际 `selectedScope.scopeType` 命名，如 `v15.f2c.scope.row.credit_cycles.0` / `cash_accounts.0`，不再让通用 `row.0` 掩盖错 scope。race UI test 先等待 loading 可见，再点 credit，最后要求 credit-specific row/title 且 cash-specific row/title 均不存在；旧的“await 前捕获 cash lens”实现将稳定遗留 cash row，因此必失败。
- `V15GallerymacOS` 以 `/tmp/fiscal-f2c-macui-bft` 执行 `build-for-testing`：**TEST BUILD SUCCEEDED**，确认 fixture、scope AX 语义和独立 macOS UI test 均已编译/签名纳入。遵循延期例外，未运行 `test-without-building` 或任何 macOS UI 冷启动。
- 本轮 xcodegen、SnapshotTool build+实际运行（12 张 F2-C PNG）、正式 iOS/macOS Release 均通过；竞态是动态交互，既有截图没有可见内容变化，未以截图代替该 UI 验收。`F2C-MAC-UI-AUTOMATION` 仍为发布前 blocker，F3+ 与正式 root 继续锁定。

## F2-C 第四次 Independent implementation/test-design Review（0 findings）

日期：2026-08-15（Asia/Shanghai）

- 审查链完整收口：首次 **2×P2**（scope refresh / `facts.future` totals）→第二次 **1×P2**（refresh 后当前 lens ownership）→第三次 **1×P2**（确定性 race fixture、loading marker、scope-specific row 语义）→第四次 **0 findings**。状态为 **Independent implementation review verified; `F2C-MAC-UI-AUTOMATION` deferred**。
- 此结论仅覆盖实现和可编译的测试设计，不宣称完整 runtime 验收。此前三次 macOS XCUITest 都是 0 个业务测试（`testmanagerd` enabling automation mode timeout）；BFT 成功，最近及历史 xcresult、重跑命令、`AXIsProcessTrusted()`/窗口诊断和用户批准的 skip policy 均保留在本 QA 的 Deferred gate 节，不由截图、SnapshotTool 或读模型替代。
- `F2C-MAC-UI-AUTOMATION` 继续是 F5/publish audit 前 blocker：用户重启并恢复 automation 环境后，先按本文件既有 `build-for-testing → test-without-building` 精确命令复跑原 `F2CMacGalleryUITests`，并重跑本轮未能进入业务执行的 FiscalKit 测试。按用户批准的全局例外，现在仅可启动 F3 Planner（只规划）；F3 Builder、F4/F5 与正式 root 仍锁定。
