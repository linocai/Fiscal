# Fiscal · PROJECT_PLAN

> 当前目标：**V2.1.0 前端视觉与交互升级 · build 39** ｜更新：2026-09-06（Asia/Shanghai）｜状态：**RELEASE_IN_PROGRESS · 用户已授权一条龙发布**

## 1. 目标、范围与 V2 基线

V2.1.0 是在已发布 V2 信息架构上完成一次有明确风格的产品级前端升级：iPhone 做到轻盈、直接、金额优先；macOS 做到安静而高效的财务工作区。它不是换一套系统默认 `Form`，也不是新增预算、待办或后台能力。

- 发布基线为 `v2.0.0 (38)`，其发布、签名、制品和回滚事实见 [archive/releases/v2.0.0/RELEASE_STATE.md](archive/releases/v2.0.0/RELEASE_STATE.md)。本文件替代已完成版本的施工控制面，不重写该记录。
- 目标版本是 `2.1.0 (39)`。`App/project.yml` 已为 iOS 26.0、macOS 26.0 和 Xcode 26.6；本版仅支持 iOS/macOS 26 及更高版本，验收设备范围是 iPhone 16 及更新机型。不得加入型号识别、旧机型尺寸分支或旧系统兼容代码。
- 保留 V2 根结构：iOS「今日 / 记一笔 / 账目」与中部创建动作；macOS「财务时间线 / 财务分析 / 设置与治理」。保留所有既有领域能力和对象入口；不改 Backend、API、schema、数据模型、迁移、金额逻辑或发布流程。
- 所有写入继续使用 `CNYAmountParser`（元、两位小数）、上海业务日、账户类型校验、预览失效、幂等、冲突/结果未知与待同步保护。视觉重构不能改变任何状态的真实含义或放宽写入权限。

## 2. 已确认的设计决定

| 主题 | V2.1 决定 | 不做的事 |
| --- | --- | --- |
| 设计参考 | Dime 的单笔录入专注为 iOS 锚点；Copilot 的 Mac 工作区为桌面主参考；MoneyCoach 补强金额/图表层级；MOZE 校验中文和复杂关系；Budget Flow 仅参考简洁与跨端一致。 | 不复制任何产品的页面，也不采用 Debit & Credit 的桌面风格。 |
| 品牌色 | 从 App Icon 的明黄和深青建立 token：近白阅读底、深青用于主要文字/操作与选中骨架、明黄只作品牌焦点。收入、支出、预计、待确认、危险各有独立的语义 token。 | 不把品牌黄复用为警告/预计，不以大面积深青或米灰卡片承载页面。 |
| 版式 | 用字号、基线、留白和稳定金额列建立层级；iOS 平面列表优先，macOS 保持可扫读的密度。卡片只承载一项重要摘要、决定或边界。 | 不嵌套卡片，不用默认 Settings 式分组列表替代内容结构，不保留微小文字或常驻空白检查器。 |
| 交互 | 系统导航、手势、键盘、动态字体和辅助功能行为继续可用；动作贴近选中对象，多选后才出现批量操作。动效只表示按下、切换、提交结果。 | 不为“现代感”引入大面积玻璃、装饰动效、第二套导航或隐藏关键操作。 |

## 3. 施工边界与文件责任

- **设计系统**：`V15/DesignSystem/V15DesignTokens.swift` 定义颜色、字体、间距、圆角、层级和状态色职责；`V15Controls.swift`、`Shared/State/V15StateViews.swift`、`Shared/Accessibility/V15Accessibility.swift` 统一按钮、字段、金额、列表行、错误/空/加载/结果状态。不得在 feature 内复制 token 或把业务状态映射为品牌色。
- **根工作区**：`AppShell/V151IOSWorkspace.swift` 只负责两 Tab、中部创建、全屏路由与事实刷新；`V151MacWorkspace.swift` 只负责三空间、范围/选择/检查器及键盘上下文。根工作区不拥有领域写入规则，也不新增入口。
- **五个核心页面**：iOS `Features/Record/V15RecordViews.swift`、`Today/iOS/V15TodayView.swift`、`Ledger/V15LedgerViews.swift`；macOS `V151MacWorkspace.swift`（时间线）与 `Reports/macOS/V15ReportingMacView.swift`（分析）。现有 model、contracts 和 services 只供给真实状态，不因排版而改变接口或并发规则。
- **全量收口面**：`Features/{Timeline,Reports,Credit,Installments,Reimbursements,CashFlow,AI,StatementImport,Reconciliation,Settings,DataSecurity}/**/{iOS,macOS}` 使用新组件逐页替换旧容器与字级；专项流程继续从已有对象路由进入。`V15Gallery*`、Root Smoke、`FiscalKitTests/V15/*` 是证据，不做平行演示 UI。
- **版本与工程**：只在 `App/project.yml` 将 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 改为 `2.1.0` / `39`；Info.plist 继续引用这两个 build setting。因改了 project.yml 必须重跑 xcodegen；不手改生成的 project 文件。

## 4. 分阶段施工

### P0 · 施工护栏与可观察基线

1. 记录当前六个本地 scheme 修改的哈希；它们是用户工作树，不得覆盖或提交。xcodegen 前使用主会话已备份的 `original-schemes`，生成后逐个恢复，再与 `scheme-hashes.json` 比对；严禁用 `git checkout` 还原。
2. 复用已有 `ICTW-v170-iPhone17Pro`（iOS 26.5，`211DD03C-812D-4A42-97EF-F693D7DF924C`），不创建模拟器、不下载 runtime，也不使用 iPhone 13。视觉截图和 UI smoke 均使用它；宽度覆盖由现有 Preview/Snapshot 的紧凑、常规、大屏布局完成。
3. 全程复用 `/Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou`，串行构建/测试，关闭 parallel testing 和 simulator destination cloning。记录目录大小变化；不执行全局 clean，不删除既有 DerivedData、ModuleCache、CoreSimulator 或其他项目缓存。只在完成后删除本任务新建且已确认的 QA 截图/日志。
4. 更新版本设置并生成工程；它与 P1 作为同一施工批次收口，并在 P1 的共享组件和记一笔改动完成后一次性双端编译，避免只改版本时的重复构建。

完成条件：版本构建设置为 2.1.0 (39)，六个 scheme 字节与基线相同，现有模拟器和缓存复用策略已准备就绪；P1 批次收口时完成首次串行双端编译。

### P1 · 共享设计系统与 iOS「记一笔」锚点

1. 重建设计 token 的职责而非逐页换色：近白 canvas/surface、深青 ink/primary/selection、明黄 brand emphasis、独立的 positive/outflow/provisional/warning/danger/unknown 表面；浅深色均满足文字、金额与边框对比。缩紧圆角、阴影和卡片使用，提升正文、辅助信息、金额和状态的可读字号。
2. 把共享 `V15Section`、字段、Picker 容器、操作按钮、金额、列表行和反馈状态改为这套语言。系统组件可以保留交互/无障碍语义，必须脱离“设置页”外观；错误、冲突、结果未知和离线状态继续有文字、图标、恢复路径，绝不只用颜色区分。
3. 以真实 `V15RecordView` 为首个完整页面：金额是输入初始焦点和最大视觉元素；普通支出遵循「金额 → 分类与账户 → 完成」，标题/日期/备注为次级、按需可见。数字键盘打开时，确认操作始终可达；类型切换即时收起不兼容字段。转账、还款、信用消费仍展示其必要账户/账期/预览，并保留所有 disabled reason、sheet 内错误、提交结果和“下一笔”流程。
4. 先用 fixture 路径验证空账户、长中文、六位金额、非法金额、提交中、成功、待同步、冲突、结果未知、还款预览过期和动态字体，而不是只验证正常支出截图。

完成条件：记一笔可在真实服务/model 路径完成普通和特殊交易，视觉上无默认 Form 堆叠；所有现有输入校验、预览失效及写入安全测试保持通过。

### P2 · iOS「今日 / 账目」与根导航

1. 今日以业务日/数据新鲜度、一个主财务位置、最近变化与最近未来、真实待处理事项构成舒展纵向阅读；取消功能大厅和重复摘要。金额主次与状态说明以 P1 token 一致呈现，分析与治理仍是具名二级入口。
2. 账目改为日期分组的平面流水：名称/说明分层、金额稳定右对齐、状态和来源不混作装饰；搜索与账户/日期/类型等筛选收在紧凑的可理解范围栏。空、加载、筛选无结果、已作废和详情返回必须保持原有范围、选择和阅读位置。
3. 两 Tab 加中部创建动作保持原有路由与最低触控范围，减少 material、厚边框和大卡片。键盘、屏幕阅读器标签、最大动态字体和底部安全区均由 root 与组件共同验证。

完成条件：同一 iPhone 16+ 页面族看起来是一套 Fiscal 界面；今日可快速读到真实财务位置，账目可连续扫读，创建、筛选、详情、专项返回和根事实刷新不退化。

### P3 · macOS「财务时间线 / 财务分析」工作区

1. 时间线重整为清楚的范围栏、流水主列和按需检查器：侧栏账户和余额可读，中央日期组、名称、分类/账户、金额列稳定对齐；无选择时检查器收缩为有用摘要或让出宽度，选择后显示关系、动作与结果。保留搜索、键盘创建、inline/multi-select 和返回上下文。
2. 在最小、标准、宽窗口下用布局阈值处理侧栏和检查器，不能以缩小金额或标题换空间。批量操作仅在选择集出现；详情、冲突、待同步和专项跳转保持现有安全边界。
3. 分析页移除固定“期间为空时”等不相关空白列，先给出期间、范围、数据时间和主结论，再组织图表、比较和下钻明细。图表必须显示口径/期间/数据来源，颜色不能单独承担收入、支出、预计或危险含义；下钻回同范围时间线。

完成条件：Mac 在高信息密度下仍能一眼区分导航、范围、事实、选择和可执行动作；无空白检查器浪费，所有键盘/多选/下钻/返回和异常状态可用。

### P4 · 详情、专项任务与治理的全量视觉收口

1. 将 P1 的 token 和组件应用到交易详情、已知未来、报表 iOS、信用、分期、报销、现金流、AI 复核、账单导入、对账、主数据、待同步、数据安全和设置；逐页删除旧米灰底、重复卡片、小字摘要和孤立大面积颜色。
2. 专项页面维持“对象身份 → 金额/状态 → 关系 → 当前可做动作”的阅读顺序。预计/已排期/已确认/正式、作废、离线、冲突、结果未知继续使用已定义的文字和结构差异；不把它们混进正式余额或用新的视觉风格掩盖风险。
3. 逐项检查 iOS sheet 内错误、输入变化后预览失效、异步 generation 守卫、分页请求归属与双端字段一致性；视觉改动如触及这些区域，必须对照已有 mac/iOS 正确样板补齐。

完成条件：没有只升级五个样板页而留下旧视觉岛；所有领域页能承载长中文、长金额、空/失败/离线和安全状态，并共享同一品牌与语义。

### P5 · 收口、人工视觉复核与交付准备

1. 更新必要的 `V15DesignSystemTests`、`V15FoundationTests`、领域单测、Root Smoke 和小范围 Gallery 断言，使 token 职责、根结构、录入路径、状态语义和路由可回归。只增加核心页/状态的 scoped Gallery 或 route；不得默认渲染整套 Gallery 矩阵。
2. 使用 Root Smoke 的正式 workspace + deterministic fixture 模式与 Mac Gallery 的指定路由，做少量有代表性的截图；不创建新 App 或独立 demo。检查浅/深色、正常与最大动态字体、长中文、六位金额、键盘、筛选、选择、多选、空/失败/离线/冲突状态。
3. 人工复核使用现有 iPhone 17 Pro iOS 26.5（作为 iPhone 16+ 验收代表）和 macOS 26：iOS 检查记一笔、今日、账目；Mac 检查时间线、分析以及一个专项返回路径。记录实际问题后修复并重验。

完成条件：视觉、交互、财务安全和构建证据完整；工作树仅含本版有意改动与原有六个 scheme 修改。此阶段不提交、推送、签名、部署或换包，除非用户另行授权。

## 5. 验收与资源门禁

| 门禁 | 必须证明的结果 |
| --- | --- |
| 视觉与可用性 | iOS 轻盈且金额优先，Mac 密集但易读；浅/深色、最大动态字体、长中文和大金额不截断关键事实。系统手势、键盘、VoiceOver/辅助标签和最小触控范围可用。 |
| 财务真值 | CNY 元/两位小数、上海业务日、方向、账户、正式/未来/候选区别不变；视觉不让预计或待同步看起来像已确认余额。 |
| 写入与异步 | 普通支出、转账、还款、信用消费及专项写入的校验、preview invalidation、幂等、conflict、unknown、queued/failed replay、generation 和 sheet 内错误链路不退化；双端防护对称。 |
| 自动验证 | 先运行 `FiscalKitTests`，再串行构建 `FiscaliOS` 与 `FiscalmacOS`；对根/路由变动运行指定 iOS Root Smoke 与 macOS Gallery/Smoke。测试始终带 `-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`，复用既有 DerivedData 和 iPhone 17 Pro。 |
| 工程与磁盘 | `project.yml` 改动后运行一次 xcodegen，恢复并校验六个 protected schemes；构建前后检查 Fiscal DerivedData 大小。禁止创建第二个 DerivedData、下载 runtime、clone simulator 或清除非本任务缓存。 |

## 6. 当前状态、Backlog 与下一步

- **发布进行中**：用户已明确授权一条龙发布，取代本计划先前“未授权发布”的阶段限制。控制面见 [V2.1.0 发布状态](archive/releases/v2.1.0/RELEASE_STATE.md)：生产 revision / Alembic / 服务 / 备份已只读核验，累计无 Backend 差异。后续完成 main 提交推送、不可变标签、签名制品、可回退 Mac 换包和 iOS IPA 交付；只把最终 iOS 安装留给用户。

- **P0–P4 已实现，P5 本地验收完成**：共享视觉系统、iOS 记一笔/今日/账目、Mac 时间线/分析/金额录入、专项页状态语义已收口。双端生成 App 均为 2.1.0 (39)，最低系统 26.0。仅视图、设计系统、版本、QA 和计划改动；未改领域模型或后端，未提交、推送、打包发布或替换正式 App。
- **验证**：两轮完整 FiscalKitTests 各 405 tests / 39 suites 通过；最终正式 iOS/macOS App Debug arm64 构建通过。7 项 iOS 录入、6 项正式 iOS 根、2 项正式 Mac 根及 1 项 Mac 分析下钻测试通过，共 16 项不同 UI 用例。最后的日期布局、深色对比、桌面快捷录入均有针对性复测。
- **实际修正**：日期被挤压和被固定保存栏遮挡、账期辅助值缺失、深色占位提示/黄色按钮图标对比不足；AX5 测试改为在键盘与固定按钮之外的可见内容区滑动，保留强可达断言。Mac 正式 fixture 补齐原有合成未来事项与交易详情，截图使用真实 workspace，不用旧 Today Gallery 替代。
- **证据入口**：[V2.1.0 本地验收记录](archive/releases/v2.1.0/qa/frontend/RESULTS.md)，含截图、执行摘要、源码与 protected schemes 哈希（总约 3.9 MB）。验证采用隔离合成数据，未执行真实后端写入、实体 iPhone 安装或专项状态的穷举截图；这些边界详见记录。
- **2026-09-06 审查与修复完成**：[审查记录](archive/releases/v2.1.0/qa/frontend/REVIEW.md)。R1 / P2 已改为完整账户菜单，选择账户或全部账户流水均回时间线；R2 / P3 已分离备注展开状态与内容，折叠保留文字，保存/下一笔重置。405 tests / 39 suites 通过，新增两个交互用例与原有 Mac 返回/快捷录入用例通过，最终双端正式 App Debug arm64 构建通过。账户菜单补充辅助功能当前值后新用例最终通过；六个受保护 scheme 未改，版本仍为 2.1.0 (39)。最新源码指纹与执行摘要分别为 `qa/frontend/review-fix-source-manifest.json` 和 `review-fix-verification.log`，均位于本版 archive。
- **资源已收口**：复用既有 iPhone17Pro，未新建/克隆设备或下载 runtime；硬件键盘设置恢复为 1，模拟器已 Shutdown。只清理本任务新建重复缓存/结果包约 530 MB，既有缓存均保留。Fiscal DerivedData 约 1.8G → 2.0G，总 DerivedData 4.4G → 4.8G，剩余磁盘约 28 GiB。后续构建继续显式 Debug / arm64 / 2 jobs，并同时设置共享 `MODULE_CACHE_DIR` 和 `CLANG_MODULE_CACHE_PATH`。
- **恢复入口与下一步**：先读本文件、审查记录和验收记录，再检查 `git status --short`，以 `review-fix-source-manifest.json` 核对最新源码。首次验收日志、6 个 scheme 原始备份在 `/var/folders/_v/s6hfcbrj5v3fyxk8jzwh7ft00000gn/T/fiscal-v210-s2uwky1l`；本次修复日志在 `/tmp/fiscal-v210-reviewfix.YX00US`。两项审查问题已关闭，等待用户体验验收；发布须进入既有完整发布流程，不能把本地验证当成发布。
- 本版非目标：后端/API/数据/迁移；新预算、提醒、待办中心；iPad、Watch、Web；App 内 OCR/照片；物理删除领域能力；任何发布动作。
- 后续 Backlog：只有在 V2.1 真实路径完成后，才评估更广的报表交互、预算产品或跨端功能；不得借本版视觉升级绕开现有产品合同。
