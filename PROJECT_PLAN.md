# Fiscal · PROJECT_PLAN

> 控制面版本：v1.5.1 ｜ 更新：2026-08-22（Asia/Shanghai）｜ 状态：**Review 已通过；macOS 发布链已获授权并执行中。**

## 1. 本轮目标

- 基于当前 `main` / v1.5.0 源码前向补救，不回退、不恢复旧 View。
- v1.5.1 是一次**仅前端**的视觉与交互还原：iPhone 与 Mac 必须忠实实现 `Fiscal 前端设计启动/` 中的参考原型，不能再把原型解释成另一套通用 SwiftUI 产品。
- 保留已经完成的 typed services、业务状态模型、认证、金额、时区、离线只读、并发与写入安全边界；只改变 SwiftUI 组合、导航、布局、排版、颜色、控件、状态表面和展示映射。
- Plan + Build 与三轮 Review 已完成；用户现已授权修复最后一个 P2 后执行 macOS 签名、换包安装、Tag 与 GitHub 推送，不做 Apple 公证或 iOS/TestFlight。

## 2. 权威顺序

1. 当前用户指令：前端与参考原型一致；本轮仅 Plan + Build。
2. `Fiscal 前端设计启动/Design/00-HANDOFF.md`：可点击原型是行为权威，静态高保真是视觉权威，设计文档是语义规则权威；冲突按其 §4 已冻结判断处理。
3. 高保真文件：`Fiscal macOS 高保真.dc.html`、`Fiscal iOS 高保真.dc.html` 及导入、报销/分期、对账/启动门/系统、报表/钻取、现金流/AI/主数据/安全、深色模式和大字号稿。
4. 可点击文件：`Fiscal 交互原型 macOS.dc.html`、`Fiscal 交互原型 iOS.dc.html`。
5. 当前 Backend schema/service 与 V15 typed contracts：只提供事实，不为视觉方便改接口或伪造数据。

禁止把既有 V15 Gallery、默认 `NavigationSplitView` / `List` 外观、通用大卡片或系统蓝色强调色当成设计权威。禁止嵌入 HTML/WebView。

## 3. 不可变产品语法

- 白/纸色是已确认事实底座；teal `#0C5A5B` 是需要决定、主动作和已提交；yellow `#FCD668` 是未定、预览、提议和陈旧。
- 浅色：paper `#FFFFFF`、raised `#FAF9F6`、canvas `#F4F2EC`、ink `#14201F`、expense/debt `#8A6A12`。深色按原型重新配比，不做简单反色。
- `preview ≠ commit`；冲突接管整面并要求重新决定；provisional 不得伪装成 fact；archive 不等于 delete；部分成功必须说明已完成、当前状态与剩余项。
- 金额使用等宽数字、按列右对齐；收入带 `+` 且 teal，支出/欠款带 `−` 且金色，余额与量值使用中性墨色。
- 客户端不自算会计真相。没有后端事实的参考文案只能作为布局占位，不进入正式 live 数据路径。

## 4. 平台实现契约

### 4.1 macOS

- 设计基准 1440×900，窗口最小宽度 1000pt；自绘三栏，不使用系统默认 split/list 视觉。
- 顶栏：交通灯留白、`Fiscal`、期间与条数、密度菜单、搜索入口。
- 左栏约 256pt：镜头计数、时间、账户、归档/报表/系统与数据/设置；紧凑 13–15pt 排版，中性色选中面，teal 只用于“需要决定”的语义。
- 中栏是账簿脊柱：未来 yellow 段、今天 teal 分隔、过去事实行、归档斜纹；行高、日期列、摘要列、金额列与键盘提示按原型。
- 右栏约 320pt：检查器、字段、来源链、账本影响、修订历史和底部动作；单选随脊柱选择，多选切换批量操作面。
- 账单导入、报表钻取、系统与数据使用单窗口接管，保留返回脊柱出口，不开新窗口。

### 4.2 iPhone

- 设计基准 390×844，只做 iPhone，不为 iPad 预留分栏。
- 主表面是“今日”决策台：34pt 标题、更新时间、账户价值主数字、信用欠款/本月支出/未收报销三数、决策卡队列。
- 底部只保留今日、中央 teal 录入按钮、账目；不使用默认四 Tab 产品架构。
- 离线条、待同步队列、卡内分类/还款/收款/现金流决定、冲突接管和凭证翻面按可点击原型。
- “账目”以搜索优先的手机脊柱呈现；交易详情、账户/信用/分期/报销/现金流为次级面；录入、报表、导入、对账为全屏模态。

## 5. Build 分块

### B1 · 精确设计系统与状态表面 ✅

所有权：`App/Sources/FiscalKit/V15/DesignSystem/**`、`Shared/State/**`、必要的展示格式器。

- 用原型数值重建颜色、字体、间距、描边、圆角、阴影、斜纹、金额、来源标记、按钮、字段、预览、冲突、凭证、离线和空/错/加载表面。
- 去掉系统蓝色、夸张大卡片、过度圆角和不受控 `Form/List` 默认样式。

### B2 · macOS 主窗口 ✅

所有权：`V15/AppShell`、`Features/Ledger/**`、`Features/Today/macOS/**` 及新的 macOS-only 展示组件。

- 完成顶栏、索引、脊柱、检查器、多选批量面和键盘/密度状态。
- 用现有 ledger/detail/history/provenance/capability 数据驱动，不能以静态合成内容代替 live 列表。

### B3 · macOS 接管工作区 ✅

所有权：现有 macOS Reports、StatementImport、Reconciliation、DataSecurity、MasterData、CashFlow、AI、Credit、Installments、Reimbursements、Timeline View。

- 按对应高保真稿统一为接管式工作区；保留业务 Model 与真实服务调用，只重排和重绘。

### B4 · iPhone 主壳与日常流 ✅

所有权：`V15/AppShell`、`Today/iOS`、`Ledger`、`Record`、Bootstrap 及新的 iOS-only 展示组件。

- 完成今日决策台、离线/待同步、底部三入口、录入、搜索账目、详情和卡内处理。

### B5 · iPhone 重活与详情 ✅

所有权：现有 iOS Reports、StatementImport、Reconciliation、DataSecurity、MasterData、CashFlow、AI、Credit、Installments、Reimbursements、Timeline View。

- 按参考稿统一全屏层级、预览、冲突、凭证、归档和危险操作，不改变业务语义。

### B6 · 深色、大字号与版本收口 ✅

- 深色令牌按 `Fiscal 深色模式.dc.html`；Dynamic Type 按“元信息换行 → 按钮纵向 → 固定高度变最小高度 → 图标顶对齐”，金额不换行。
- 版本升至 `1.5.1 (25)`；只整理 v1.5.1 前端相关工作区，不生成包、tag、push 或部署。

## 6. Build 完成门

本轮不做 Independent Review。Builder 只做以下必要自检，避免再次用验证替代施工：

1. 改源清单时才运行 `xcodegen generate`。
2. 完成后只运行 iOS Simulator 与 macOS App target 的编译检查；不跑全量测试、长 UI 自动化、发布签名或生产验证。
3. 逐屏用原型作视觉基线，确认主结构、栏宽、密度、排版、颜色、关键状态和交互路径已落入正式 live root。
4. `git diff` 只能包含 v1.5.1 前端、版本和本计划相关改动；Backend、migration、生产配置不得变化。
5. 完成 Build 后向用户报告改动与仍需人工观察的视觉点，然后停止，等待用户明确放行 Review。

## 7. Build 收口记录

- 正式 live root 已切换为原型结构：macOS 使用自绘顶栏 + 索引 + 账簿脊柱 + 检查器；iPhone 使用“今日 + 中央录入 + 账目”三入口。
- 原有业务 Model、typed services 与安全边界继续复用；重活工作区由正式 root 接管，不嵌入 HTML/WebView，不改 Backend 或 migration。
- 启动门已按参考稿重绘，并阻止正式包从 QA 环境变量覆盖生产 Keychain access key。
- 版本已落为 `1.5.1 (25)`；正式 iOS 目标收窄为 iPhone 竖屏；macOS 默认窗口为 1440×900。
- 已重新生成 Xcode 工程；macOS App target 与 iOS Simulator App target 的 Debug 短编译均通过。
- 用户放行的首轮 Review 已完成，并发现 10 个前端行为阻断项；随后只针对这些阻断项返工，没有扩展后端或发布范围。
- 未运行全量测试、长 UI 自动化、发布签名、打包、tag、push 或部署。

## 8. Review 修复收口

- 未知分类写入不再无条件显示成功；只有读回分类与目标一致才确认完成。
- macOS 已补正式“记一笔”/`⌘N`、复选与 Shift 多选、批量分类预览、部分失败结果、`j/k/空格/⌘↩` 实际快捷动作。
- 待同步队列改为真实持久化 outbox：离线录入与分类决定可入队，双端显示数量、状态、重试/移除与同步回执；未知结果不自动重放。
- macOS 月份切换同时驱动列表期间、顶栏期间和月报；Today 月报失败显示“暂不可用”，不再伪造为 0。
- iPhone “选择分类”定位到对应账目并经过预览确认；“稍后”会从当前决策队列移出；其他卡片按来源进入对应工作区。
- macOS 决策项按来源路由，不再把所有 source ID 当作交易 ID；作废/恢复、加入报销、改为分期均显示能力禁用原因。
- 报表正式表面收敛为总览、支出、现金流、债务四个产品镜头，并提供七种支出口径；旧技术维度只保留模型兼容，不再出现在镜头选择器。
- 已再次运行 `xcodegen generate`；iOS Simulator 与 macOS App target 的 Debug 短编译均通过。
- 第二轮 Review 的四项问题已收口：iPhone 分类改为详情 Sheet 内的预览/确认流程；两端 attention 对后端全部已知 `source_type` 精确路由，系统异常与未知类型安全进入系统与数据；macOS 批量分类数量恢复真实字符串插值；iPhone 失败待同步项目在重试后立即重放。
- 本轮未新增源文件，未重跑 xcodegen；iOS Simulator 与 macOS App target 的 Debug 短编译均再次通过。

## 9. 当前下一步

- 最终 Review 无 P0/P1，允许进入发布收口；最后一个 Sheet 生命周期 P2 已在打包前修复。
- 从干净的 v1.5.1 源码提交生成 Developer ID 签名 macOS 包，严格验签后替换 `/Applications/Fiscal.app` 并做最小启动检查。
- 写入最终发布记录，创建 annotated `v1.5.1` Tag，并推送 `main` 与 Tag 到 `origin`；不做 Apple 公证、iOS/TestFlight 或 Backend 部署。
