# Fiscal · PROJECT_PLAN

> 目标版本：v1.5.2（28）｜更新：2026-08-23（Asia/Shanghai）｜阶段：**RELEASE · Build 28 已签名、换包并发布**

## 1. 当前目标与授权

- 基线为 `main` / tag `v1.5.1` / commit `2f47d4e`，向前修复，不回退 v1.5.1 已完成的业务安全能力。
- v1.5.2 是一次以独立审计为输入的**双端前端设计验收修复**：macOS 与 iPhone 必须忠实落实 `Fiscal 前端设计启动/`，解决 `F151-01` 至 `F151-17`。
- 用户已追加授权 v1.5.2（27）执行 commit、push、签名发布、macOS 换包安装与 Build 27 标签；iOS 安装由用户执行。
- 用户已授权 v1.5.2（28）立即修复 macOS 月份流水范围、增加一个 Build，并执行 commit、tag、push、双端签名发布与 macOS 换包；iOS 安装由用户执行。
- 当前授权不包含：Backend/schema/migration 变更、生产部署、Apple 公证或 TestFlight。

## 2. 权威与审计输入

优先级从高到低：

1. 当前用户指令与本计划。
2. `Fiscal 前端设计启动/Design/00-HANDOFF.md`：语义与冲突裁决。
3. 静态高保真 `.dc.html`：视觉权威。
4. 可点击 iOS/macOS 原型：交互权威。
5. `Fiscal 前端设计启动/Design/06-direction-decision-and-inventory.md`：屏幕和状态覆盖。
6. Backend schema/service 与 V15 typed contracts：事实和可用能力权威。
7. `archive/audits/frontend-audit-v1.5.1-2026-08-22.md`：本轮 17 项缺口的冻结记录。

禁止事项：

- 不把现有 View、Gallery、默认 `NavigationStack` / `Form` / `List` 的外观当作设计权威。
- 不嵌入 HTML/WebView，不以截图或静态假数据冒充正式 UI。
- 不为匹配原型在客户端计算会计真相；后端未提供的数据必须显示真实空态、不可用态或禁用原因。
- 不以“已有模型/按钮/入口”代替视觉与交互验收。

## 3. 冻结的审计问题

完整证据见 `archive/audits/frontend-audit-v1.5.1-2026-08-22.md`。

| 编号 | 等级 | 平台 | 问题 | 归属批次 |
| --- | --- | --- | --- | --- |
| F151-01 | A | Mac | 镜头不是脊柱筛选器，缺归档镜头 | B2 |
| F151-02 | A | iOS | Today 卡缺卡内分类/还款/收款/现金流决定 | B3 |
| F151-03 | A | 双端 | 报表缺权威构图 | B4 |
| F151-04 | A | 双端 | 系统与数据、设置覆盖不完整 | B5 |
| F151-05 | A | 双端 | 通用账户详情与独立待同步队列缺失 | B2、B3 |
| F151-06 | A | 双端 | Dynamic Type AX5 未落地 | B1、B6 |
| F151-07 | B | 双端 | 归档视觉语法未全局贯彻 | B1、B2、B5 |
| F151-08 | B | 双端 | 离线乐观值缺真值标注 | B1、B2、B3 |
| F151-09 | B | 双端 | 冲突缺字段级新旧对照 | B1、B3、B5 |
| F151-10 | B | 双端 | 账单导入信息结构偏通用 | B5 |
| F151-11 | B | 双端 | 重型业务页缺对象专属构图 | B5 |
| F151-12 | B | 双端 | 加载态和原生控件破坏统一语言 | B1、B4、B5 |
| F151-13 | B | 双端 | 量值被错误表现为收支 | B1、B2、B4 |
| F151-14 | C | iOS | 重型入口隐藏且集合不一致 | B3 |
| F151-15 | C | iOS | 底栏图标、徽标、交易详情偏占位 | B3 |
| F151-16 | C | 双端 | 启动门状态与信息不完整 | B5 |
| F151-17 | C | Mac | 窄窗口比例失衡 | B2、B6 |

## 4. 不可回退契约

- `preview ≠ commit`：预览和提交是两次决定，输入变化立即作废服务器预览。
- 冲突必须接管当前决策面，展示旧/新事实并重新预览；不静默覆盖。
- provisional、AI、未来、导入、待同步不伪装成 fact：yellow 左条、虚线/形状和文字三重冗余。
- archive 不等于 delete：灰度、45°斜纹、“归档 · 只读”和恢复入口。
- 部分成功必须说明做成什么、现在是什么、还剩什么。
- CNY 金额只走 `CNYAmountParser`；业务日期和用户可见导出日期使用 `Asia/Shanghai`。
- 保留 typed services、现有 Model、幂等键、离线写入白名单、generation/token 竞态守卫和错误展示链路。
- iPhone 底部只保留今日、中央记一笔、账目；macOS 维持单窗口索引/脊柱/检查器和接管模式。

## 5. 施工计划

### B0 · 基线与验收夹具 — completed

- 冻结 v1.5.1 审计为 `F151-01` 至 `F151-17`。
- 保留 v1.5.1 计划摘要和发布证据，不重写历史。
- 确定版本目标 `1.5.2 (26)`；版本号只在功能与验证收口时修改。
- 后续每个批次开始前先对照对应高保真和可点击原型；完成后保存不含私人财务数据的合成 QA 图。

### B1–B6 · 已完成

- B1 共享状态、归档/离线真值、语义字体与 AX5；B2 Mac 七镜头、账户与显式 PendingWrites；B3 iOS Today/账目原位决定；B4 双端报表与钻取；B5 重型工作区、设置/系统/启动门；B6 视觉 QA、版本与门禁均已完成。
- 历史验收、视觉矩阵、测试和能力边界见 `archive/audits/v1.5.2-build-gap-register.md` 与 `archive/releases/v1.5.2/RELEASE_STATE.md`；后端能力限制不得按前端完成处理。

### B7 · v1.5.2 独立复审修复 — completed

所有权：正式 iOS/macOS 根壳、共享状态组件、Ledger/PendingWrites、MasterData、DataSecurity、StatementImport 及其针对性测试；不改 Backend，不签名、不安装、不 commit/tag/push。

- 让正式 `V151IOSWorkspace` 接入语义字体、AX5 重排与正式根壳视觉验证；不得用 Gallery 的另一套 Today View 代替验收。
- 成功、读回确认、未知/仅展示与归档使用各自状态组件；成功凭证不得再显示或朗读为“归档 · 只读”。
- 分类决定不得把本地摘要冒充服务器预览；当前 Backend 无独立 preview 契约时，展示服务器当前事实和明确能力限制，并更新能力登记。
- 冲突必须保留接管态直至用户显式读取；对可 fresh GET 的对象计算并展示真实旧值/新值，不使用“预览时版本/服务器最新版本”等占位值。
- 口令服务端已修改但本机凭证保存失败时进入不可重提的终态、清空输入并要求使用新口令重新解锁。
- 系统与设置的每次读取只按本轮结果决定 loaded/failed；失败不得把上一轮值伪装为实时事实，若保留旧值必须带陈旧时间和错误标记。
- 待同步统一采用 B2 冻结的显式同步语义；移除 Mac 启动静默 replay，冲突/结果不明继续禁止自动重放。
- Mac 账单导入同凭证恢复补齐离线/仅展示门禁与可见原因；与 iOS 行为对称。
- Mac 月份报表读取增加 generation/owner 守卫，旧月份响应不得覆盖当前月份。
- 清理正式主路径残留的无语义 `ProgressView`、默认 `Form` 和不受控 bordered 控件，使用 Fiscal 骨架与控件语法。
- 为上述路径补模型/组件/正式根壳测试；至少覆盖二次读取失败、access key 保存失败、普通主数据冲突、Mac 月份竞态、双端 PendingWrites 与状态组件语义。

完成门：已通过 r7。业务量级正式 root fixture 为请求月份返回完整 `Asia/Shanghai` 月报，iPhone 13（390×844）浅色、深色、AX5 三图均有服务器月支出数值；独立 F2-A `Int64.max` root 夹具证明金额仅在局部横滚而不撑宽整页，三个底栏动作仍可触达。两处未保留快照的伪字段差异已移除。`FiscalKitTests` 393/393 通过，正式 root UI 2/2 通过，iOS/macOS Debug 与无签名 Release 均通过；证据见版本记录。

### B8 · 用户语言快修（Build 27）— completed

- 双端正式界面从用户任务出发重写导航、标题、说明、状态、按钮和错误提示；移除“脊柱、检查器、工作台、工作区、权威、服务端、读回”等工程视角词汇。
- 不再向用户展示数据修订号、对象版本号、操作编号、请求键/请求体、哈希、内部状态码、原因码、提案版本和原始枚举值。
- 删除要求用户手填交易 UUID 的商户关联入口，以及“现有消费转分期”的手工交易 ID 入口；保留正常的新消费分期流程。
- AI 记账改为“待确认内容—检查并修改—确认记账”的用户流程；移除质量诊断、审核字段、原始错误码和内部执行结果。
- 账单导入、报表、分期、报销、现金流、核对、设置与系统页面改用用户可理解的结果、下一步和恢复说明；内部 typed contract、版本校验、幂等、竞态与安全防护继续保留。
- 完整问题与删改清单见 `archive/audits/v1.5.2-build27-user-language-quickfix-2026-08-23.md`。

完成门：`FiscalKitTests` 393/393（40 suites）通过；iOS/macOS App target 和最终签名 Release 均构建通过；用户可见敏感工程词扫描仅剩协议字段、内部状态映射、临时文件名和 accessibility identifier，未作为正文呈现；打包前后严格验签和 SHA-256 校验通过。

### B9 · macOS 月份流水范围快修（Build 28）— completed

- 按可点击 macOS 原型恢复 `全部` 为流水页默认镜头；`未分类` 保持独立筛选，不再代替主流水。
- 初次进入与月份切换都使用 Asia/Shanghai 月份边界；点击月份会清除旧账户、归档和镜头范围，显示该月全部流水。
- 当前/未来段只在当前月份的 `全部` 镜头显示；历史月份与未分类镜头不再混入当前日期或未来事项。
- 增加“该月有分类流水、未分类为 0”的查询夹具回归，证明主流水不会被未分类计数错误清空。
- 完整记录见 `archive/audits/v1.5.2-build28-macos-ledger-scope-quickfix-2026-08-23.md`。

完成门：定向回归 5/5；`FiscalKitTests` 396/396（41 suites）；iOS/macOS App target 与最终签名 Release 全部构建通过；双端成品均核验为 `1.5.2 (28)`，解包后严格验签及 SHA-256 校验通过；macOS 已备份 Build 27、换包并成功启动。

## 6. 验收矩阵

| 门 | 必须满足 |
| --- | --- |
| 语义 | preview、conflict、provisional、archive、partial success 五条规则逐屏成立 |
| macOS 主壳 | `全部` 主流水 + 七个专用镜头真实收敛账目区；右侧详情不断链；1000pt 可用 |
| iPhone Today | 四类决定均可卡内完成；冲突和错误不离开当前卡 |
| 页面覆盖 | i-01 至 i-17、m-01 至 m-10 均有正式入口和关键状态 |
| 报表 | 四镜头、七 neutral 口径、专用构图和真实钻取 |
| 离线 | 服务器确认值、本地乐观值、待同步数和同步凭证同时可见 |
| 归档 | 斜纹、灰度、只读标签、恢复入口同时存在 |
| 可访问性 | iPhone AX5 无截断；金额不换行；禁用原因可见；触达达标 |
| 视觉 | 浅/深色令牌一致，无系统蓝、无不受控 Form/List/Material |
| 工程 | iOS App、macOS App、FiscalKitTests 全部通过，工作区无无关改动 |

## 7. 执行纪律

- 每次只推进一个可验证批次；批次开始前确认 `git status`，结束后记录 changed files、验证结果和未完成编号。
- 新增或删除 Swift 源文件、修改 `App/project.yml` 后执行 `cd App && xcodegen generate`；仅 View 内容变化不提前重生成工程。
- 双端共享语义先在 B1 完成，不在各业务页复制冲突、归档、离线或 AX5 逻辑。
- 修改一端时按项目规则扫描另一端同类点，尤其 selection 收敛、预览失效、错误横幅和 generation 竞态。
- 若后端不提供参考要求的事实，先记录为明确 blocker；未经用户授权不扩展 Backend。
- 不使用真实财务数据做仓库内快照，不输出或提交私人余额。

## 8. 当前状态与下一动作

- PLAN 已完成：v1.5.1 审计已归档，17 项问题均已映射到 B1–B6 和验收矩阵。
- B1 已完成：共享字体/AX5、归档斜纹、字段级冲突、离线真值和最终几何骨架已通过双端编译及定向测试。
- B2 已完成：macOS 七镜头、待同步显式提交、通用账户检查器、归档只读/恢复与窄窗口比例已接入，macOS App target 编译通过。
- B3 前端施工已完成：iPhone Today 原位决策、账户详情、完整待同步队列、重活入口与底栏/详情层级均已接入；四项后端能力边界已单独登记。
- B4 已完成：双端报表四镜头、七 neutral 口径、单窗口/全屏钻取、真实导出与全状态语法均已接入；四项报表事实能力边界已单独登记。
- B5 已完成：账单导入、七类重型业务对象、系统与数据、设置和启动门均已按真实服务能力收口；能力缺口 CAP-152-09 已登记。
- B6 的既有收口证据保留；B7 r7 已完成正式根壳正常态、F2-A 极值局部滚动与伪字段差异复验。剩余只是不扩展 Backend 的 CAP-152 能力边界。
- v1.5.2（26）的源码、审计证据、签名 Release 产物和本地安装历史保持不变，见 `archive/releases/v1.5.2/RELEASE_STATE.md`。
- 用户语言快修已在 v1.5.2（27）源码完成并通过双端签名构建与 393 项测试；源码提交 `8a25baa` 已推送至 `origin/main`。
- Build 27 的 macOS Developer ID 包与 iOS Development IPA 均已严格验签；macOS 已备份 Build 26、换包为 Build 27 并成功启动，iOS 安装继续由用户执行。
- 产物、SHA-256、回滚备份、标签与最终 Git 状态见 `archive/releases/v1.5.2/RELEASE_STATE.md`。
- Build 28 的月份流水范围快修源码已提交并推送；双端签名成品、哈希、回滚备份与本地安装证据已写入 `archive/releases/v1.5.2/RELEASE_STATE.md`。
- macOS 已运行 v1.5.2（28），原 Build 27 保留在 `/Applications/Fiscal-v1.5.2-build27-backup-20260823-1446.app`；iOS Development IPA 由用户安装。
- 不移动既有 `v1.5.2`（Build 26）标签；Build 28 使用独立不可变标签 `v1.5.2-build28`。
