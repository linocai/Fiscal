# Fiscal · PROJECT_PLAN

> 更新：2026-09-06（Asia/Shanghai）｜目标：**V2.2.0 原生前端重构**｜状态：**2.2.0（40）完整 Review 已完成，R1–R9 与 D1 已修复，408 项单测、针对性回归与双端 App 构建通过；已获用户“一条龙”授权，正在执行正式发布**

## 1. 目标、边界与当前事实

- 把已发布的 V2.1.0（39）从旧骨架的小修升级为完整、清晰、现代的个人财务产品界面。实现必须是 Swift/SwiftUI；参考图只约束信息优先级、色彩关系和体验方向，绝不作为 PNG、HTML、WKWebView 或逐像素复刻规格。
- 已确认的参考：Mac 的[总览与账户概览](archive/design/mac-redesign-2026-09-06/fiscal-mac-target-v2.png)及[账户选择浮层](archive/design/mac-redesign-2026-09-06/fiscal-mac-accounts-picker-v2.png)；iOS 的[页面内容](archive/design/ios-redesign-2026-09-06/fiscal-ios-main-pages-v1.png)、[记一笔](archive/design/ios-redesign-2026-09-06/fiscal-ios-record-v1.png)与[悬浮栏方向](archive/design/ios-redesign-2026-09-06/fiscal-ios-navigation-v2.png)。iOS 图中右上角铅笔不是冻结决定；高频“记一笔”必须留在底部、有文字、单手可发现。
- 当前生产基线为标签 v2.1.0 的 build 39，源码 353c381ff6a2540a048e8c3d3a7d12b57e24e9ad，发布记录提交 96d2f9a27bc5413b915dbb74002035d96026d2c7。App/project.yml 已更新为 **2.2.0 / 40**，iOS/macOS 26.0、Swift 6；xcodegen 后六个受保护 scheme 已按原始字节恢复，用户已授权一条龙发布，执行进度见 [RELEASE_STATE.md](archive/releases/v2.2.0/RELEASE_STATE.md)。
- 仅支持 iOS/macOS 26+ 与 iPhone 16+。在 main 工作；不新增模拟器、runtime、分支或 DerivedData。复用 iOS 26.5 主模拟器 iPhone 17 Pro（211DD03C-812D-4A42-97EF-F693D7DF924C）、/Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou 与 /Users/linotsai/Library/Developer/Xcode/DerivedData/ModuleCache.noindex；保持串行、少量构建；修复后仍有约 54 GiB 可用空间。
- 六个已有本地 scheme 修改是受保护用户状态，必须逐字保留且不得暂存或回滚。V2.2.0 不改 Backend/API/migration，除非施工中证明现有只读契约无法支持已确定页面；届时先把缺口写回本计划再决定。

## 2. 已核实的实现起点

- 根分别是 V151IOSWorkspace.swift（仅“今日 / 账目”加自绘中央黄色加号）与 V151MacWorkspace.swift（时间线、分析、设置及多个次级模块）。App/README.md 仍声明 iOS 不使用 TabView，这是旧约束，施工时必须更新。
- 业务和安全层可复用：V15Services、V15TodayReadModel、V15ReportingModel、V15LedgerModel、V15RecordModel、V15AccountDetailModel，以及信用/分期/报销/现金流/导入/AI 各自 model。此次重构不改金额、版本、幂等或后端含义。
- V15TodayReadModel 从 reports/facts 读取同一 revision 的现金余额、信用欠款、未收报销、未来事项与下钻 scope；V15ReportingModel 从 reports/v2/monthly/yyyy-MM 和 yearly 读取收入、个人实际支出、净收支、分类、账户与可选 daily 序列。图表和“本月”数据只能取后者；不得拿 30 天 facts 伪装为自然月趋势。
- 现有设计系统在 V15DesignTokens.swift / V15Controls.swift，多为旧版白灰卡片和自绘底栏假设。它是重建视觉基础的入口；专项页仍要保留错误、离线、未知结果、预览和辅助功能组件。
- iOS 26 SDK 已有原生 TabView、tabViewBottomAccessory(content:) 与 tabBarMinimizeBehavior(.never)。26.0 只能使用基础 accessory 重载；带 isEnabled: 的重载从 26.1 起可用，不能成为 26.0 的编译或行为前提。
- RootSmoke 的正式 fixture 会直接装载现有 V151IOSWorkspace / V151MacWorkspace；若新根改名或替换，必须同步该注入点。既有 Mac “三空间”断言须改成四目的地与入口守恒，不能删除状态恢复和返回上下文测试。

## 3. 固定产品与视觉决定

### 3.1 共同语言

- 品牌以深青 #153B35、提亮深青 #2D5B52、焦点明黄 #F5C93F 为骨架；大面积阅读面为白/冷中性。黄色用于品牌锚点与一个明确主动作，不用于警告、大片背景或每张卡；错误、未知、离线继续使用独立语义色。
- 用大金额、稳定列、少量有职责的容器和留白建立财务感。禁止把旧时间线、说明文字、分隔线和圆角逐项换色后称为重构；也不要把 Apple Settings 的成组列表当作主内容。
- 用户输入和显示的金额一律是元；CNYAmountParser 负责转换为 Int64 分，API 与领域模型继续只传递 minor units。日期和自然月以 Asia/Shanghai。设计层不能自行解析或换算金额。

### 3.2 Mac：四个主空间与多账户侧栏

- 用 SwiftUI NavigationSplitView 组织**总览 / 交易 / 账户 / 分析**，在深青侧栏保持文字导航、品牌 F、当前态和键盘可达性；“设置与数据”移入窗口工具栏/账户管理的次级入口，非第五主空间。
- 侧栏常驻一张提亮深青“账户概览”卡：现金与储蓄、信用账户两组各只显示总额、数量和“当前余额/当前欠款”语义。点击组打开 SwiftUI popover：搜索、受限高度滚动列表、键盘上下/回车/Escape；点账户显式进入账户上下文。不得列出所有账户、不得只突出现金、不得悄悄改变总览口径。
- 总览按阅读顺序展示：账户净额（明确标注为“现金与储蓄余额 − 当前信用欠款”，只在同一 facts 快照内计算）、现金与储蓄、信用欠款；本月收入/个人实际支出/净收支；有 daily 才显示趋势；接下来要付；最近交易。净额计算使用不溢出的差值路径；负净额必须带负号显示，不能复用会取绝对值的 V15MoneyPresentation 的 balance/neutral 样式。未收报销与数据完整性按实际状态进入提醒/明细，不伪装成资产。
- 交易页保留桌面高密度列表、搜索、筛选、详情、批量分类与键盘快捷键；账户页承接完整可搜索账户表、余额/额度、账户流水及管理入口；分析页承接现有四个报表透镜和下钻/导出。所有次级任务从上下文打开而非消失。

### 3.3 iPhone：四个目的地、一条真实系统栏和一个底部创建动作

- 根改为原生 TabView：**总览 / 交易 / 账户 / 分析**四个目的地均有图标和文字。让 iOS 26 提供浮动材质、选中态、安全区与滚动行为；不再自绘玻璃胶囊、方形选中块、右侧黄色方块或旧式正中巨大加号。
- 使用 tabViewBottomAccessory 放一个轻量、明确标注“记一笔”的创建 Button，作为四个目的地之外的动作；它不伪装第五 Tab，也不移到难发现的右上纯图标。首批以 tabBarMinimizeBehavior(.never) 维持可发现性；不另套一层玻璃背景。点击后 fullScreenCover 打开现有金额优先编辑器，编辑时没有主导航，关闭回原 Tab，确认写入后刷新所涉 read model。
- iOS 总览与交易保持轻盈、垂直可扫；账户页以现金/信用分组汇总、搜索和长列表承载多账户；分析页先给可读的月度摘要与趋势/分类，再打开现有完整报表下钻。设置与治理从账户页的管理/更多工具栏进入，不能占用主 Tab。
- 记一笔保留支出、收入、转账、信用卡消费、还款五类。金额优先、名称、随类型变化的账户/目标账户/分类/账期、上海日期、备注和保存动作必须完整可达；视觉简化不得删去类型兼容校验。

### 3.4 全应用覆盖是完成硬条件

- V2.2.0 完成的定义是**每个用户可达页面、详情、表单、流程与弹层**都采用同一套 SwiftUI 语言；两端对称覆盖各自现有能力，无参考图不构成保留旧风格或延期的理由。按已定字体、金额、间距、容器、字段、按钮、工具栏、返回/关闭/保存和状态提示推导，不新增业务。
- Mac 与 iPhone 分别按密度和输入方式布局，不机械缩放；键盘、文件选择器、分享、权限等系统组件沿用原生行为，只统一 App 可控内容与动作。

| 页面家族 | 当前源目录 | 必改表面 |
| --- | --- | --- |
| 主空间 | AppShell；Today、Ledger、Reports | 四主空间、总览、列表、账户与分析 |
| 交易详情与编辑 | Features/Record、Ledger | 类型编辑、详情、关联、批量分类与确认状态 |
| 账户、分类与商户 | Foundation/V15AccountDetailModel；Settings/MasterData | 账户详情、流水、账户/分类/商户管理与归档入口 |
| 信用与分期 | Features/Credit、Installments | 账期、还款、预览、建立/编辑/操作全流程 |
| 报销 | Features/Reimbursements | 报销单、对象、回款、预览与结果 |
| 现金流与未来 | Features/CashFlow、Timeline | 周期/计划、未来详情、确认入账与返回 |
| 报表 | Features/Reports | 四透镜、图表、下钻、导出与保存反馈 |
| 账单导入 | Features/StatementImport | 选择、解析、预览、逐项核对和结果 |
| AI | Features/AI；Settings/MasterData | 待确认提案、详情、确认/拒绝与配置 |
| 设置与连接 | Settings/MasterData、DataSecurity、Bootstrap、AppShell | 主数据、归档/恢复、AI/提案、导入、待同步、安全、口令/凭据失效/首次连接/服务未就绪 |
| 共享弹层与状态 | DesignSystem、Shared/State、Shared/Accessibility | picker、sheet/popover/fullScreenCover、skeleton、空/错误/离线/冲突/未知、预览/只读/待同步/成功/进度 |

- M3 必须逐家族完成实际视觉与交互重构，不能只接通旧页、换背景或套 token；M4 逐项核对可达页面与 sheet/popover/fullScreenCover，拒绝主界面新风格、子页旧风格的混搭验收。
- 逐家族施工及验证状态记录在 [UI_COVERAGE.md](archive/releases/v2.2.0/qa/UI_COVERAGE.md)；本文件始终是唯一计划入口。

## 4. 入口映射：旧能力全部保留

| 用户任务 | 新主路径 | 次级路径与原能力 |
| --- | --- | --- |
| 看余额、欠款、待收、近期应付 | 总览 | V15TodayReadModel 的 facts/scope；信用、报销、现金流未来事项均回到已核验所属页 |
| 手工记账 | iOS 底部“记一笔”；Mac 总览/交易工具栏“记一笔” | V15RecordView / V15RecordModel；五种交易类型、真实保存结果和刷新不变 |
| 查找、筛选、修改、作废/恢复交易 | 交易 | V15LedgerModel 的查询、详情、版本冲突、批量分类与来源/关联操作完整保留 |
| 管理现金、储蓄、信用账户及查看流水 | 账户；Mac 侧栏账户概览可直达 | V15AccountDetailModel、主数据账户管理；信用账户进一步到信用账期 |
| 账期、还款、分期 | 账户详情或交易关联入口 | V15Credit / V15Installment 保留账期调整、预览、建立/编辑/操作、未知结果核验 |
| 报销单与到账 | 交易关联、总览待收或未来事项 | V15Reimbursement 保留报销单、回款、预览、作废/恢复和版本检查 |
| 已知未来与现金流计划 | 总览“接下来要付/查看全部” | V15FutureTimeline、V15CashFlow 保留来源核验、创建/编辑/确认入账 |
| 月/年分析、分类明细、导出 | 分析 | V15Reporting 的四透镜、period drill-down、revision 绑定导出完整保留 |
| 账单导入、AI 待确认、AI/OCR 设置、主数据、归档/安全、待同步 | 账户页管理入口的“设置与数据” | V15Settings 及 StatementImport / AIProposal / DataSecurity / Archive；不把治理功能藏成不可达深链 |

## 5. 施工边界与文件职责

- **根与路由**：重构 V151IOSWorkspace.swift、V151MacWorkspace.swift，建立显式的 V2.2 root route/state，负责 Tab、主空间、次级 sheet/全屏页、写入后的受影响事实刷新与返回位置。iOS 不能沿用 BottomKind 自绘栏；Mac 不能沿用“最多四个账户”列表。
- **新阅读层**：在现有 Features/Today、Ledger、Reports 下新增或替换 V2.2 SwiftUI views 与一个只读 overview composition。它在内部维护并校验 facts 与本月 report 的 revision 归属，不能把不同 revision 合成一个事实；用户只看到可理解的更新时间或“请刷新”状态，不暴露工程 revision。若 daily 缺失、报表为空、读失败或离线，去掉曲线并显示相应真实状态，不绘制示例数据。
- **账户空间**：新增原生账户 hub 与 Mac 账户概览 popover，复用 V15LedgerModel.loadReferences、V15AccountDetailModel、主数据/信用服务；完整账户管理继续进 V15MasterDataView，不复制写入逻辑。
- **编辑与专项页**：V15RecordViews、ledger、reports、credit、installment、reimbursement、cash-flow、future、settings 视图按 V2.2 容器、层级、工具栏和错误区改造；各 model、V15Services、contracts 和 Backend 默认不改。全局按钮/字段只在 Gallery 与专项页回归后再更新，避免一次 token 改动破坏安全语义。
- **设计基础与文档**：在 V15DesignTokens / V15Controls 建立可跨端复用的颜色、排版、卡片、财务指标、列表行和状态容器；更新 App/README.md 的旧 TabView 禁令。最后改 App/project.yml 到 2.2.0 / 40，运行 xcodegen。
- 每个异步读取/预览继续使用 generation 所有权；筛选/账户/期间/输入变化立即使派生预览和分页归属失效。iOS 全屏页和 sheet 内必须显示错误；离线只读、冲突、待同步、response-unknown 与幂等恢复不得因新导航而遗漏。

## 6. 里程碑、交付与验收

1. **M0 · 架构落点与原生导航风险消除**：先记录六个 scheme 的逐字备份/hash；建立 V2.2 route contract 和 iOS 原生四 Tab + 有字底部 accessory，接回现有今天/账目/记账，不改变业务写入。同步 RootSmoke fixture 和旧三空间测试。使用既有 iPhone 17 Pro 的 iOS 26.5 模拟器验证触控、VoiceOver 名称、键盘/全屏编辑安全区及 accessory 不被系统收起；它不等同于 iOS 26.0 runtime 实测，部署目标兼容性以 26.0 API 可用性和 generic iOS Simulator 构建保证。
2. **M1 · 共享语言与 Mac 主工作台**：完成深青侧栏、统一账户概览 popover、总览/交易/账户/分析的真实数据布局，迁入近期交易、未来事项、账户上下文和 Mac 快捷键。验收多账户、无交易、有未来事项、加载/失败/离线、窄窗口与深浅模式，以及负账户净额的带符号显示和非溢出差值；账户数量再多也不撑高侧栏。
3. **M2 · iOS 四页与金额优先记账**：把四页换成轻量内容组织，保持原生悬浮栏和底部“记一笔”；完成账户分组/搜索和写入后精准刷新。验收 iPhone 17 Pro 竖屏、动态字体、Reduce Motion/Reduce Transparency、Home Indicator、数字键盘、每种交易类型及编辑取消。
4. **M3 · 全应用专项页重构与入口闭环**：按 3.4 的每个页面家族完成实际 SwiftUI 视觉和交互重构，逐项走完上表入口；保留预览→确认、冲突刷新、未知结果读取和离线禁写。验收报告下钻/导出、账单导入、报销回款、还款和分期关键路径，不能只给旧专项页套容器。
5. **M4 · 全域回归、版本与交付候选**：逐项核对全部可达页面及 sheet/popover/fullScreenCover 的覆盖状态与双端证据，再更新 README、project.yml 到 2.2.0 / 40、必要测试和可复现视觉证据；运行 xcodegen 后只用已保存的六个具体文件恢复受保护 scheme 字节并重新核对 hash，绝不执行泛用 git checkout。至少运行一次完整 FiscalKitTests 与两端必要 RootSmoke，再比较 git diff，确认无 Backend/migration/模拟器/缓存副作用。保留 QA 材料；此里程碑只形成 V2.2.0 build 40 候选，不发布、签名、换包或推送。

## 7. 质量门禁与最大风险

- 每个 SwiftUI 批次必须构建 FiscaliOS 的 generic iOS Simulator App target 与 FiscalmacOS 的 macOS App target；既有 iPhone 17 Pro 只用于 UI 验证。日常只跑受影响测试；业务/模型改动再跑相应 FiscalKitTests，并补路由、指标口径、交易类型切换、generation/preview 失效的有意义测试。M4 跑完整 FiscalKitTests 和两端必要 RootSmoke。Gallery 可提供确定性状态截图，但不能代替正式 App 与真实服务状态的验收。
- 全部构建/测试使用 xcodebuild 的 -jobs 2、串行执行，禁用并行测试与目的地克隆。构建前后记录既有 DerivedData 和 ModuleCache 的目录增量；不新开 DerivedData、不做全局 clean，只清理由本轮明确确认的临时产物。
- 视觉验收以已确认方向图为对照：第一眼能读出钱、债务、月度流动和下一笔要处理的事；Mac 有稳定的账户入口与层级，iOS 有系统原生的四目的地栏及有字底部创建。比较真实内容、空态、失败态、长账户名/大金额/多账户和动态字体，而非按生图像素判定。
- 最大风险是将两套报告 read 的不同 revision 混成一个“净资产”或在无 daily 时伪造曲线，以及原生 tab accessory 与键盘/安全区冲突。M0 和 overview 的内部 revision 归属校验先消除这两点；不能用人工示例数据掩盖。
- 当前状态：M0–M3 代码整合完成，**V2.2.0（40）双端 App target 构建通过**，已核对最终产物版本与最低系统 26.0。完整 FiscalKitTests **408 / 408（39 组）**通过；取得通过结果的不同 UI 用例累计 **43 项**（iOS RootSmoke 11、Mac RootSmoke 9、iOS Gallery 14、Mac Gallery 9；本轮针对性验证 11 项），并完成原生 AppKit 账户输入验证。41 张代表性截图与实际结果见 [验收入口](archive/releases/v2.2.0/qa/README.md)。
- **M4 账户浮层补查完成**：Review 中已在真实隔离根窗口用连续原生按键走通自动焦点、空结果、清空、第五账户选择、回车进入账户上下文及信用浮层 Escape。XCTest 本轮在 automation mode 初始化时超时，未进入用例；整窗人工工具回放与自动测试计数分别记录，见 [REVIEW_EVIDENCE.md](archive/releases/v2.2.0/qa/REVIEW_EVIDENCE.md)。
- M4 修正包括：金额负号/溢出保护、上海当月与跨月测试、同 revision 总览组合、Mac 卡片/安全页布局、iOS 报表整行点击与日序列空态、账户原生焦点与文字说明。现有业务模型、Backend、API/migration 不变。
- 资源收口：复用既有 iPhone 17 Pro / iOS 26.5，没有新增模拟器、runtime 或 DerivedData；当前缓存约 3.0 GiB + 2.4 GiB，磁盘剩余约 53.7 GiB。仅清理本轮中止测试生成的 402.6 MiB 诊断包并保留日志。六个 scheme 的原始 SHA-256 再次全部一致。
- **Review 修复结论**：初次完整 Review 的 8 项 P2、1 项 P3 与 D1 均已修复。涵盖根读取刷新、双端最近交易隔离/重复导航、Mac 待办反馈与来源返回、账户读取状态、iOS 空态/分类引用/AX5 金额，以及离线/待同步说明和首屏待办布局。完整单测 408 项、新增 8 个回归用例与双端 App target 均通过；原发现与修复后证据分别见 [REVIEW.md](archive/releases/v2.2.0/qa/REVIEW.md)、[FIX_REPORT.md](archive/releases/v2.2.0/qa/FIX_REPORT.md)。本轮为针对性修复和主会话复核，未冒充第二次独立全量 Review。
- 下一步：V2.2.0（40）修复候选已收口。用户要求发布时，再按既定发布流程审计相对生产 353c381 的累计差异并执行；目前未提交、推送、发布或换包。恢复时先读本文件、FIX_REPORT、`git status` 与 [修复后源码指纹](archive/releases/v2.2.0/qa/fix-source-manifest.json)。
