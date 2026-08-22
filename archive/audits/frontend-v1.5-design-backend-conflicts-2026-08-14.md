# Fiscal v1.5 前端设计 × Backend / 产品规则冲突清单

> 状态：D1–D10 已于 2026-08-14 全部按推荐项批准；尚未进入施工
> 审计日期：2026-08-14（Asia/Shanghai）
> 设计基线：`Fiscal 前端设计启动/`
> 后端基线：当前 `Backend/`（v1.4.0 API）
> 产品基线：根 `PROJECT_PLAN.md` 与 `archive/plans/v1.4-v1.5-backlog.md` 的 v1.5 P30–P35 规划
> 本文件只做契约审计，不批准任何后端或前端改动。

## 0. 结论摘要

新设计的视觉体系可以直接作为 v1.5 的视觉权威，但不能按现状直接施工成完整 v1.5。

原因不是样式问题，而是存在三层事实尚未对齐：

1. 设计稿覆盖了离线写入队列、完整修订历史、来源链、分类合并/拆分预览、归档导出进度等能力；当前 API 没有相应契约，或行为与设计相反。
2. v1.5 产品规划要求 `KnownFutureEvent`、统一事实快照、扣除已确认应付后余额、商户归一、月报/年报和报告导出；这些仍是 P30–P34 backlog，当前 Backend 尚未实现。
3. 设计稿的个别“冻结决定”与当前后端直接冲突，例如 AI 必须人工确认，而后端仍支持自动执行；设计允许离线排队写入，而现有客户端明确只有只读离线快照。

因此正式施工应分成两道门：

- 先确认本清单中的产品取舍，并冻结 v1.5 服务端契约。
- 服务端契约可用后，再开始 clean-room SwiftUI 重写。

不能用客户端拼接、推测或本地计算来掩盖缺失的服务端事实。

## 1. 权威顺序

| 范围 | 权威来源 | 处理规则 |
| --- | --- | --- |
| 金额、字段、枚举、状态机、校验、可用动作、幂等、并发 | 当前 Backend schema/service | 设计冲突时以后端为准；若 v1.5 产品目标要求新能力，先改后端契约 |
| 产品边界与 v1.5 目标 | `PROJECT_PLAN.md` + v1.5 P30–P35 backlog，经用户本次确认后冻结 | backlog 当前仍是规划，不能假装已实现 |
| 色彩、字号、间距、组件外观、视觉状态语法 | `Fiscal 前端设计启动/` | 作为视觉验收基线 |
| 页面组织和交互意图 | 设计原型 | 仅在后端契约支持时采用；不可让原型虚构行为 |
| v1.4 旧前端 | 无设计权威 | 只可审计非视觉基础设施，不复用旧 View、样式或表现层状态模型 |

设计交接包称“交互原型是行为权威”，但用户本轮指令已覆盖这句话：行为必须先通过 Backend 与产品规则校准。

## 2. 阻断完整 v1.5 的契约缺口

以下项目如果不先处理，就只能做“换壳版 v1.4”，不能声称完成 v1.5。

### B01 · v1.5 统一事实快照尚未实现

**设计/产品目标**

- v1.5 首页应统一展示当前现金余额、当前信用负债、待回报销、扣除已确认应付后余额。
- 所有数字来自同一个版本化服务端事实快照，并携带 `as_of`、窗口、revision 和口径版本。
- 见 `archive/plans/v1.4-v1.5-backlog.md:461-517`、`:549-585`。

**当前后端**

- `/reports/overview` 返回 `account_value_minor`、信用欠款、月收入、未收报销、七口径支出、现金流摘要、forecast 等旧式组合。
- 不存在 `after_confirmed_outflow_minor`、`confirmed_due_outflow_minor`、统一完整性计数或事实快照版本。
- `ReportMeta` 只有 timezone、currency、date range、as_of，没有 data revision 或 schema version。
- 证据：`Backend/src/fiscal_api/api/p7_schemas.py`、`Backend/src/fiscal_api/services/reporting.py:207-266`。

**影响**

- iOS 今日页和 macOS 概览不能按 v1.5 产品定义落地。
- 设计稿中“账户价值扣掉全部信用欠款”的数字，不等于 v1.5 的“当前现金余额减窗口内准确/已确认应付”，不能沿用或在客户端相减。

**建议**

先完成 P30/P32 事实快照接口，再接新首页。设计视觉保持不变，主数字和解释文案按新契约替换。

### B02 · 统一已知未来事件与去重契约尚未实现

**设计/产品目标**

- macOS 脊柱未来段、iOS 决策台、现金流镜头和首页未来摘要应引用同一批未来事实。
- P30 要求 `KnownFutureEvent` 具备稳定 `source_type/source_id`、四级 certainty（`exact_due / confirmed / expected / scheduled`）、深链、窗口和去重。
- 见 `archive/plans/v1.4-v1.5-backlog.md:461-512`、`:587-614`。

**当前后端**

- `/reports/cash-flow` 的 `ForecastEvent` 只有 `exact/expected`，当前只投影信用账期与报销回款。
- 手工现金流在 `/cash-flow-items`，分期计划在 debt/installment 接口，信用到期又同时出现在 overview、forecast 和 system cash-flow item 中。
- 当前没有跨这些来源的统一稳定事件 ID、完整 certainty 或聚合去重接口。
- 证据：`Backend/src/fiscal_api/services/reporting.py:512-590`、`Backend/src/fiscal_api/services/cash_flow.py:392-503`。

**影响**

- 客户端若自行把多个接口合并成“未来时间轴”，存在同一信用账期重复出现、重复计入的风险。
- 设计稿 macOS 的“确定出账 = 信用到期 + 房租”和脊柱未来段当前无法由一个后端响应证明。

**建议**

先实现 P30 `KnownFutureEvent` read model；新前端只负责排序与展示，不自行去重金额。

### B03 · P31 商户归一与过去事实分析尚未实现

**产品目标**

- v1.5 要有稳定 Merchant/Counterparty、别名、用户确认映射、商户/账户/来源/类型等报表维度及同比环比。
- 见 `archive/plans/v1.4-v1.5-backlog.md:520-547`。

**当前后端**

- 没有 merchant/counterparty 实体、路由或关系。
- Spending 只按分类聚合；report drill-down 只接受 spending/cash-flow lens，以及 category/account/date 过滤。

**影响**

- 设计参考虽然出现“商户”文案，但没有覆盖 v1.5 商户主数据、映射确认、规则来源和商户报表。
- 若直接开工，P31 必然在后期打穿新页面结构。

**建议**

先冻结 merchant 还是 counterparty，并完成 P31 schema；前端再设计对应详情、映射提议和报表镜头，沿用既定视觉系统。

### B04 · P34 月报、年报和报告导出尚未实现

**设计/产品目标**

- 设计稿报表页提供“导出 CSV”。
- v1.5 P34 要求月报、年报、PDF、CSV、report schema version、generated_at/data revision 和完整下钻。
- 见 `archive/plans/v1.4-v1.5-backlog.md:616-657`。

**当前后端**

- 只有 overview/spending/cash-flow/debt/drill-down。
- `/transactions/export.csv` 只是流水筛选导出，不是报告 CSV。
- 没有月报、年报、报告 PDF 或报告 CSV 端点。
- 证据：`Backend/src/fiscal_api/api/routes/reports.py:25-84`、`Backend/src/fiscal_api/api/routes/transactions.py:102-133`。

**影响**

- 设计稿的“导出 CSV”若直接接流水导出，会把不同产品语义伪装成同一个功能。

**建议**

报表导出按钮在 P34 接口完成前不得启用；正式施工前先冻结屏幕、PDF、CSV 共用的报告契约。

### B05 · 离线写入队列与现有离线契约相反

**设计决定**

- 设计冻结了离线写入白名单、待同步队列、自动重放、本地乐观余额和批量同步凭证。
- 见 `Fiscal 前端设计启动/Design/00-HANDOFF.md:114-115`、`Design/06-direction-decision-and-inventory.md:48-93`。

**当前实现与 API**

- `OfflineSnapshotStore` 明确声明“没有请求队列，VPS 是唯一写入权威”。
- `APITransport` 仅在 GET 网络失败时回退到加密只读快照。
- 分类、备注编辑、批量分类、忽略 attention 等设计白名单操作并非全部拥有 Idempotency-Key；排序端点甚至没有 expected version。
- 证据：`App/Sources/FiscalKit/API/OfflineSnapshotStore.swift:8-14`、`App/Sources/FiscalKit/API/APITransport.swift:113-146`。

**影响**

- i-16 待同步队列、iOS/macOS “待同步”镜头以及“含未同步余额”均无真实契约。
- 不能只在客户端补一个队列，否则会破坏幂等、跨设备冲突和服务端金额真相。

**建议**

v1.5.0 保持“离线只读快照，所有写入禁用并说明原因”。如确实需要离线写入，应作为独立后端+客户端契约立项，不属于单纯前端重写。

### B06 · AI“必须人工确认”与后端自动执行直接冲突

**设计/产品规则**

- 置信度只用于排序和提示，不得跳过人工确认。
- 见 `Fiscal 前端设计启动/Design/00-HANDOFF.md:57`、`Design/01-domain-and-priorities.md:72-76`。

**当前后端**

- `AISettingsResponse`、strategy 和 quality events 均包含 `auto_execute_enabled`、金额阈值、置信阈值和 `automatic_execute`。
- service 会判断提议是否满足自动执行条件。
- 证据：`Backend/src/fiscal_api/api/p8_schemas.py:108-121`、`Backend/src/fiscal_api/services/ai.py:666-893`。

**影响**

- 仅在新 UI 隐藏自动执行设置不能保证提议不会由服务端自动写账。
- 新界面若把所有提议称为“等待你确认”，可能与真实服务端状态不一致。

**建议**

若确认采用新设计原则，必须先在后端关闭并移除/废弃自动执行能力，迁移现有设置为关闭；不能只改 UI。

### B07 · 修订历史与完整来源链没有读 API

**设计目标**

- 交易详情和 macOS 检查器展示字段、postings、来源链、完整 revision 历史。
- 见 `Design/03-information-architecture.md:123`、`Design/06-direction-decision-and-inventory.md:123,142`。

**当前后端**

- 数据库确实保存 `TransactionRevision`，但 API 只返回当前 `TransactionResponse`，没有 revision 列表端点。
- `source` 只说明产生方式；账单导入 provenance、AI proposal、cash-flow 来源对象等没有统一可读来源链。
- 证据：`Backend/src/fiscal_api/db/models/ledger.py:42-46,154-179`、`Backend/src/fiscal_api/api/routes/transactions.py:148-154`、`Backend/src/fiscal_api/api/p3_schemas.py:87-108`。

**影响**

- i-07、m-04 的核心信息区无法真实实现；使用 `created_at/updated_at` 伪造两条 revision 不可接受。

**建议**

增加只读 revision/provenance 契约后再实现检查器；至少要有事件、版本、时间、快照/差异和稳定来源目标。

### B08 · 分类合并/拆分设计与实际命令模型不兼容

**设计目标**

- 合并前显示交易数、金额、子分类依赖并让用户决定子分类去向。
- 拆分要求把历史交易逐条归位后确认。
- 见 `Fiscal 现金流 AI 主数据 安全.dc.html:95-138`。

**当前后端**

- merge 请求只有 source/target version；服务端自动迁移交易、自动合并同名子分类、其余子分类改挂目标。
- split 请求只创建两个以上子分类，不包含历史交易归位，也没有 preview。
- 证据：`Backend/src/fiscal_api/api/p2_schemas.py:201-209`、`Backend/src/fiscal_api/services/categories.py:213-309`。

**影响**

- 设计里的预览和逐条归位不是当前 API 的另一种展示，而是不同的产品行为。

**建议**

如果保留设计交互，需新增服务端 preview token/版本、依赖清单、子分类映射和拆分归位命令；否则必须重画这两个流程。

## 3. 当前 API 与设计行为的直接不一致

### C01 · Attention 类型已可确定，但两条 deep link 无法闭环

当前后端实际产生以下 `source_type`：

- `reconciliation_checkpoint`
- `reconciliation_missing`
- `uncategorized_transaction`
- `ai_proposal`
- `operation_exception`
- `cash_flow_overdue`
- `reimbursement_overdue`
- `credit_cycle_overdue`
- `statement_import_review`
- `statement_import_failed`

对应 deep link 由后端固定为 `fiscal://...`，见 `Backend/src/fiscal_api/services/reconciliation.py:142-344`。

问题：

- `fiscal://reconciliation/checkpoints/{id}` 没有按 checkpoint ID 读取的 API；现有列表端点要求 account_id 或 credit_cycle_id 二选一。
- `fiscal://settings/migrations/{id}` 没有迁移运行详情 API。
- statement import 两类 attention 明确不可忽略，设计不能统一显示“稍后/忽略”。

建议：补齐两个 deep-link read contract；新前端对未知 `source_type` 必须提供安全的通用详情，不硬编码崩溃。

### C02 · 版本冲突响应不足以展示设计要求的“变化原因与差异”

设计要求冲突接管面显示“变了什么、旧值、服务器当前值、为什么变化”。

当前通用 `resource_version_conflict` 只有 code/message，不带 current version、current resource 或字段 diff，见 `Backend/src/fiscal_api/services/common.py:38-41`。客户端可以重新 GET 并重新预览，但不能可靠知道“期间新增了一笔还款”这类原因。

建议：

- v1.5 最低可接受：显示通用冲突说明，重新 GET 后要求用户重新决定。
- 若坚持设计中的字段对照和原因，应扩展稳定的 conflict `details`，不能由客户端猜测。

### C03 · 批量分类是原子失败，不是部分完成

设计原型称：多选中包含已作废交易时，其余项目仍完成，并返回部分完成报告。

当前 `bulk-category` 会先校验全部交易；任一交易已作废、不可分类、版本冲突或方向不匹配时，整个请求失败且不会提交任何分类，见 `Backend/src/fiscal_api/services/transactions.py:304-375`。

建议：以当前原子语义为准，重画为“全部未修改 + 标出阻断项”。不要把原子失败展示成部分成功。

### C04 · 信用账单日变更是原子操作，不存在中途部分生效

设计线框要求覆盖多周期 rebase 中途失败后的部分成功。

当前 schedule change 在单一数据库事务内执行；异常会 rollback，成功才 commit，见 `Backend/src/fiscal_api/services/credit.py:299-329,330-486`。

建议：删除此流程的“部分生效”状态；保留 preview、冲突、原子失败和成功凭证。

### C05 · 设计给分类动作展示财务预览，但后端没有预览接口

iOS 分类卡和 macOS 检查器在选择分类后展示“本月支出/未分类数量变化”的预览。

当前单笔更新和 `bulk-category` 都直接写入，没有分类预览接口。客户端自行计算报告变化违反“服务端拥有报表口径”。

建议：普通分类改为直接原子保存 + 成功凭证；如果必须保留财务影响预览，则先新增服务端 preview。

### C06 · 报销并非设计所称“多数生命周期动作都有 preview”

当前有 preview 的主要是：claim replacement、cancel-outstanding、receipt create/replace。submit、retract、reopen、void、restore、archive、unarchive 没有 preview 路由。

建议：

- UI 只对后端已有 preview 的动作采用 preview→commit。
- 若产品认为 void 等动作必须预览，需新增后端端点，不能先做假预览。
- 文案需区分 `restore`（恢复作废）与 `unarchive`（取消归档），不能统一叫“恢复”。

### C07 · 系统派生现金流可编辑范围与设计规则相反

设计规则称系统派生项金额跟随来源，只能改有限展示字段。

当前行为：

- credit-cycle projection 完全只读。
- reimbursement projection 可通过 `CashFlowSystemReplace` 改 title、note、planned amount、expected date 和 status。
- 证据：`Backend/src/fiscal_api/api/p13_schemas.py:123-129`、`Backend/src/fiscal_api/services/cash_flow.py:239-297`。

建议：冻结产品规则。推荐金额始终跟随报销事实，仅允许标题、备注和可选日期覆盖；若采纳，需要收窄后端 schema。

### C08 · 归档导出没有服务端进度、历史或凭证接口

设计稿显示“可能持续几分钟、上次导出、进度、完成凭证与校验值”。

当前 `/archives/export` 同步返回 `.far` 文件；无任务 ID、进度、导出历史或凭证查询，见 `Backend/src/fiscal_api/api/routes/archive.py:15-25`。

建议：当前契约下改为普通文件导出：只展示本次传输进度，以及保存后的文件名、时间和大小；不能声称服务端保存“上次导出/已校验”。若要展示 manifest、校验值或可恢复任务，应先让后端返回对应元数据或新增 job contract。

### C09 · 启动门不存在“密钥过期”状态

设计区分“过期”与“撤销”。当前 access key 没有到期字段；passphrase change 通过 generation 使旧 key 失效，错误统一为 `invalid_access_key`（无效或已撤销）。

证据：`Backend/src/fiscal_api/db/models/access.py:23-24,52-53`、`Backend/src/fiscal_api/core/security.py:37-46`。

建议：移除“已过期”独立状态，保留口令错误、无效/已撤销、离线、服务未就绪。若未来引入 TTL，再追加过期状态。

### C10 · 账单本地提取不能承诺离开页面后继续

设计流程写“可以离开这个界面，进度会保留”。当前 iOS 进入后台或页面消失会丢弃本地 source/review 状态并清理临时材料；失败重启也是显式前台动作，没有后台重试。

证据：`App/Sources/FiscalKit/Features/IOSStatementImportScreen.swift:43-44`、`App/Sources/FiscalKit/Features/StatementImportIntake.swift:374,444-451`。

建议：出于隐私与临时文件边界，v1.5 文案改为“离开会停止本地提取；已登记批次可稍后重新开始”。不要为匹配原型而偷偷持久化 PDF。

### C11 · 导入确认凭证不足以实现“查看新建的 N 笔”

当前 `StatementImportConfirmReceipt` 只有 operation ID、batch ID/version、status 和 confirmed row IDs，不返回 created/matched transaction IDs 或分项计数，见 `Backend/src/fiscal_api/api/p27_confirmation_schemas.py:37-43`。

设计还声称校验差额会以带金额提醒进入决策队列；当前 import attention 只有通用 explanation，未携带差额金额。

建议：扩展 receipt 为逐行结果（resolution + transaction ID）和稳定 counts；若要显示校验差额提醒，attention 也需携带对应 check/source。

### C12 · “界面没有删除”与安全删除 API 不一致

设计把 archive 解释成唯一删除语义。当前账户和分类都提供安全 DELETE：仅在无引用等约束满足时永久删除，同时也提供 archive/restore。

证据：`Backend/src/fiscal_api/api/routes/accounts.py:76-88`、`Backend/src/fiscal_api/api/routes/categories.py:71-84`。

建议：产品需确认是否在 v1.5 UI 暴露永久删除。推荐主界面只提供归档；永久删除仅用于无使用记录的新建错误项，并明确不可恢复。若完全不暴露，后端路由可保留为维护能力。

### C13 · 账户/分类排序没有乐观并发保护

`AccountOrderRequest` 只有 ordered IDs；`CategoryOrderRequest` 只有 parent ID + ordered IDs，没有 expected version 或排序 revision，见 `Backend/src/fiscal_api/api/p2_schemas.py:101-102,196-199`。

设计要求跨设备冲突不得静默覆盖，但排序当前可能 last-write-wins。

建议：在实现拖拽/键盘排序前，增加列表级版本或每项 expected versions。

### C14 · 分期计划不是四态，而是五态

设计屏幕清单称 lifecycle 四态，遗漏 `completed`。当前公开状态为：`active / completed / settled_early / partially_cancelled / cancelled`，见 `Backend/src/fiscal_api/api/installment_types.py:9-14`。

建议：新前端必须覆盖五态，`completed` 使用已完成事实样式，不并入 `settled_early`。

### C15 · 交易 void 的可用性与禁用原因没有服务端 capability 字段

void 会受报销分摊、报销收款、system/installment 关系限制，见 `Backend/src/fiscal_api/services/transactions.py:974-1004`。但 `TransactionResponse` 没有 `available_actions` 或 reason code 列表。

建议：增加服务端 capabilities，或在点击后处理稳定错误；不推荐把所有后端限制复制到 ViewModel 中长期维护。

### C16 · stale 阈值没有产品/服务端契约

当前离线快照有 `storedAt`，但没有“在线数据超过多少分钟算陈旧”的统一阈值。设计文件也仍把它列为开放问题。

建议：离线时总是显示快照时间；在线 stale 只在服务端明确返回 freshness/lag 后显示，不用客户端任意分钟数判断。

### C17 · last_four 是否展示仍需隐私决定

账户/债务响应提供 `last_four`，设计稿刻意不展示，产品规则禁止完整卡号但未明确屏蔽尾号。

建议：默认只展示账户昵称；只有重名或明确需要辨识时显示“尾号 1234”，并禁止进入截图夹具和日志。

## 4. 设计未覆盖、但当前后端已有契约

这些不是后端冲突，而是正式重写前必须补齐的设计状态。补稿必须沿用现有视觉令牌，不参考 v1.4 UI 外观。

| 设计缺口 | 当前后端能力 | 处理建议 |
| --- | --- | --- |
| 账户/分类排序编辑态 | accounts/categories order | 在 C13 并发契约修复后补拖拽、键盘、VoiceOver 等价路径 |
| AI provider 配置与质量页 | settings/provider-settings/strategy/learning-rules/quality | 先解决 B06 自动执行冲突，再补完整设置页 |
| 首次启动/空账本引导 | auth/system/accounts/categories | 补 passphrase 未初始化与空账本路径，不虚构云账户 |
| 报销 draft/pending/reopen/void 等完整状态 | 六态及完整生命周期路由 | 按真实 action/preview 矩阵补稿 |
| 信用周期详情 | cycle 详情 + 分页 transactions | 按后端五态及金额字段补稿 |
| Dynamic Type AX3–AX5 实际重排 | 前端职责 | 以金额不折行为硬约束补全逐屏布局 |
| 动效/转场 | 前端职责 | 只用于状态转换，不用动画掩盖提交结果 |

## 5. 已确认一致、可直接沿用的契约

以下内容已经与当前 Backend 对齐，不需要因本清单推翻：

- Account kind：`cash / debit / credit`。
- Transaction kind：五类可手工创建；`installment_fee / installment_refund / reimbursement_receipt` 为服务端拥有的系统类型。
- Transaction source：`manual / system / ai_text / ocr / legacy_import / cash_flow / statement_import`。
- Credit cycle 五态：`open / settled / partial / unpaid / overdue`。
- Reimbursement claim 六态：`draft / pending / partial_received / received / cancelled / partially_received_cancelled`。
- Cash-flow direction、五态、monthly recurrence 与手工/系统来源区分。
- Statement import 九态、五种 resolution、部分确认且每次所选行原子提交。
- Spending 七口径均由服务端返回；`personal_realized` 可作为 UI 默认镜头，但必须保留口径标签。
- 信用账单日、分期、报销 cancel/receipt、导入确认等已有 preview 的操作，应严格执行 preview 失效和重新决定。
- 金额为 CNY minor units、业务日期 Asia/Shanghai、API 时间戳 UTC。
- teal/yellow/ink/gold、深色模式映射、字号、间距和状态视觉语法不与后端冲突，可作为新 Design System 的直接输入。

## 6. 27 屏施工可行性摘要

| 屏幕组 | 当前结论 |
| --- | --- |
| 启动门 | 可做，但移除“密钥过期”，保留无效/撤销、离线、not-ready |
| iOS 今日队列 / macOS 需要决定 | 部分可做；Attention 可接，统一未来事件和离线待同步需先解决 B02/B05 |
| 记一笔 | 在线流程可做；离线入队不可做 |
| AI 文本速记/提议 | UI 可做；必须先决定 B06 自动执行 |
| 账目搜索与交易详情 | 搜索可做；修订历史和完整来源链被 B07 阻断 |
| 账户/信用周期 | 数据可做；信用周期高保真补稿仍缺 |
| 分期 | 大部分可做；补 `completed`，按真实 preview/result 字段重画示例 |
| 报销 | 大部分可做；必须按 C06 的真实 preview 矩阵重画 |
| 现金流 | 手工项可做；系统派生项先冻结 C07 |
| 报表/未来时间轴 | 当前只能做 v1.4 报表；完整 v1.5 被 B01–B04 阻断 |
| 对账 | 主流程可做；checkpoint deep link 需补接口 |
| 账单导入 | 大部分可做；修正后台继续、凭证和 attention 表述 |
| 待同步队列 | 当前不支持，建议从 v1.5.0 范围移除 |
| 主数据/AI/数据安全 | 部分可做；合并拆分、排序并发、AI 自动执行、导出凭证需先处理 |

## 7. 已批准的决策表

用户已于 2026-08-14 确认以下项目全部采用推荐选择。推荐项以当前产品原则、数据正确性和最小风险为依据。

| # | 决策 | 已批准选择 | 结果 |
| --- | --- | --- | --- |
| D1 | v1.5 是否包含 P30–P34 后端契约建设 | **包含，先后端后前端** | 已批准；交付真正的 v1.5，而非 v1.4 换壳 |
| D2 | v1.5.0 是否做离线写入队列 | **不做，保持加密只读快照** | 已批准；移除 i-16 和待同步镜头，写入离线时禁用并解释 |
| D3 | AI 是否允许自动执行 | **不允许，服务端关闭并废弃自动执行** | 已批准；与“提议必须人工确认”一致 |
| D4 | 账户/分类永久删除是否进入 UI | **仅归档；永久删除只留维护或零使用错误项** | 已批准；避免把 archive 与 delete 混为一谈 |
| D5 | 系统派生报销现金流能否覆盖金额 | **不能；金额跟随报销事实** | 已批准；后端收窄 override，只允许有限显示字段 |
| D6 | 是否补交易 revision/provenance 读 API | **补** | 已批准；实现交易详情和 macOS 检查器核心区 |
| D7 | 分类合并/拆分采用设计稿交互还是当前后端行为 | **采用设计稿，先扩展 preview/映射契约** | 已批准；高风险操作可预览、可解释 |
| D8 | 普通单笔/批量分类是否保留财务影响预览 | **不保留；原子保存 + 凭证** | 已批准；避免新增低价值 preview 和客户端自算报表 |
| D9 | 本地 PDF 提取离开页面后是否继续 | **不继续，保持临时文件与隐私边界** | 已批准；调整设计文案，不建立后台 PDF 持久化 |
| D10 | Widgets/Spotlight 是否必须进入 v1.5.0 | **核心 App 完成后评估；允许顺延 v1.5.x** | 已批准；与 backlog 的发布门一致，不阻塞 P30–P34 正确性 |

## 8. 正式施工前的下一步

D1–D10 已确认。正式施工前还应先完成一份冻结契约；本次确认本身不代表已经开始施工：

1. 把 D1–D10 的决定写入唯一 `PROJECT_PLAN.md`。
2. 为需要补后端的项目定义 schema、错误、版本、幂等与 data-revision scope。
3. 更新 27 屏字段映射，删掉所有虚构字段和不成立的状态。
4. 冻结 v1.5 新前端目录与迁移门，再开始 clean-room SwiftUI 施工。

在上述确认完成前，不应修改现有前端或开始创建 v1.5 View。
