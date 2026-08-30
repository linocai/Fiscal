# Fiscal · PROJECT_PLAN

> 目标版本：v1.5.5（32，不改版本）｜更新：2026-08-30（Asia/Shanghai）｜阶段：**NB MIGRATION · COMPLETE**

## 1. 当前目标与授权

- 用户已授权立即把 **Fiscal 自身全部生产组件**从杭州云 `118.178.122.194` 迁移到宁波云 `114.66.2.205`；本轮不修改 App 版本号或 Build。
- 范围只包含 Fiscal API、生产 PostgreSQL 数据库、运行密钥、系统账户、发布与回滚包、备份/恢复状态、健康/磁盘/通知任务、`fiscal.linotsai.top` 的 NPM/TLS/DNS 入口及杭州端 Fiscal 专属清理。LinoFinance、YiCoffee、主页、小燃、Neckline、ICTW 和共享主机上的其他项目全部排除。
- 用户明确取消 48–72 小时观察期：宁波切流后完成当场数据库、服务、公网和双端验收；全部通过即清理杭州 Fiscal 专属组件。仍必须保留最终可恢复备份和单写者边界，不能用“无观察期”省略验收或回滚材料。
- Fiscal 生产已完整切换到宁波：公网 DNS、NPM/TLS、PostgreSQL、API、四个运维 timer 与双端真实客户端验收全部通过；杭州 Fiscal 专属服务、数据库、入口、证书、身份和活动目录已清除。
- 宁波 `deploy` 的既有管理员路径已验证可用；迁移全程未把管理员密码、设备密钥、数据库秘密或财务原文写入仓库、日志摘要或验收记录。
- 本次迁移的宁波生产 revision 为 `3eb49cbc4151aa06b0dacecc7025ad2ed7d85f42`；后续提交只补充迁移交接与验收记录，不改变 v1.5.5（32）运行代码或数据库 head。
- 用户已授权 v1.5.5（31）进入 PLAN → BUILD 一条龙：修复未记账 AI 待处理内容不能删除，以及 AI 上游失败原因被压成模糊“暂时不可用”的问题；macOS、iOS 与 Backend 同步收口。
- 本轮授权包含实现、测试、双端构建、复核、commit、tag、push 与签名发布包准备；明确停在生产 Backend 部署和 macOS 安装换包之前。Apple 公证、TestFlight 与 iOS 安装不在本轮执行范围。
- 用户已指定 v1.5.4（30）只修复 `REC-154-01`：macOS 核对页在账户切换和诊断加载后把实际余额输入与保存入口挤出可视区域，造成界面看似失效。
- 本轮 BUILD 已授权并完成；commit、tag、push、签名发布与安装换包须等待用户后续指令。版本配置与双端构建产物均已更新并核验为 `1.5.4 (30)`。
- 基线为 `main` / tag `v1.5.1` / commit `2f47d4e`，向前修复，不回退 v1.5.1 已完成的业务安全能力。
- v1.5.2 是一次以独立审计为输入的**双端前端设计验收修复**：macOS 与 iPhone 必须忠实落实 `Fiscal 前端设计启动/`，解决 `F151-01` 至 `F151-17`。
- 用户已追加授权 v1.5.2（27）执行 commit、push、签名发布、macOS 换包安装与 Build 27 标签；iOS 安装由用户执行。
- 用户已授权 v1.5.2（28）立即修复 macOS 月份流水范围、增加一个 Build，并执行 commit、tag、push、双端签名发布与 macOS 换包；iOS 安装由用户执行。
- 用户已指定 v1.5.3（29）修复 `NEXT-01` 至 `NEXT-04`，并授权完成 BUILD、提交、标签、推送、双端签名与 macOS 换包；iOS 安装由用户执行。
- v1.5.2 审计修复当时不包含 Backend/schema/migration 变更；本轮 v1.5.5 已明确授权 Backend 契约与线性 migration，但仍不包含生产部署、Apple 公证或 TestFlight。

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

### B10 · v1.5.3 双端交互修复（Build 29）— completed

#### NEXT-03 · P0 · 保存成功后旧草稿可被重复提交

- 现象：用户点击“保存账目”并成功后，金额、名称、备注、账户和分类仍留在输入框中，“保存账目”也可再次触发；误触第二次会用同一内容创建重复账目，迫使用户再作废其中一笔。
- 根因：`V15RecordModel.submit()` 成功分支只写入 `.success(created)`，没有结束当前草稿会话或清空输入；视图仍常驻保存按钮，模型入口也没有拒绝 `.submitting`、`.success` 或 `.queued` 状态的再次提交。成功后释放旧幂等键，使第二次点击可能取得新键并成为新的合法创建请求。
- 修复范围：在线保存确认成功后立即结束旧草稿会话，清空金额、名称、备注、来源账户、目标账户、分类和账期，回到一张不可提交的空白新表单；成功凭证独立保留，不得因清空输入而消失。离线成功入队后采用同样的一次性草稿规则，但继续明确余额尚未获得服务器确认。
- 防重门禁：提交入口在模型层必须非重入；请求处理中、已成功或已入队的同一草稿拒绝再次提交，不能只依赖按钮来不及刷新的禁用外观。失败、冲突和结果不明时保留输入与原幂等语义，允许安全重试但不得生成重复账目。
- 双端范围：macOS 与 iOS 共用同一模型规则；连续录入只能从新的空白草稿开始，并与 `NEXT-01` 的成功后账户/流水事实刷新链路在同一个提交完成事件中触发。
- 验收：快速双击保存只产生一笔账目；成功返回后旧字段立即清空且保存按钮不可用；失败或结果不明时字段不丢失；点击“录入下一笔”和直接继续填写都只产生一个新草稿；补在线、离线、并发双击、成功后二次点击及安全重试的模型回归，并覆盖双端正式录入视图。

#### NEXT-01 · 记账后账户余额跨界面未同步

- 现象：macOS 成功录入账目后，账户详情通过单账户读取显示新余额，但左侧账户边栏仍显示录入前余额；退出并重新打开 App 后才一致。
- 根因：边栏绑定 `V15LedgerModel.accounts` 的引用快照；录入成功没有向正式根工作区发送账户事实失效信号，返回账目只切换页面，`ledger.load()` 也只刷新流水而不刷新账户引用。
- 修复范围：建立记账成功后的统一失效/刷新链路，至少刷新账户列表、当前月份流水、Today/汇总事实和当前已选账户详情；检查 iOS 同类入口以及转账、还款等同时影响多个账户的写入路径，不得只修普通支出。
- 离线边界：加入待同步时不得把未获服务器确认的余额伪装成最终余额；同步确认后再触发同一刷新链路。
- 验收：普通收入/支出保存后无需重启即可看到边栏与账户详情余额一致；转账和还款的来源、目标账户同时更新；返回账目与连续录入均不残留旧快照；补模型及正式 macOS 根壳回归测试。

#### NEXT-02 · macOS“记一笔”重复左栏挤压录入区

- 现象：进入“记一笔”后，右侧已经直接显示完整录入表单，左侧仍用大面积重复展示页面介绍和“新建账目”按钮，造成主要输入区被压缩到固定窄栏。
- 根因：macOS 复用了“先展示入口、再打开编辑器”的两阶段构图，但桌面端同时把编辑器常驻在同一页面；重复入口失去任务价值，`V15RecordEditor` 又被固定为 420pt 宽。
- 修复范围：移除 macOS 录入页左侧介绍区、重复“新建账目”按钮和无意义分隔线；以录入明细为唯一主内容，使用整个可用工作区，并在内容内部保持合理的表单阅读宽度与自适应留白。
- 保留内容：顶部“返回账目”、录入字段、校验提示、保存结果和“继续录入”流程保持在同一主内容区；不得改变 iOS sheet 的既有交互。
- 验收：1000pt 最小窗口与常用宽窗口下均不再出现重复入口或空置半屏；全部字段、错误提示和保存操作无需横向滚动且视觉焦点落在录入任务上；补正式 macOS 录入根视图的布局回归测试。

#### NEXT-04 · 账户流水未按当前账户视角表达双边交易

- 现象：用户点击“花呗”查看账户流水时，一笔同时涉及“杭联0519 → 花呗”的还款只显示“杭联0519”和负金额，视觉上像无关账户的支出混入花呗流水。
- 根因：后台账户筛选正确地按所有 `Posting.account_id` 查找受影响账目，但 macOS 流水行只展示 `transaction.accountID` 的来源账户名称；金额方向也按交易类型统一决定，没有读取当前所选账户对应 posting 的金额与角色。
- 修复范围：保留“任一分录涉及该账户即进入账户流水”的正确查询语义；账户筛选激活时，双边交易明确显示“来源账户 → 目标账户”，并以当前账户对应分录表达流入、流出、欠款增加或欠款减少。普通单账户收支继续保持简洁。
- 双端范围：扫描 macOS、iOS 账户流水、账户详情与报表钻取的同类行，不得出现同一交易在不同入口使用相互矛盾的账户方向；无账户筛选的全部流水仍可使用全局交易视角。
- 验收：还款在来源账户显示资金流出、在信用目标账户显示欠款减少；转账在来源与目标账户分别显示流出和流入；行内能够同时识别双方账户；金额来自当前账户 posting 而不是仅由交易 kind 推导；补收入、支出、转账、还款及信用消费的账户视角回归测试。

#### 双端审计结论

| Backlog | macOS | iOS | 计划裁决 |
| --- | --- | --- | --- |
| `NEXT-03` 重复提交 | 已确认：成功后保留有效旧草稿，模型允许再次提交 | 已确认：共用 `V15RecordModel`，同样受影响 | 共享模型先修，双端不得各自补按钮防抖 |
| `NEXT-01` 余额刷新 | 已确认：根工作区的账户引用、流水、Today 与月报没有收到录入成功事件 | 已确认：录入 full-screen cover 没有完成回调，Today、账目和账户卡不会主动刷新 | 建立 typed 完成事件；仅服务器确认成功触发事实刷新 |
| `NEXT-02` 录入构图 | 已确认：重复左栏 + 右侧固定 420pt 编辑器 | 不存在：iOS 已是单一全屏编辑器 | 仅改 macOS 布局，保持 iOS 交互不变 |
| `NEXT-04` 账户视角 | 已确认：行内只显示来源账户，金额按交易 kind 表达 | 已确认：正式 iOS 账目行和详情使用同一错误表达 | 共享 posting 驱动的展示策略，双端复用 |

#### B10-A · P0 录入会话与防重复提交

所有权：`V15RecordModel.swift`、`V15RecordViews.swift`、`F1ATests.swift`。

- 引入 typed 录入完成结果，区分服务器确认成功与离线已入队；视图只在模型返回一次性完成结果时通知宿主。
- 模型提交入口增加非重入守卫；`.submitting`、同一草稿已确认或已入队时不再创建第二个请求，不能依赖 SwiftUI 按钮刷新速度。
- 将成功凭证与当前草稿状态分离。确认成功或入队后原草稿立即结束并清空业务字段，空白新草稿因本地校验而不可提交；成功凭证继续可见。
- 确定性失败、冲突和结果不明保留输入；结果不明重试继续复用原 payload-bound 幂等键，编辑后才换键。
- 回归至少覆盖：并发快速双击只发一个 POST、成功后再次点击零 POST、成功/入队清空、失败不清空、unknown 同键安全重试、下一笔新键。

#### B10-B · 录入完成后的双端事实失效链路

所有权：`V151MacWorkspace.swift`、`V151IOSWorkspace.swift` 及正式根壳测试。

- macOS 接收确认成功事件后并发刷新账户引用、当前筛选流水、Today facts、当前月报；若仍有选中账户，再读取该账户详情。所有异步写回继续使用既有 generation 守卫。
- iOS 根工作区持有录入事实 revision；确认成功时让当前 Today 或账目页面刷新，并保证随后切换到另一页时也读取新 revision。账目刷新同时包含账户引用和当前筛选列表；打开中的账户详情按 revision 重读。
- 离线入队不刷新为服务器余额，只更新待同步语义；同步真正确认后的刷新仍走同一个 typed 失效入口。
- 回归至少覆盖：普通收入/支出、转账、还款分别刷新受影响账户；Mac 边栏与详情一致；iOS 账户卡、账目和 Today 不需重启；旧异步响应不得覆盖新 revision。

#### B10-C · posting 驱动的当前账户流水表达

所有权：Ledger 共享展示策略、`V151MacWorkspace.swift`、`V151IOSWorkspace.swift`、`V15LedgerViews.swift`、`F1BTests.swift`。

- 新增共享、纯函数的账户流水展示策略，以 `transaction.postings`、当前筛选账户、账户类型及来源/目标账户生成标题补充、金额和语义方向；不修改 Backend 查询语义，也不从余额反推分录。
- 有账户筛选时，转账和还款显示“来源 → 目标”；金额取当前账户 posting。信用目标的正向还款表达为“欠款减少”，信用消费表达为“欠款增加”。
- 无账户筛选时保留全局交易视角；若服务端异常缺少当前账户 posting，显示明确不可判定状态，不回退成错误的来源账户支出。
- macOS 与 iOS 正式流水行和详情共用策略；检查报表钻取是否具备同一 posting 上下文，无上下文时保持报表事实口径，不伪造账户方向。
- 回归矩阵覆盖单账户收入/支出、现金账户转账两端、借记账户还款端、信用账户还款端、信用消费、缺失 posting 防护。

#### B10-D · macOS 单一录入主内容区

所有权：`V15RecordViews.swift` 与 macOS 录入布局验收。

- 删除 macOS 左侧重复介绍、“新建账目”按钮和分隔线；正式页面只保留一个录入编辑器主内容区。
- 移除 420pt 固定右栏。编辑器占满工作区，字段容器使用可读宽度和响应式留白；1000pt 最小窗口不得截断，宽窗口不得再空置半屏。
- 保存凭证、错误和下一笔输入继续位于同一内容流；iOS full-screen/sheet 分支不得发生视觉或交互回退。
- 增加正式 macOS 录入页的最小宽度与常用宽度回归，确认没有重复入口、横向滚动或不可达保存操作。

#### B10-E · 版本、工程门与发布边界

- `MARKETING_VERSION` 已更新为 `1.5.3`、`CURRENT_PROJECT_VERSION` 已更新为 `29`；`xcodegen generate` 已执行，工程差异仅包含版本号与新增共享展示文件。
- F1-A / F1-B 定向门通过：21 项测试覆盖并发双击、成功后二次点击、在线/离线草稿生命周期、安全重试、收入/支出/转账/还款/信用消费的账户分录视角。
- 全量 `FiscalKitTests` 最终复跑通过：401 tests / 41 suites；`FiscaliOS` generic iOS Simulator、`FiscalmacOS` macOS App target 和 macOS Gallery 均构建成功。
- 双端构建产物 Info.plist 均核验为 `1.5.3 (29)`；`git diff --check` 通过。macOS Gallery 实机检查确认单一录入主内容区、保存后字段清空、成功提示保留且空草稿校验不抢占视觉。
- 本批未修改 Backend/schema/migration，未执行 commit、tag、push、发布签名、安装换包、公证或 TestFlight，等待后续明确指令。

### B11 · v1.5.4 核对界面可用性修复（Build 30）— completed

#### REC-154-01 · P0 · 诊断加载后核对操作区消失

- 用户证据：`录屏2026-08-23 18.56.03.mov` 中连续选择账户时，右栏加载骨架较短，实际余额表单会短暂出现；诊断返回后长证据列表插入表单上方，表单与“确认目标/保存核对记录”被推到可视区域之外，用户无法判断下一步。
- 运行核实：录屏时段的账户核对请求均返回 HTTP 200，没有崩溃、超时或写入失败；最终账户与服务端结果一致。问题属于前端信息架构、滚动归属和加载前后几何跳变，不是数据损坏。
- 代码根因：macOS 当前采用“目标列表 / 历史与全局关注事项 / 诊断与表单”三栏；右栏把长诊断放在保存表单之前，选择账户又将编辑步骤重置为第一步，但不会将用户带到被挤出屏幕的操作区。
- 权威裁决：以 `Fiscal 前端设计启动/Fiscal 对账 启动门 系统.dc.html` 为准，恢复“当前目标的核对操作区 / 诊断证据区”两块主要区域。实际余额、账面余额、差异、记录入口和历史检查点属于当前目标；诊断证据独立滚动，不得遮挡或推走主操作。

#### B11-A · macOS 两区核对工作台

所有权：`V15ReconciliationMacView.swift`、必要的共享核对展示组件与 macOS Gallery 场景。

- 将三栏改为两块稳定工作区：左侧为当前核对目标与检查点操作，右侧为诊断证据。账户/信用账期切换收敛为左区顶部的紧凑选择控件，不再占用整条独立脊柱。
- 左区首屏必须始终包含当前目标、账面余额、实际余额输入、核对日期、差异状态和当前步骤主动作；历史检查点置于该区下部的独立滚动区域，不得把主动作推出视口。
- 右区只承载当前目标的诊断证据、空态、加载态和失败恢复；加载骨架与真实长列表只能改变右区内容，不得改变左区表单位置或可达性。
- 全局关注事项不再堆进每个账户的历史栏。核对页只显示能够由 `target.resourceID` 或当前目标检查点明确归属的核对提醒；无法证明属于当前目标的事项留在既有“需要决定”入口，不在此页制造错误关联。
- 未录入实际余额时显示账面事实与待输入状态；录入后直接并排显示实际余额和差异，再进入最终确认。保留“不自动平账”、offline、unknown、conflict、partial refresh 与确定性重试的既有安全语义。
- 1000pt 最小宽度、常用宽窗口、深色和 AX5 下均不得出现主操作被长证据或历史记录遮挡、横向滚动或金额换行。

#### B11-B · 选择、草稿与异步状态收敛

所有权：`V15ReconciliationModel.swift` 与 `F3ETests.swift`。

- 保留并验证现有 selection/diagnosis generation 守卫：快速选择多个账户时，只有最后一次选择可以更新检查点和诊断。
- 切换目标时清理上一目标专属的实际余额、备注、已选检查点、服务端字段错误与编辑确认进度；核对日期保持合法的当前上海业务日期。不得把 A 账户的观察值带到 B 账户。
- 选择加载与写入锁分离：读取新目标时可以继续明确看到目标和只读表单位置，但保存必须等待该目标诊断归属确认；不得让旧诊断与新表单短暂拼接。
- 已进入 unknown、accepted refresh 或提交中的写入继续维持原所有者锁和恢复入口，不以布局重构削弱 keyless write 防重复保护。
- 增加当前目标关联提醒的纯函数筛选，未来未知 `source_type` 不做归属推断，也不因过滤而自动执行忽略。

#### B11-C · iOS 同类问题审计

所有权：`V15ReconciliationView.swift` 与 iOS 核对 Gallery/UI 回归；没有同类问题时不改正式布局。

- iOS 使用独立编辑 sheet，实际余额字段本身位于诊断之前，但审计发现第二步的“下一步”动作仍排在长诊断之后，同样会被 24 条证据推离当前视口；已把诊断移到步骤动作之后，保持既有 sheet 与三步语义不变。
- 覆盖长诊断、AX5、快速切换目标、返回编辑页和错误展示：实际余额输入、下一步/保存按钮必须可达，目标切换后不得保留另一目标草稿。
- iOS 仅实施上述同类可达性的最小对称修复；其他核对设计差距未扩入 v1.5.4。

#### B11-D · 验收、版本与发布边界

- 模型与竞态：定向 `F3ETests` 15/15 通过，新增用例确认切换目标会清空实际余额、备注和确认进度，并只展示可由目标或其检查点证明归属的提醒；既有快速 A→B、旧响应、unknown 与 readback 守卫继续通过。
- macOS UI：F3-E Gallery UI 2/2 通过；长诊断测试实际定位并确认实际余额输入和主动作均可点击。状态矩阵继续覆盖冲突、部分刷新、写入失败与无关提醒过滤。
- iOS UI：F3-E Gallery UI 最终 7/7 通过；另在 iPhone 13 的 AX5 系统字号下定向复跑长诊断用例 1/1 通过，实际余额与“下一步”均存在且可点击。
- 视觉验收：使用 24 条合成诊断分别检查 1000×700 浅色、1180×820 深色、1440×900 浅色与 1440×1080 AX5；四组均保持左侧操作区首屏可达、右侧证据独立增长，无横向滚动或金额换行。截图仅写入临时目录，未包含用户数据或录屏帧。
- 工程门：全量 `FiscalKitTests` 402 tests / 41 suites 通过；`FiscaliOS` generic iOS Simulator、`FiscalmacOS` macOS target、`V15GallerySnapshotTool` 均构建成功；`git diff --check` 通过。
- 版本：`App/project.yml` 已更新为 `MARKETING_VERSION: 1.5.4`、`CURRENT_PROJECT_VERSION: 30` 并执行 `xcodegen generate`；iOS 与 macOS 构建产物 Info.plist 均核验为 `1.5.4 (30)`。
- 发布边界：本批未修改 Backend/schema/migration，尚未执行 commit、tag、push、发布签名、安装换包、公证或 TestFlight，等待复审与后续明确授权。

#### B11 完成定义

- 用户选择任一账户后，无论该账户有 0 笔还是长列表诊断，首屏始终看得到实际余额输入和明确的下一步动作；请求完成前后不发生操作区消失。
- 快速连续点击账户只留下最终账户的目标、账面余额、历史与诊断，不混入旧账户事实；切换账户不会携带上一账户的观察值。
- 当前账户页面不再展示与其无关的 AI 失败、其他账户缺锚点或全局现金流提醒。
- macOS 构图与权威参考的“核对操作 / 诊断证据”主次关系一致；iOS 同类可达性验证通过；版本、测试和双端构建门全部通过后方可宣布 v1.5.4（30）BUILD 完成。

### B12 · v1.5.5 AI 待处理删除与故障可解释性（Build 31）— completed；release prep in progress

#### AI-155-01 · P0 · 误录入的未记账内容无法删除

- 用户事实：AI 待处理页能够查看、修改、确认、忽略或重试，但误录入内容没有删除入口；“忽略”仍保留原文和历史记录，不等于用户要求的删除。
- 根因：Backend 只有 proposal create/get/list/replace/execute/ignore/retry/undo，没有 DELETE 契约；macOS 与 iOS 因而都不存在可绑定的真实删除能力。
- 删除边界：只有从未生成账目或现金流的 `pending`、`failed`、`ignored` 可以真正删除；`processing` 必须等待解析收敛，`executed`/`undone` 必须保留来源链并使用撤销，不允许伪装成可删除。
- 数据语义：删除 proposal 时在同一事务内删除其 AI 质量事件和原始输入，使误录内容不再出现在列表、质量指标或归档导出中；不得删除任何已生成的账目、现金流、账户、分类或学习规则。
- 并发与未知结果：DELETE 使用 `expected_version` 锁定当前事实；状态或版本变化返回可恢复冲突。响应结果不明时客户端必须 fresh GET：404 才确认删除，仍存在则保留条目和重试入口，不得重复提交其他操作。

#### AI-155-02 · P1 · AI 上游错误被压成统一“暂时不可用”

- 已核实：当前安装版配置状态为“已配置”，正式 API 与提案读取可达；失败条目记录 `ai_provider_unavailable`。现有 provider 把 429、上游 5xx、超时、DNS/连接/TLS 错误合并成同一代码和文案，且未写安全的上游故障日志，因此无法从客户端判断真实原因。
- Backend 分类：至少区分请求过多（429）、上游服务异常（5xx）、连接超时、连接/DNS/TLS 失败、配置或凭证被上游拒绝（其他 4xx）与响应格式异常；保留稳定、面向用户的恢复说明。
- 安全日志：只记录 provider host、model、故障类别、HTTP status、耗时与 request id；禁止记录 API key、Authorization、用户原文、候选账户/分类、上游响应体或完整 URL 查询参数。
- 前端呈现：macOS/iOS 显示可行动文案，例如稍后重试、检查网络或检查 AI 配置；不向用户展示内部代码、异常类或工程诊断字段。历史旧代码继续映射为兼容的通用提示。

#### B12-A · Backend 权威契约

所有权：AI routes/service/repository/provider、线性 migration 与 P8 schemas/tests。

- 新增 `DELETE /api/v1/ai/proposals/{id}?expected_version=n`，成功返回 204，并继续经过正式 mutation revision/attention 失效链。
- service 在行锁内校验版本、状态和关联对象均为空；0036 migration 为 proposal 增加数据库删除守卫，并只允许受守卫的父项删除级联清理其质量事件，独立改删质量事件仍被不可变触发器拒绝。
- 删除不存在返回 404；处理中、已执行、已撤销或未知状态返回稳定的 `ai_proposal_delete_forbidden`；版本冲突返回现有统一冲突结构与 fresh reload path。
- provider 细分错误代码和安全日志；P8 provider 单测覆盖 429、5xx、timeout、connect、4xx、invalid response，并证明日志不含密钥、原文或响应体。
- PostgreSQL/API 回归覆盖允许状态、禁止状态、质量事件清除、账目不受影响、版本竞态、404 与 data revision 仅成功删除时递增。

#### B12-B · 双端删除交互

所有权：`V15AIContracts.swift`、`V15AIProposalModel.swift`、macOS/iOS AI proposal views/components 与 F3-F tests/fixtures。

- typed service 增加 no-content DELETE；模型只为 pending/failed/ignored 暴露删除能力，并在 mutation gate 内阻止双击和与 retry/execute/ignore 并发。
- macOS 在内容详情的“人工动作”区、iOS 在同一内容详情动作区提供红色“删除这项内容”；按钮不得藏在工程菜单或仅靠键盘操作。
- 点击后使用系统确认面，明确“只删除这项未记账内容，不会影响账本；删除后无法恢复”。确认前零写入；取消保持选择和滚动位置。
- 成功后从当前页移除条目、更新待确认计数并按相邻项收敛选择；空列表显示真实空态。失败/冲突/结果不明都在当前界面展示恢复入口。
- 已执行/已撤销条目不显示或禁用删除，并保留“撤销这笔记账”的正确动作；processing 显示等待解析完成的原因。

#### B12-C · 验收与停止点

- Backend：格式、静态检查、数据库无关测试与可用的 PostgreSQL 定向测试通过；删除和 provider 分类均有单元/API 证据。
- App：F3-F 模型/fixture 回归、全量 `FiscalKitTests`、macOS/iOS 正式 target 构建通过；删除确认、取消、成功、冲突、unknown、空态与已执行保护均覆盖。
- 视觉：macOS 常用宽度和 1000pt、iPhone 13 普通字号与 AX5 检查危险按钮、确认文案、长原文及错误提示不溢出；沿用 Fiscal 现有语义和用户语言，不引入新组件库。
- 版本：`MARKETING_VERSION=1.5.5`、`CURRENT_PROJECT_VERSION=31`，执行 xcodegen 并清理生成噪声；最终双端产物 Info.plist 必须一致。
- 发布准备：复核通过后提交、创建不可变 `v1.5.5` 标签、推送 `main` 与标签，生成并严格验签 macOS/iOS 发布包及 SHA-256 记录。
- 明确停止：不执行 HZ Backend deploy，不修改生产数据库/服务，不替换 `/Applications/Fiscal.app`，不安装 iOS 包；把部署命令、产物与回滚点准备好后等待用户下一条指令。

#### B12-D · BUILD 验收结果

- Backend 全门通过：Ruff 格式/静态检查、Pyright 0 error / 0 warning、一次性 PostgreSQL 数据库上的全量 393 tests 通过；删除 API、数据库守卫、质量事件级联、data revision 与六类 provider 故障均有回归证据。
- App 模型与共享逻辑通过：F3-F 定向 31 tests；全量 `FiscalKitTests` 407 tests / 41 suites；删除只发一次、unknown fresh GET、冲突锁、404 收敛、离线零写入和用户文案映射均有覆盖。
- iOS F3-F Gallery UI 11/11 通过，覆盖确认取消、真正删除、失败原因用户化、unknown/readback、空态、冲突与 AX5 长内容；提交 AI 文本后主动收起键盘，恢复入口不再被键盘遮挡。
- macOS F3-F UI 在当前宿主连续三次被系统层 `Timed out while enabling automation mode` 阻断，0 个业务用例实际启动，不记为业务失败或通过。替代证据为 macOS UI `build-for-testing` 成功、正式 Release 成功，以及 15 张 F3-F 静态快照中的浅色、深色、错误态和 AX5 人工目检通过。
- 最终正式构建通过：`FiscaliOS` generic iOS Simulator Release、`FiscalmacOS` Release、`V15GallerymacOS` build-for-testing 与 `V15GallerySnapshotTool` Release；双端 Info.plist 均为 `1.5.5 (31)`，`git diff --check` 通过。
- 独立差异复审未发现需阻止发布的问题：已执行/已撤销/处理中条目受前后端双层保护，数据库直接删除也受守卫；日志不包含用户原文、Authorization、上游响应体或密钥；删除结果不明不会自动重发。

#### B12 完成定义

- 用户能在 macOS 与 iOS 对未记账 AI 内容执行一次有确认的真正删除；刷新、重启和归档导出后都不会重新出现。
- 删除绝不触及已经生成的账目或现金流，且任何竞态/未知结果都不会被界面误报为成功。
- 新失败能明确告诉用户是限流、上游异常、超时、连接失败、配置拒绝还是返回不可识别；生产日志足以定位但不泄露财务原文或凭证。
- 全部工程门、复核、提交、标签、推送和签名包准备完成，状态停在“等待生产部署与换包”。

### B13 · v1.5.5 未决删除刷新恢复快修（Build 32）— complete

- 复审发现 `AI-155-03`：DELETE 已到达服务端但响应断开时，模型进入 unknown；若用户不用专用“读取最新内容”而点击普通刷新，服务端列表可能已无原条目，页面改选下一项，但旧 owner 的 `directAttempts` 仍使全局写入锁保持，恢复入口却随当前选择消失。macOS 与 iOS 共用模型，双端都会进入“有锁、无入口”。
- 快修边界：保持 `MARKETING_VERSION=1.5.5`，仅把 `CURRENT_PROJECT_VERSION` 增至 `32`；不改 Backend、migration、DELETE 契约、用户确认文案或其他业务页面。
- 修复原则：普通刷新遇到未决直接写入时，必须先按该 attempt 的 owner 做 fresh GET 收敛，而不是把列表响应直接当作写入结果。DELETE owner fresh GET 为 404 才确认删除；owner 仍存在则恢复该 owner 的 unknown 可见面；fresh GET 失败则继续保留 owner、锁和重试入口。任何分支都不得自动重发 DELETE。
- 不变量：`writeLocked == true` 时必须存在当前用户可达的 recovery surface；刷新、选择变化和 owner 从列表消失不能制造孤儿锁。补 `deleteUnknown -> load()` 回归，覆盖 404 已删除、仍存在和读回失败，并断言 DELETE 始终只发一次。
- 验收：F3-F 定向与全量 `FiscalKitTests` 通过；iOS F3-F UI 覆盖 unknown 后普通刷新仍能恢复；macOS/iOS 正式 target 均构建为 `1.5.5 (32)`；复核无新 findings 后停在 commit/tag/push/签名包和部署换包之前。
- 结果：普通刷新现在优先收敛未决 owner；404 确认删除并解锁、仍存在时恢复原 owner 的结果未知面、读回失败时保留原 owner 与重试入口，所有路径均未重发 DELETE。macOS 与 iOS 复用同一修复。
- 门禁：F3-F 34/34、全量 `FiscalKitTests` 410/410（41 suites）、iOS 对应 UI 场景 1/1 全绿；`FiscaliOS` 与 `FiscalmacOS` Release 均成功，成品 Info.plist 均为 `1.5.5 (32)`，`git diff --check` 通过。
- 发布结果：源码提交 `5bf7956` 已推送；生产 Backend 已从 revision `3a584da` / Alembic `0035` 切换到 `5bf7956` / `0036`，迁移前后备份、readiness 与公网 liveness 均通过；双端签名包已严格验签，macOS 已备份 v1.5.3（29）并换包启动为 v1.5.5（32），iOS Development IPA 交由用户安装。既有 `v1.5.5` 标签保持不可变，Build 32 使用独立 `v1.5.5-build32` 标签。

### B14 · Fiscal 杭州→宁波生产迁移（不改版本）— complete

#### MIG-155-01 · 权威现状与单项目边界

- 杭州当前 Fiscal 为 `/opt/fiscal/releases/5bf795625673`、Alembic `20260823_0036`，生产库约 13 MB；API、PostgreSQL、Fiscal 备份/恢复/健康/磁盘 timer 与 `fiscal.linotsai.top` Nginx/TLS 仍实际工作。
- 宁波根盘约 47 GB 可用、约 3.1 GiB 可用内存、无 Swap；NPM 是 80/443 唯一入口，系统 Nginx 必须继续 disabled。Fiscal 后端不得占用或修改 Neckline/ICTW 的 8002/8787、NPM 数据库或既有自定义入口。
- 迁移只处理生产库 `fiscal`。Fiscal 历史 release、已验证 dump、operation 状态与 shadow 数据库作为冷归档迁出杭州，但 shadow 库不得恢复成宁波生产数据库。

#### B14-A · 宁波部署适配与冷态预部署

- 以当前干净 `main` 为来源，为宁波 NPM 拓扑提供独立、向后兼容的监听与 health 配置；杭州默认 127.0.0.1 语义不得被破坏。
- 宁波安装 PostgreSQL 16、Fiscal 专属 OS/DB role、目录、固定 uv、systemd units 和受限端口；API 只允许本机/NPM Docker bridge 访问，PostgreSQL 只监听 loopback。
- 安全迁移 `/etc/fiscal/fiscal.env` 所需秘密以保持现有设备认证；禁止输出内容。宁波所有正式服务和 timer 必须 enable，避免杭州 Fiscal active-but-disabled 的重启风险。
- 先复制代码与冷归档，再从杭州已验证 dump 在宁波完成恢复彩排；校验 SHA-256、PG archive、Alembic head、canonical tables、orphan postings、readiness、备份和隔离恢复。

#### B14-B · NPM/TLS 与切流前门

- 通过 NPM 官方管理面创建 `fiscal.linotsai.top` proxy host，不直接编辑 NPM 数据库或生成的 `proxy_host/*.conf`；证书必须在切流前可严格验证。
- 使用直连宁波 IP + SNI/Host 的方式验证 liveness、readiness 边界、受保护接口 401 和一次授权读取；公共 DNS 在最终停写前仍保持杭州。
- 切流前同时记录杭州最终 revision/head、宁波 revision/head、两端服务状态、备份校验值与明确回滚材料。

#### B14-C · 最终停写、迁库和 DNS 切换

- 停止杭州 `fiscal-api.service` 形成唯一写入冻结点；立即制作最终 custom-format `pg_dump`、manifest 和代码/配置元数据备份，经校验后传入宁波。
- 在宁波恢复最终库，验证 `20260823_0036`、完整性、外键/孤儿分录、应用 readiness、备份与 restore drill，再启动并 enable Fiscal API。
- 将 `fiscal.linotsai.top` A 记录切到 `114.66.2.205`；独立 DNS-over-HTTPS 与直连 TLS 必须同时证明新入口，macOS/iOS 用现有域名完成真实读写验收，不重新构建客户端。
- 单写者规则：DNS 切换后宁波一旦接受新写入，禁止仅改回 DNS 指向杭州；回滚必须先停止宁波写入并把最新宁波数据库恢复回杭州。

#### B14-D · 当场验收与杭州 Fiscal 清理

- 不设置观察期。数据库、服务、TLS、公网、认证、macOS/iOS、备份和恢复演练当场全部通过后，立即进入杭州 Fiscal 专属清理。
- 先保留最终不可变 dump、SHA-256、当前与上一 release 归档及安全的恢复说明；随后只 disable/remove Fiscal API 与 Fiscal timers、Fiscal Nginx vhost/续签项、Fiscal OS/DB roles、`/opt/fiscal`、`/var/lib/fiscal` 和 Fiscal 数据库/冷影子库。
- 杭州共享 `nginx.service`、`postgresql@16-main.service`、80/443/5432 配置及任何非 Fiscal vhost、数据库、用户、目录和进程不得停止或修改。
- 完成后更新 `NB_info.md`、`hz_info.md`、本计划与新的迁移验收记录；记录宁波 revision/head、证书、备份/恢复证据、DNS、新服务状态和杭州 Fiscal 缺失证明。

#### B14 完成结果

- 宁波生产运行于 `main` / `3eb49cbc4151aa06b0dacecc7025ad2ed7d85f42`、`/opt/fiscal/releases/3eb49cbc4151` 与 Alembic `20260823_0036`；PostgreSQL 16 只监听 loopback，API 的 `8010` 只允许 NPM Docker bridge，Fiscal API 与四个运维 timer 均 active + enabled。
- 杭州停写后的最终生产 dump 已在宁波恢复；225 条交易、247 条分录、0 孤儿分录及三组去隐私化财务指纹与源端逐位一致。恢复后备份、当前备份、restore verify 与受保护读取均通过，未把真实余额或流水内容写入仓库。
- NPM 官方管理面已建立 `fiscal.linotsai.top → 172.18.0.1:8010`；证书、HTTP/2、HSTS 与公网 readiness 403 边界均通过。阿里云权威记录已切到 `114.66.2.205`、TTL 10 分钟，AliDNS/Cloudflare DoH、外部主机和本机公网访问均确认新入口。
- `/Applications/Fiscal.app` 已从现有域名读取宁波生产；iPhone 端也产生了宁波认证成功的真实请求。无需重建或更换 v1.5.5（32）客户端。
- 杭州 1 个生产库和 49 个影子演练库已先全部导出校验，再随代码、配置、unit、Fiscal Nginx 与证书材料形成冷归档；宁波保存 `/var/lib/fiscal/backups/hz-retired-archive/fiscal-hz-retirement-20260830T115250Z.tar.gz`。归档双端 SHA-256 一致后，杭州 Fiscal unit、数据库/角色、入口、证书、系统身份和活动目录全部清除；共享 Nginx、PostgreSQL 与非 Fiscal 项目保持运行。

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
| 生产迁移 | 宁波 revision/head、readiness、备份/恢复、NPM/TLS/DNS 和双端读写全部通过；杭州只缺失 Fiscal 专属组件，其他项目不变 |

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
- v1.5.3（29）B10-A 至 B10-E 已完成：`NEXT-01` 至 `NEXT-04` 均已从 Backlog 收口到源码、测试和双端构建证据。
- 双端完成范围：共享录入模型已防重复并在成功后清空；macOS 与 iOS 都接收服务器确认事件并刷新页面事实；共享 posting 策略修正两端账户流水；macOS 录入页已移除重复左栏，iOS 保持单一全屏流程。
- 最终门禁为 401 tests / 41 suites 全绿、Mac/iOS 正式 App target 构建成功、双端版本 `1.5.3 (29)`、实机样例视觉检查通过、`git diff --check` 通过。
- v1.5.3（29）一条龙发布完成：源码提交 `78fd1c3`、双端签名包、严格验签、macOS 备份换包与启动均已完成；最终记录和不可变标签为 `archive/releases/v1.5.3/RELEASE_STATE.md` / `v1.5.3`。
- 当前 macOS 为 `/Applications/Fiscal.app` v1.5.3（29）；原 v1.5.2（28）保留在 `/Applications/Fiscal-v1.5.2-build28-backup-20260823-1834.app`。iOS Development IPA 由用户安装。
- v1.5.4（30）BUILD 已完成，唯一施工项 `REC-154-01` 已收口：macOS 按权威参考重构为稳定的核对操作区与独立诊断区；iOS 审计发现并最小修复长诊断把步骤动作推离视口的同类问题。
- 最终门禁为 402 tests / 41 suites、macOS F3-E UI 2/2、iOS F3-E UI 7/7、iPhone 13 AX5 定向 1/1、双端正式 App 与截图工具构建成功、双端版本 `1.5.4 (30)`、四组长诊断视觉检查和 `git diff --check` 通过。
- v1.5.4 已独立提交为 `a80c5f7` 并创建本地不可变标签 `v1.5.4`；与 v1.5.5 一并在最终发布准备阶段推送，不部署该中间版本。
- v1.5.5（31）B12-A 至 B12-D 已完成：未记账 AI 内容真正删除、双端确认与未知结果收敛、上游故障分类和安全日志均已进入源码并通过 Backend、共享模型、iOS UI、双端构建与 macOS 快照门禁。
- 当前发布门没有产品阻断项；唯一环境限制是 macOS UI 自动化宿主未能启用 automation mode，已用可测试编译、正式构建和静态视觉矩阵补证并如实登记。
- v1.5.5 源码已独立提交为 `a21e17c`；签名 macOS universal 包、iOS arm64 Development IPA、双端 dSYM、`RELEASE.txt` 与 `SHA256SUMS` 已从该干净提交生成，打包前后严格验签和可执行文件同一性核对通过。
- 发布交接记录见 `archive/releases/v1.5.5/RELEASE_STATE.md`；记录提交为 `56c8480`，不可变 `v1.5.5` 标签指向该提交，`main` 与 `v1.5.4`/`v1.5.5` 标签均已推送。当前无本地施工动作，等待用户授权生产部署与 `/Applications/Fiscal.app` 换包。
- v1.5.5（32）一条龙发布完成：B13 通过 34 项问题域测试、410 项全量测试、iOS 用户路径自动化、双端签名 Release 和解包后二次验签；Build 31 包已被 Build 32 取代。
- 生产 Backend 当前位于宁波 `/opt/fiscal/releases/3eb49cbc4151` / Alembic `20260823_0036`；最终恢复、当前态备份与 restore verify 均已验证，服务 active + enabled，本机 readiness 200、公网 liveness 200。
- 当前 macOS 为 `/Applications/Fiscal.app` v1.5.5（32）；v1.5.3（29）回退包位于 `/Applications/Fiscal-v1.5.3-build29-backup-20260823-222919.app`。iOS Development IPA 位于 `build/release-v1.5.5-32/artifacts/`，由用户安装。
- 最终发布记录、SHA-256、签名、生产部署和回滚边界见 `archive/releases/v1.5.5/RELEASE_STATE.md`；既有 `v1.5.5` 标签不移动，Build 32 使用不可变 `v1.5.5-build32`。
- B14 Fiscal-only 杭州→宁波迁移已完成：宁波 revision `3eb49cb` / Alembic `20260823_0036`、最终生产恢复、NPM/TLS/DNS、公网与鉴权、macOS/iOS 客户端、备份/恢复均已通过；杭州 Fiscal 证据完成冷归档后，其专属服务、数据库、入口、证书、身份和活动目录已清除，非 Fiscal 项目未纳入本次操作。详细证据见 `archive/releases/v1.5.5/NB_MIGRATION_ACCEPTANCE_20260830.md`。
