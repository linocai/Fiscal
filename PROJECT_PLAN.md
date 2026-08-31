# Fiscal · PROJECT_PLAN

> 目标：**v1.6.0（Build 33）** ｜更新：2026-08-31（Asia/Shanghai）｜阶段：**RELEASE · 一条龙发布已授权并执行中**

## 1. 当前目标、基线与范围

- 以“**事实完整性与操作闭环**”完成正式 v1.6.0：高风险操作先由服务端预览、同一事实版本的报表 v2、账户核对历史可见、已知未来事项可安全打开其所属对象，以及诚实的本机登录失效说明。
- 目标版本已更新为 `1.6.0 (33)`；本轮含新正式 API、线性 migration、报表契约和双端流程，按 minor 升级实施。
- 客户端/生产基线：`main` `d8e7fd0` 与 `origin/main` 同步；已发布客户端为 v1.5.5（32）；宁波生产为 revision `3eb49cb`、Alembic `20260823_0036`。发布前必须审计该实际生产 revision 到最终 release commit 的累计差异。
- 用户已授权 Plan、Build、独立 Review、两轮快速修复、双端视觉审查与独立复审修复，并于 2026-08-31 明确授权执行完整“一条龙发布”。视觉/交互八项与最终独立复审两项均已实现并完成定向/全量测试与双端构建；当前按 §7 顺序执行提交、不可变标签、签名打包、宁波后端迁移、健康验收与 macOS 可恢复换包，iOS 交用户安装。当前六个 Xcode scheme 本地变更属于既有工作区；XcodeGen 后已恢复并逐一校验原始摘要，不纳入本版本。

### Build 收口事实

- B15-A～B15-E 已完成实现；截图/OCR 玩法保持冻结范围不变。
- 首轮独立 Review 的 4 项发现已收口：action commit 在全局写锁内校验 revision；iOS 账目详情不再绕过 preview/commit；分类确认采用单飞防双击；CSV/PDF v2 导出补齐分期汇总。
- 第二次独立 Review 确认上述 4 项均已成立，但新增 1 项 P1：现金流“确认本次”提交没有专用单飞 guard。该项已快修：model 入口以 `confirmCommitIsInFlight` 拒绝并发提交，同一 preview 只产生一个 idempotency key；该状态进入统一写锁/禁用理由，iOS 与 macOS 按钮在途显示“正在提交”；新增双击回归测试证明只发出一笔提交。
- 针对性独立复审新增的两项已收口：iOS Today 内联现金流确认使用不可变 attempt key 的 single-flight gate；主现金流确认在途只锁定会改变 selection/owner 的筛选、月份和条目操作，避免 generation 被切换失效，同时不误伤无关界面入口。对应状态测试覆盖单飞与提交期间选择不可变。
- 最终独立复审新增的两项 P2 已收口：分类 commit receipt 成功后即视为已写入，随后的 GET 刷新失败只进入“已保存、可重试读取”状态，双端不再诱导重复提交；CSV/PDF 导出移除 revision/schema/stable ID/minor-unit 等工程字段，改用中文用户字段、人民币元与上海时间，文件名也不再暴露 revision。
- Backend 完整 PostgreSQL suite：`399 passed`；Ruff format/check 与 Pyright 均通过。新增真实竞争测试证明并发 writer 先提交时 token 只会返回 `action_preview_stale`，不会落下分类写入或错误回执。
- Apple `FiscalKitTests`：`420 passed`（41 suites）；新增分类“提交成功、刷新失败”回归，并保留分类、主现金流确认和 iOS Today 内联确认的单飞/选择归属覆盖。iOS generic simulator 与 macOS App target 在最终修复后均重新编译成功。
- 双端构建产物 `Info.plist` 已核对为 `1.6.0 (33)`；`git diff --check` 通过。
- 六个受保护 Xcode scheme 摘要与 Build 前记录完全一致。
- 人工视觉复验已完成 iPhone 13 浅色/深色/AX5，以及 macOS 当前正式组件；视觉八项与后续独立复审两项均已关闭，结果见 §8。尚未完成：真机流程验收、修复后独立复审（若用户要求）以及发布链路。

## 2. 权威与已校正的 Backlog

优先级：当前用户指令与本计划 > `AGENTS.md` > Backend schema/service/routes > V15 typed contracts/models/views > 设计启动资料；历史证据见 [能力缺口登记](archive/audits/v1.5.2-build-gap-register.md)、[v1.5.5 发布记录](archive/releases/v1.5.5/RELEASE_STATE.md) 和 `archive/releases/`。

| 旧项 | 代码事实与 v1.6.0 裁决 |
| --- | --- |
| CAP-152-01/02/10 | 还款、现金流确认、单笔/批量分类仍是 direct commit；本版以真正 preview/token-bound commit 收口。 |
| CAP-152-05～08 | `/reports/spending`、`/cash-flow`、`/debt` 各有局部计算，但 P34 period contract 只含三种分类金额、无完整日/未来/债务序列及完整 drill；本版合为正式报表 v2。 |
| CAP-152-04 | `/reconciliation/checkpoints`、`V15ReconciliationService` 和双端核对页已存在；改为通用账户详情接入，**不新造后端历史接口**。 |
| CAP-152-09 | access key 无 TTL/单键撤销；口令修改使 `credential_generation` 全量失效。只修原因与文案，不出现“过期”或旧设备生命周期。 |
| CAP-152-03 | 待同步原地编辑仍缺失，留在后续 Backlog。 |

## 3. 冻结的非目标

- 截图/照片记账保持现状：仅 iOS 快捷指令读取**最近 10 分钟截图**，由用户自行配置轻敲背面两下触发；不新增 App 内照片/截图/OCR 入口、macOS 拖入、权限、通知或替代流程，也不改该既有流程。
- 不做待同步原地编辑、到期提醒、App 内归档恢复、附件中心、设备级密钥管理、预算/建议/行为预测、多币种、多人、银行连接。
- 不把旧 `/reports/*`、直接写入 API 或已发布客户端静默改坏；新客户端只走本版新契约，旧路径保留兼容语义。

## 4. 稳定业务与并发规则

- 金额使用 `CNYAmountParser` / minor units；业务日、报表范围、未来事项、导出文件名一律 `Asia/Shanghai`。所有未来序列均为已有账期、报销或现金流事实，不做消费/收入预测。
- preview 为短时、一次性服务端会话：记录 action、规范化请求摘要、依赖对象版本、`data_revision`、到期与消费状态；不进入 Archive。输入任一变化、本地切换对象、版本/修订变化或到期即清空 token 并禁止提交。
- commit 只接受 token 与 `Idempotency-Key`，在锁内校验 payload/对象版本/修订；同键重放返回同一收据，异键或已消费 token 冲突。结果未知只能读取收据/最新事实，不自动重发写入。
- 在线 preview/commit 必须联网且鉴权有效；本版入口离线时明确禁用，不把本地摘要或待同步写入称为服务端预览。旧 pending 项仍可查看、移除和按既有规则恢复。
- 每个异步 model 采用 owner + generation；取消、失败和分页清理同样只影响原请求。冲突、unknown、错误在当前 sheet/inspector 显示恢复入口，不能隐藏到背景页面。

## 5. 后端契约与 migration（B15-A）

状态：**完成；第二次独立 Review 未发现新增问题。**

所有权：`Backend/src/fiscal_api/api/` schemas/routes、`services/`、repositories/models、Alembic、Backend tests；本批先锁 OpenAPI/fixture，再实施。

1. 新增一个线性 `0037` action-preview session/receipt migration（当前 head `0036`）：token、action、request digest/密封输入、依赖版本与 revision、expiry、consumed/receipt/idempotency；索引 expiry，Archive 导出排除该短时操作状态，生产备份仍按既有受限备份规则保存。
2. 新增三组 versioned API，不改旧 direct routes：
   - `repayment-preview` / `repayment-commit`：预览账户、信用账期、欠款与分录影响；commit 只从已封存 preview 创建还款。
   - `category-preview` / `category-commit`：同一契约处理单笔与批量；预览逐笔旧/新分类、数量与影响，commit 对整组选中账目和版本**原子**提交，任一冲突则全组重预览。
   - `cash-flow-items/{id}/confirm-preview` / `confirm-commit`：预览当前计划事项确认后的状态、影响和版本，再由 token 确认。
3. preview 返回面向用户的影响、token 到期、`data_revision` 与对象版本；commit 返回完整 receipt/刷新范围。测试覆盖版本、修订、输入、到期、重复 token、同键、冲突、unknown readback、权限与并发。
4. 新建 `/reports/v2/` period read/export/drill 路由和 schema；保留 P34 v1。v2 每次请求在单一一致性读快照中生成 `schema_version=2`、`data_revision`、上海日期范围；drill/export 必带该 revision，不一致返回 `period_report_changed`。
5. v2 统一返回七口径分类分布与按日序列：总消费、商户退款、净消费、预计报销、已收报销、个人预计承担、个人实际承担；并返回可追溯的已知未来事项与信用账期/分期债务周期序列。drill 行补齐七口径金额、来源/目标账户名称与归档状态、账目 `voided_at`/状态；默认 figures 与 drill 均只取有效账目，审计状态不得被客户端拼接。
6. access key 鉴权仅在能证明 digest 对应旧 generation 时返回稳定 `credential_generation_changed`；其余保持泛化 `invalid_access_key`。不新增 expired/revoked 字段、TTL、单键撤销或敏感密钥可枚举信息；无需 migration。

## 6. 双端施工批次

### B15-B · 服务端预览操作（双端）

状态：**完成；最终独立复审的分类提交/刷新边界问题已修复并验证。**

所有权：`V15*Contracts.swift`、`V15Services.swift`、`V15RecordModel/Views.swift`、`V15LedgerModel/Views.swift`、`V15CashFlowModel/Views.swift` 及对应 fixtures/tests。

- 还款录入、单笔分类、macOS 批量分类、iOS 等价分类入口和现金流确认全部改为“查看影响 → token 仍有效才确认”。从预览返回到编辑、改金额/日期/账户/账期/分类/选择集、刷新到新 revision 时立即失效。
- 提交期间防双击；成功仅以 receipt/readback 触发既有账户、账目、Today、报表、attention 刷新。冲突回编辑，unknown 留在原操作面并提供安全读取；不产生第二笔还款、重复分类或重复确认。
- 分类 receipt 已确认成功时，后续 GET 失败只提示“已保存，最新账目暂时无法读取”并允许安全刷新；不得把已落库事实降级为提交失败或再次开放相同写入。
- iOS sheet 内必须展示 loading/影响/失效/错误；macOS 维持 inspector 选择归属。两端均不显示 token、revision、请求键或工程词。

### B15-C · 正式报表 v2（双端）

状态：**完成；最终独立复审的导出用户语言问题已修复并验证。**

所有权：`V15Reporting*` contracts/services/model/views、macOS/iOS report views、导出和 F4 fixtures/tests。

- 客户端切换到 `/reports/v2/`，不再从 legacy spending/cash-flow/debt 拼图；四个报表镜头共享同一 meta revision，切换范围/镜头取消旧 generation。
- 分类、日趋势、已知未来、债务周期与 drill 使用同一 revision；分页/导出沿用该 revision，任何改变都清空摘要、页游标、drill 和导出候选并要求重新读取。
- 七口径保持 neutral 金额表达；未来项标明“已知/预计/已排期”的来源与确定性，不称为预测。空态表示真实无数据，未知 server enum 仅展示且不参与计算。
- CSV/PDF 仅输出用户可理解的中文业务字段、人民币元与上海时间；内部 revision/schema/稳定 ID/minor-unit 字段只保留在机器契约和响应头，不进入文件正文或文件名。

### B15-D · 账户历史与已知未来导航（双端）

状态：**完成；第二次独立 Review 未发现新增问题。**

所有权：`V151MacWorkspace.swift`、`V151IOSWorkspace.swift`、共享账户详情 model、`V15FutureTimeline*`、Credit/Reimbursement/CashFlow 的可选对象选择与测试。

- 提取共享账户详情读取：并行获取账户与既有 `reconciliation/checkpoints?account_id=`，用 account-scoped generation 保证切换账户不串行；显示真实检查点历史、空态、失败重试与“进入核对”，不创建新 API 或从余额推历史。
- Future Timeline 将已通过 `isSafeLocator` 的事件交给根壳导航；进入目标前 fresh read 并验证 source ID、账户、账期/claim/party/item 归属。仅信用账期、报销对象、现金流条目可打开；失效、归属不符、未知 source 或离线只显示原因，不执行写入。
- macOS 维护原单窗口选择/inspector；iOS 在全屏目的地保留返回来源。不得接受任意 URL、host、query 或借 deep link 绕过对象选择。

### B15-E · 登录失效说明、版本与收口

状态：**完成；第二次独立 Review 未发现新增问题。**

所有权：Bootstrap contracts/model/views、Backend auth/security tests、`App/project.yml`、release scripts/records。

- 双端把旧“访问密钥已过期或被撤销”改为事实性文案：能确认代次变化时说明“口令修改后，本机需要重新解锁”；其余只说“本机登录信息无效，请重新解锁”。保持同一安全恢复路径。
- 最后才更新为 `MARKETING_VERSION=1.6.0`、`CURRENT_PROJECT_VERSION=33`；若改 `project.yml` 或增删 Swift 源文件，运行 `cd App && xcodegen generate`，保留那六个 scheme 工作区变更不碰。

## 7. 验收与发布门

- Backend：Ruff、Pyright、完整 PostgreSQL suite；0037 upgrade、preview session 生命周期、三类 commit、P34 v1 兼容、reports v2 同 revision/分页/导出、auth reason 非枚举泄露均通过。
- App：新增定向共享 tests（token 失效、并发、unknown、offline、generation、账户历史、source-aware navigation、v2 revision conflict），然后 `FiscalKitTests` 全量；`FiscaliOS` generic simulator 与 `FiscalmacOS` target 必须编译。
- 视觉/UI：macOS 1000pt 与常用宽度、iPhone 13 普通/AX5、浅深色；长影响清单、七口径趋势、长历史、失效导航、错误面均无截断、主操作始终可达。真机完成还款/分类/现金流确认、账户历史、未来导航与**既有**快捷指令最近 10 分钟截图流程回归。
- 发布前：`git diff --check`、仅计划范围差异、双端 Info.plist 均为 1.6.0 (33)。一条龙发布时：先从宁波生产基线审计累计差异并完成最终验证；提交并推送 `main`，创建不可变 `v1.6.0` tag，从该已提交 revision 生成发布包并严格验签。随后才执行宁波 deploy dry-run、迁移前备份校验 → apply 0037 → 迁移后备份/restore verify → local readiness 200、public liveness 200、public readiness 保持预期阻断、受保护读取与 v2 smoke；最后 macOS 可恢复备份换包启动，iOS IPA 交用户安装。部署后若需记录事实，另以 docs 提交补充 release record，绝不移动既有 tag。
- 回滚：禁止盲 Alembic downgrade；若 migration 后需退回，先停止写入、备份宁波当前库、恢复已验证 pre-0037 dump 到新目标再切换。客户端只在签名/健康均通过后替换。

## 8. 2026-08-30 双端视觉审查

审查基线与边界：iOS 使用当前 Build 33 的独立 RootSmoke 正式根组件与合成事实，在 iPhone 13 / iOS 26.5 检查普通字号浅色、普通字号深色与 AX5；macOS 使用当前 Build 33 编译出的正式 View 组件和隔离 Gallery 数据直接运行，检查 Today、记一笔、现金流、报表及深色现金流。未执行保存、确认、取消等写入。RootSmoke/Gallery 自身的 fixture 错误文字不计为产品问题；以下均由实际布局或正式用户文案路径直接复现。

| 级别 | 平台 | 原发现 | 修复与复验证据 |
| --- | --- | --- | --- |
| P1 | iOS | AX5 下 Today 根内容不滚动，固定底栏覆盖“未收报销”起的内容。 | **已解决。**底栏改为 safe-area inset，根内容保持滚动；AX5 自动化滚动后“已知未来”操作与底栏同时可点击，浅色/深色/AX5 RootSmoke 通过。 |
| P1 | macOS | 现金流空白草稿时，“新建现金流”入口被标题/金额校验禁用。 | **已解决。**入口只受全局不可写状态约束，空白草稿可打开；直接运行 macOS Gallery 验证空白表单可进入、创建按钮保持禁用且无初始报错。 |
| P1 | iOS | Today 内联现金流确认缺 single-flight，同一 token 可生成两个提交 key。 | **已解决。**内联确认加入 immutable attempt single-flight gate，提交在途拒绝第二次进入；单元测试证明同一时刻只拥有一个 key。 |
| P2 | 双端 | 主现金流确认提交在途仍可切换条目，使 commit generation 失效。 | **已解决。**提交在途锁定 scope、账户、月份、条目和自动选择，await 返回前 selection/owner 不变；状态测试覆盖该竞态。 |
| P2 | iOS | 报表总览和现金流双列主金额在 iPhone 13 被列边界裁切。 | **已解决。**报表指标改为具备完整金额最小宽度的自适应布局；UI 测试逐项验证指标 frame 位于 App 可见边界内。 |
| P2 | 双端 | 空白记账与新建现金流首次打开即显示校验错误，并重复同一原因。 | **已解决。**空白初始状态保持中性；只有非空无效输入或服务端 field issue 显示一次错误，按钮不再复述字段错误。iOS 记账/现金流 UI 测试与 macOS 直接视觉复验通过。 |
| P2 | macOS | Today 展示 `legacy`、`隔离环境重新验证`、`当前阶段` 等工程/运维措辞。 | **已解决。**operation/locator 原因统一转换为用户可执行说明，双端共享；单元测试扫描用户文案，禁止泄露既有工程词。 |
| P3 | iOS | 现金流首页大标题在 iPhone 13 把“逐笔”拆开并占用过高。 | **已解决。**副标题缩短为“逐笔看清计划与实际”，普通字号 Gallery 回归不再拆字。 |

通过项：iOS Today 普通字号浅色/深色的主要卡片、底栏与操作对比度可辨；iOS 记账表单由全屏明细承担，不再出现旧版左侧重复“大框”；macOS 记账表单已使用整页单列编辑器；macOS 报表四镜头与现金流三栏在常用宽度下层级清楚，深色模式未见新的裁切或不可辨操作。

复验说明：macOS Gallery XCUI 启动被本机“启用 UI 自动化”管理员密码提示挡在应用启动前，因此该次没有执行任何产品断言；随后改用已编译的同一隔离 Gallery App 直接运行和读取可访问性树，完成新建现金流入口、空白表单、校验中性状态和布局复验。该宿主权限问题不计为产品缺陷。

### 2026-08-31 最终独立复审补充

- **P2 · 双端分类提交状态：已解决。** receipt 成功与刷新成功拆分记录；刷新失败时双端明确显示分类已保存，只开放读取恢复，不重复写入。新增回归证明一笔 commit 后即使 GET 失败也只发送一次写入。
- **P2 · 报表导出用户语言：已解决。** CSV/PDF 正文和文件名不再暴露 `data_revision`、`report_schema_version`、`stable_id`、`value_minor`、原始枚举或 revision 后缀；金额统一展示为人民币元，PostgreSQL 月报/年报真实导出回归通过。

## 9. Backlog、完成定义与下一步

- 本版完成：CAP-152-01/02/04/05/06/07/08/09/10；CAP-152-04、09 按本计划的已校正含义关闭。后续保留 CAP-152-03、提醒、归档恢复、附件与设备管理。
- 完成定义：双端只以同一服务端事实提交和展示，报表与 drill/export 绝不混 revision，账户详情能见真实检查点，未来事项只打开被证实所属的对象，登录失效不虚构原因；所有门禁、部署、签名、换包和记录完成后才发布 v1.6.0（33）。
- 下一步：完整执行已授权的一条龙发布并把生产、签名、换包与交付事实写入 `archive/releases/v1.6.0/RELEASE_STATE.md`。真机 iOS 安装仍由用户完成；任何部署阻断按 §7 回滚边界处理，不移动既有标签。
