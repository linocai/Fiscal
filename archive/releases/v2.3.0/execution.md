# Fiscal 2.3.0（43）执行记录

> 2026-09-12 立项并完成｜状态：独立复审完成，R1–R5 待修复，尚未发布｜主入口：[PROJECT_PLAN.md](../../../PROJECT_PLAN.md)

## 1. 需求映射与范围

用户明确授权“进入工作流，修复我们所有 Backlog 列出来的东西”，目标 2.3.0（43）。基线 main `0dab1386b8745298998a5d0245e68a4edb5e9513`。原 Backlog 文字在 `build/v2.3.0-43/preflight/backlog-baseline.md` 保留；以下映射接替旧文中的“下次修复/仅登记”。

| ID | 原反馈与必须交付的行为 | 主要验收 |
|---|---|---|
| B01 | 信用账户增加无息、无固定日期的随借随还；必须归信用欠款，不能用负现金代替；期初欠款有确认日；实际借入与偿还及导入贯通 | 负债归类、资金双边、部分/全还、重复导入、无虚构到期/额度、归档/报表 |
| B02 | 主数据保存失败却以“已保存”呈现；账户字段规则前后端不一致；保存成功后主界面及时更新 | 账户/分类/商户，双端成功、422、网络、冲突、结果未明、输入保留与防重复 |
| B03 | 总览顶部首要数字是现金与储蓄＋滚动30日预计入账－滚动30日预计流出；待入账前置，净额/总欠款退为辅助 | 起止日期、同revision、来源明细、部分收付/提前还款、去重、未知说明 |
| B04 | Mac“记一笔”的灰色矩形原生选择/日期/保存控件与现有风格不符；类型/账户/分类等少量选项直接平铺 | 与已认可绿色视觉对照；可见选择、禁用/悬停/焦点，多选项/窄窗口；同类表单扫查 |
| B05 | Mac交易账户切换藏在左上角且依赖小下拉；需顶部显著的大按钮直接切换；接受现有默认账户 | 入口、选中状态、账目/金额同步、快切竞态、溢出布局 |
| B06 | 一次性处理已出账、未出账和未到期分期，输入银行实扣和日期，核对手续费/减免；预览后一次完成 | 金额拆分、整组原子/幂等/恢复、未来事项消除、原历史保留 |
| B07 | 还款输入显示剩余应还，超额中文显示输入/待还/差额；不显示取数失败＋原始英文＋无效重试 | 普通/随借随还/全结清边界，校验与网络失败区分 |

不增加自动预测、预算、利息计算或新借款产品体系。用户取消了真实借款录入；全部验证使用合成数据，不创建生产账户/账目。当前不部署后端、不替换 `/Applications/Fiscal.app`、不发布标签、不生成 IPA。已发布 2.2.1 的事实保持在其原发布记录。

## 2. 基线事实与技术决定

- `db/models/account.py` 的 `kind_configuration` 与 `api/p4_schemas.py::CreditAccountSummary` 均强制额度/账期；`services/credit.py` 为每个信用账户投影当前账期，不能单靠前端隐藏字段实现无账期模式。
- `services/transactions.py::_validated_postings` 的还款强制 cycle，转账只允许现金/借记之间；新增借入不能冒充收入、信用消费或普通转账。
- `services/installments.py::settle_early` 每个计划自行 commit，且要求锁定账期先结清；客户端串联普通还款和多次结清会留下部分完成，不能作为账户级方案。
- `MasterData/V15MasterDataModel.swift::apply` 把错误写到 receipt，`V15MasterDataViews.swift::editorContent` 一律套成功组件。422 的实际被拒字段未还原，不把推测当事实。
- `CashFlowService.active` 已采用上海今日至今日+29日；`ReportingService._known_future_events` 有账期、报销、手工计划三类来源，内部转账已排除。首页目前用现金−总欠款作大数字。
- `CashFlowService.settle` 当前一笔实际收付即将整个计划设为 settled；要满足“部分完成仅留剩余”的已确认需求，必须补累计关联，不能只修改首页公式。
- Archive 当前只兼容 0038/0039，严格校验实体集合和列集合；新增正式关系表须同步版本适配。预览属于排除的运行数据，金融操作分组/账目关联属于正式历史。

以上为立项时确认的基线问题。以下保留本版实施契约；最终完成结果与验证范围见 §10，实际文件与 Git 为实现事实。无待用户决定项。

## 3. B01 / B02：账户模式、记账与保存

### 3.1 账户模型及 API

沿用 `Account.kind=credit`，扩展 `CreditCycleMode` 为 `statement_day_cutoff | previous_calendar_month | on_demand`，不另建“负现金”或“借款资产”。创建/更新继续使用 `/accounts`，金额字段仍为分。

| 字段 | 固定账期（现有两种） | 随借随还 `on_demand` |
|---|---|---|
| opening_balance_minor | >=0，沿用现有历史规则 | >=0，是欠款正数，不是负现金 |
| opening_balance_as_of_date | 正期初必填有效上海日期 | 正期初必填有效上海日期；零期初可为空，沿用零期初约束 |
| opening_due_date | 正期初必填，且>=确认日 | 必须为空 |
| credit_limit_minor | 必填且>0 | 必须为空，本版不增加额度功能 |
| statement_day / due_day | 必填1–28 | 必须为空 |
| current_cycle / next_due_cycle | 保持现有对象/可空语义 | 均为 null，不创建占位 cycle |
| available_credit_minor / over_limit_minor | 保持现有数值 | null；界面写“不设额度”，不显示伪造0 |

账户 API 的 `current_balance_minor` 保持已有信用账户符号约定；信用 summary 的 `current_debt_minor` 始终是非负欠款。扩展 summary/债务报表 DTO 的额度、日期、current_cycle 为可空，读取端按 mode 分支，固定账期值保持不变。随借随还 `cycles` 返回空页，分期/账期设置入口明确不适用；不得因一个无账期账户使所有信用账户读取失败。

模式在新建草稿可自由切换并清除不兼容字段；已建立财务历史的账户不得用普通 PATCH 切换成另一模式。仅无欠款、无交易、无分期、无被引用账期的空账户可切换，服务端检查并返回中文可解释的模式锁定错误。现有两种固定账期之间仍走既有 schedule-change 契约。正期初确认日前的借入/还款拒绝；报表早于确认日依旧返回未知，不反向补造历史。

### 3.2 借入和还款

新增 `TransactionKind.borrowing`，可通过现有交易草稿/预览确认及账单最终草稿写入：

- `account_id` 为 on_demand 信用账户，`destination_account_id` 为真实现金/借记收款账户；金额>0，`credit_cycle_id/category_id=null`。
- source posting 为信用账户 `-amount`（欠款增加），destination posting 为资金账户 `+amount`。界面文案“借入”，两端角色明确。
- `repayment` 沿用资金账户 source `-amount`、信用账户 destination `+amount`。固定账期必须匹配 cycle；on_demand 必须 `credit_cycle_id=null`，校验当时剩余欠款及全时间顺序前缀不得为负。
- on_demand 不接受 `credit_purchase`，也不能通过普通 income/expense/transfer 绕过借入与还款校验。部分还款合法，全还后可再次借入；没有安排就没有未来到期/逾期。
- 借入/还款本金从收入、消费和内部现金转账统计排除；资金到账/流出仍计实际现金流。信用负债报表、账户净额和导出包含 on_demand 欠款。
- 修改、作废、恢复、幂等重放、导入确认、AI候选/最终草稿必须遵循同一服务校验；有后续还款依赖时不得把借入作废成负欠款。

导入必须能人工核对并选择“借入/还款”、来源及目标账户；无账期还款不得要求选 cycle。原文/AI不能确定关联时保留待确认，不依据金额或账户名自动完成。匹配已存在账目时只关联原记录；重复文件/行/确认重放不得新增同一笔金融事实。无需扩展自动解析模型供应商或新导入格式。

### 3.3 保存状态与校验

将 receipt 分为明确状态（success / validation / failure / conflict / unknown / informational，或等价强类型），界面只对确认成功使用成功标题。适用于账户、分类、商户及映射/排序等同链路消息；不要把“已读取/无关联”也写成“已保存”。

真实日期校验必须使用严格日期解析、年月日回读一致及日期顺序，不能只用正则；金额用 CNYAmountParser，额度0、超界日、负信用期初、on_demand禁用字段、归档引用都在本地指出具体字段，服务端再校验。失败保留草稿，修改输入清旧校验并使预览失效。

成功创建后绑定服务器返回 ID 和版本，刷新账户管理及所有受影响的 ledger/facts/credit 引用；不能保持新建草稿让第二次保存又发 create。结果未明沿用现有 unknown-create 锁和回读恢复，不能把一个同名账户未经身份核对当本次成功，也不发新请求复制。写入确认和本地列表刷新是两个结果：写入已成功但刷新失败时分别说明，不能让用户误以为应重新保存。

## 4. B06 / B07：账户级全额结清

### 4.1 外部契约

新增 `/credit-accounts/{id}/payoff-preview`、`/credit-accounts/{id}/payoff`、`/credit-payoffs/{operation_id}`（读取持久结果）、`/credit-payoffs/{id}/reverse-preview`、`/credit-payoffs/{id}/reverse`。预览复用 `ActionPreviewSession` 的短期 token/输入哈希/revision 思路；结清正式 receipt 不得只放在归档排除的 `action_operations`。

预览输入：`payment_account_id`、`occurred_at`（带时区）、`actual_amount_minor`（允许0，覆盖银行全额减免）、`additional_fee_minor`、`waived_principal_minor`、`waived_fee_minor`（均非负Int64）、`bank_confirmed_settled`（提交必须true）、`note`（差额非0须有核对说明）。提交复用完全相同输入并带 `preview_token` 和 `Idempotency-Key`。

银行核对输入不自动从差值填入手续费/减免。定义 `D` 为本次预览所覆盖的全部账面剩余负债（包含已经入账的分期手续费，不能再加一次未到期总额）：

`actual_amount_minor = D - waived_principal_minor - waived_fee_minor + additional_fee_minor`

总减免不得超过D；手续费减免必须能分配到有证据的剩余费用，没有证据时提示改为核实本金减免/原始账目，不能杜撰手续费余额。金额、账户、日期、银行确认或差额说明任一变化使预览立即失效。银行实扣不满足等式时返回明确错误及 `remaining_minor / input_minor / difference_minor`，不截断实扣、不修改期初欠款凑数。

预览返回：token/有效期/绑定revision、付款前后余额、信用欠款前后值、实扣、已有本金/费用与减免/额外费、逐账期/逐计划拆分、将关闭的未来事项、警告及可执行状态。界面在一个预览中完整呈现，不让用户重复选账期；成功后只有一份账户级回执，并可展开多个内部账目。

### 4.2 原子写入与历史

- `credit_payoff_operations` 保存永久操作ID、目标/付款账户、请求哈希、唯一幂等键、日期、拆分、结果快照、状态与逆转关联；`credit_payoff_links` 把所有生成交易与该操作关联，并记录角色/原账期/计划来源。可在同一表 payload 保留必要 period 原状态，避免额外通用事件体系。preview引用可空/导出时排除，金融关系与结果必须归档。
- 获得既有全局 mutation lock 后先查幂等重放，再校验token、依赖与金额；锁内确定全部账期/计划/源交易，按稳定顺序一次写入，所有子服务必须 `commit=False` 或提取无commit helper，最外层唯一 commit。中途任何异常全部 rollback。
- 既有原始消费、期初、分期本金/费及曾经的还款历史不删除、不改金额。未来有效分期可迁移到本次结清承接位置并标记 settled_early，完整保留原计划/period及可逆快照；账期映射不能虚构银行到期日。按实际结清日期校验负债已经发生；如存在结清日期之后的账目导致无法证明全部结清，提示核对，不能逆改后续事实。
- 正常本金部分仍生成 repayment postings，可按cycle分摊；明确减免生成仅作用信用账户的系统债务调整，额外手续费生成资金账户实际费用。建议系统 kind 为 `credit_principal_waiver`、`credit_fee_refund`、`credit_settlement_fee`；均禁止手工普通交易入口直接创建。principal waiver 不计收入/消费，fee refund 冲减费用且非现金，settlement fee 计实际费用/现金流；所有参与 cycle/invariant/history/report 计算，不允许只在显示层改零。
- 剩余本金/费用的分摊必须确定且可复现：优先明确关联的费用来源，再按账期应还日期、cycle/period稳定ID分配；任何不能无歧义核对的费用减免给出差额说明，不悄悄摊成消费退款。
- 成功后本次覆盖的欠款、剩余账期、活跃未到期分期和相应未来应还均为0；付款账户只减少银行实扣，借入/还款本金不计消费。所有revision、快照和links在同一事务中产生。
- 断网/取消/重启后使用持久写入日志恢复原token+请求+key；成功receipt查询和同key重放在token过期后仍能返回原结果。相同key不同输入冲突，重复预览/不同key也不能重复结清已清负债。
- 生成子账目不能独立改/作废；提供整组撤销预览/提交（账户详情回执入口）。仅无后续依赖时按快照整组恢复，重放幂等；有后续还款、分期/账目修改或归档依赖时明确拒绝并保留现状，不能部分恢复。此处用于记错账恢复，不执行真实银行退款。

### 4.3 普通还款提示

普通还款显示当前所选cycle剩余或on_demand总欠款。客户端输入超额即时中文：“剩余应还 ¥X，输入 ¥Y，超出 ¥Z”；服务端预览及提交同步返回结构化数值，不能将生命周期前置债务错误误映射成纯超额。真实网络错误使用读取/重试状态；金额校验使用字段错误与“修改金额/核对差额”，不显示原始英文。全额结清入口用于跨账期实扣，不放宽普通还款为任意超额。

## 5. B03：滚动30日与来源完整性

### 5.1 读接口与时间边界

扩展现有 `GET /reports/facts`，新增 `disposable` 对象：`date_from`、`date_to`、`current_cash_minor`、`expected_inflow_minor`、`expected_outflow_minor`、`projected_balance_minor`、`undated_inflow_minor`、`unscheduled_credit_debt_minor`、`overdue_outflow_minor`。在原facts同一revision读取边界计算，不由客户端拼接不同时间请求。

窗口固定为上海今日00:00至第30日结束，即今日至今日+29日，含两端；显示准确日期，每天午夜及回前台重新读取。流入/流出包括有效日期内 confirmed/expected/scheduled/exact_due 全部剩余事项，界面保留确定性标签。未来事件分页须与顶部revision绑定，不能用截断事件数组汇总出一个少算的数字。优先复用并统一现有 `_known_future_events` / future分页 / cash-flow active 的源规则，避免三套不一致公式。

主数字包含已登记且有预计日期的工资/计划收入、报销剩余到账、计划支出、剩余信用到期应还；无计划不推测消费。当前现金仅现金/借记余额，借入资金真实到账后已在其中。欠款总额/账户净额/待收报销总额作为辅助信息；预计入账和预计流出有可打开的明细，顶部并列呈现三个组成。

无预计日期报销、无安排on_demand欠款及窗口前未处理逾期应还单列说明（不伪造日期、不悄悄当未来零风险）。读取失败或必要数据不完整显示不可用/上次快照标识；旧服务器缺新增字段时新客户端显示“此指标需新版服务”，不能自动退回现金−信用欠款。所有加减用checked Int64，溢出不得崩溃或截断为0。

### 5.2 完成、部分完成和关联已入账

- 系统credit cycle和报销来源金额始终来自原始负债/回款的剩余值；override只影响允许的展示/预计安排，不把一个仍有欠款的来源直接“完成”成0。同一来源键只出现一次，分期余额与cycle不重算两遍。
- 手工计划新增 `cash_flow_settlement_links`：`id`、`item_id`、唯一 `transaction_id`、`closes_remainder`、`created_at`，关联正式账目而不另造余额。累计完成金额按有效关联账目的方向/金额读取，剩余=max(原计划−累计,0)；一笔交易只归属一个手工计划，不能再与报销/信用系统来源重复认领。
- 迁移/Archive适配把旧 `linked_transaction_id` 回填为一条 `closes_remainder=true` 的关联，保留历史一次结算关闭整项语义；旧列保留兼容，不重复计累计值。后续新结算由links为权威，旧列只保留兼容最近/唯一关联。
- 现有 settle 请求加 `complete_remaining: bool`，为旧客户端缺字段保持旧行为true；2.3.0 对小于剩余的实际收付默认false，并提供明确“本次已完成全部”选项。大于剩余允许真实差额但必须展示核对，不制造负预测；原计划金额保持可追溯，不能减小原计划伪装累计。
- 增加 `/cash-flow/items/{id}/settle-existing`：`expected_version`、`transaction_id`、`transaction_expected_version`、`complete_remaining`，带稳定幂等键。只关联经人工核对的已正式入账交易（含导入），校验资金账户/方向/来源归属与金额；不再创建交易。新UI在计划入账处可选“记录本次收付”或“关联已有账目”。
- 部分完成保留active剩余；全额/显式关闭才settled。作废/恢复/编辑关联交易通过现有settlement生命周期链重算，版本和读模型一致更新；重复请求返回原结果，不新增links或账目。计划变更不可低于已完成金额而不经显式收口；已有关联时限制会破坏归属的方向/资金账户修改。
- 不靠相似标题/相同金额自动判断重复；有系统来源的还款/回款走原来源入口。手工计划关联同一已入账交易时禁止双认领。确需另建还款安排时必须有显式来源绑定；本版不从无安排借款自动制造未来计划。

## 6. B04 / B05：双端界面

- 复用 `V22PageComponents.swift`、`V15Controls` 与当前色板，增加可复用可换行选项组/大按钮选择组件。记录页的类型、来源/目标账户、分类，账户编辑模式，信用还款及现金流等同类Mac表单按空间使用该组件；与金额/账务状态模型解耦。
- Mac日期使用与现有表面一致的可点击日期显示＋明确日历选择，不暴露突兀的窄步进器；保存/预览按钮统一既有ActionButton风格，含禁用原因、hover/focus/键盘导航/VoiceOver。
- Mac交易页顶部单独明显账户切换区，当前账户及可切换账户直接可见，保留默认进入现有选中/默认账户；选项多时换行或水平滚动并确保选中项可见。不要仅把原下拉箭头放大；切换账户后标题、过滤、金额、选中账目与派生数据同步收敛。
- iOS按屏幕保持菜单/紧凑选择，但新增模式、借入/还款、全结清和首页指标必须功能一致，sheet内错误可见。
- 先在合成fixture做一屏实际渲染样板，再扩到同类控件；验收实际页面可见性，不把AX存在当可见。截图包括Mac正常/窄窗口、多账户、记录表单、全额结清预览与错误、双端总览；只用合成财务数据，不把用户截图私密内容写进Git。

## 7. 施工 ownership 与先后关系

主会话分配以下四块；各builder不是独占代码库，不还原他人改动。跨owner变更通过消息/精确patch交给文件所有者；同一Swift大文件、同一个迁移不可多人同时改。

| Owner | 独占写入范围/责任 | 第一步与依赖 |
|---|---|---|
| K 核心金额后端 | Backend除F清单外；账户/credit/transactions/installments、借入/还款/全结清API/DB、导入AI/最终确认、archive、migration、核心测试；`api/dependencies.py`及路由注册统一归K | 落§3/§4模型/schema与迁移；将最终可空字段/交易kind/错误结构通知C、F。0040统一收拢本版DB变化，F提供cash-flow模型定义后合入；archive最终适配要等所有正式表齐全 |
| F 预测与现金流后端 | `services/reporting.py`、`repositories/reporting.py`、`services/report_exports.py`、`services/cash_flow.py`、`repositories/cash_flow.py`、`db/models/cash_flow.py`、`api/p7_schemas.py`、`api/p13_schemas.py`、`api/p34_schemas.py`、`api/routes/cash_flow.py`、`api/routes/reports.py`及本块测试；可新增本域小模块 | 落§5剩余事件/links/DTO，立即把DB定义交K；消费K的新kind和mode。若report路由实际文件名不同先定位同责任文件，勿改K账务服务 |
| C App契约与状态 | `V15/Foundation`、所有V15业务Model（非View）、写入日志/transport/错误映射、FixtureTransport、V15 FiscalKitTests；V15共享DTO均归C | 先新增on_demand/borrowing、可空summary及payoff/disposable/cash-flow契约，再实现状态模型；把面向View的可用属性/方法通知U |
| U App界面与交互 | V15全部View/AppShell/DesignSystem、RootSmoke/Gallery视图和UI测试，新增UI组件 | 先做Mac记录页选择组件样板及顶部账户切换；其他UI接C契约。不直接改Foundation/Model，需增行为交C |
| 主会话集成与兼容 | `App/project.yml`、生成工程、V15目录外的旧Domain/Data/Features与相应旧模型测试、统一门禁与本记录 | 施工时由C明确交接旧模型兼容，防止新增枚举/可空字段使导入适配器或旧缓存解码失败；不与C/U抢写 |

`App/project.yml`、xcodegen/版本与最终工程文件由主会话统一集成，新增源文件各owner通知主会话。Apple编译/测试和所有使用同一PG的pytest由主会话统一排队，禁止builder各自并发构建/truncate。无关格式化/自动生成噪声不进入交付。若实际人手调整，主会话明确重新划定ownership，不隐含抢写。

K/F可并行写各自服务，C/U按本契约并行准备，但最终schema或公共方法变化必须同步。K的单次原子金额写入不能拆成不同builder在同文件的交叉修改。共享接口明确后即可开工，不再要求用户批准常规工程选择。

## 8. 迁移、归档、兼容与回滚

- 预定单一 Alembic `20260912_0040`，down_revision=`20260910_0039`；修改account/transaction约束，增加payoff正式表、cash-flow关联表及必要索引/关联，回填旧单次cashflow结算，保留现有固定账户和账期原值。最终模型表列以K/F同步后的实现为准，禁止两个Alembic head。
- 当前版本常量/readiness/Archive head同步0040。Archive显式支持0038→0039→0040及0039→0040：先认证并按源schema校验，再在副本添加新空实体/回填有证据关系，再校验新schema和外键；0038原有mapping_generation回填继续保留。新账目种类、payoff分组/拆分/撤销与cashflow links完整round-trip，原文件字节不变。
- 新App必须能读取旧的固定账户/旧缓存；新增可空值不能全局force unwrap。旧客户端对on_demand的限制需作为后续发布协调风险记录，不能为了旧DTO制造假账期/额度；本轮不在生产创建新mode。后续发布必须后端与双端共同验证后协调上线。
- 隔离库从空库upgrade和0039合成旧数据upgrade均验证；无新增域数据时可downgrade回0039再upgrade。存在on_demand、新kind/金融关系时downgrade明确拒绝，不能删除新数据恢复旧约束；实际发布回滚使用发布前一致备份/匹配代码，不对已写新模型的库盲目降级。
- 预览session不进Archive；payoff永久结果和金融关系可恢复，归档恢复后原已完成操作重放/查询不应生成第二笔。必要删除短期preview外键值不能删除正式关系。

## 9. 验收矩阵与门禁

所有业务验收在 `fiscal_v230_43_tests_20260912` 与RootSmoke合成数据完成。pytest autouse会清空共享库，执行前后协调API/fixture，避免边跑测试边用UI写同库。

1. **B01**：创建零/正期初on_demand，日期与非法字段边界；借入→部分还→全还→再次借入；前日期/超额/同账户/错类型拒绝；修改/作废/恢复不越过债务前缀；固定账期回归；credit列表/首页/报表现金流/消费/导出符号正确；导入新建及匹配已有/重复文件/确认重放均唯一。
2. **B02**：账户/分类/商户双端的成功、字段422、冲突、服务错误、网络响应丢失及结果未明；新建成功第二次操作不重复创建；草稿保留、可改重试、刷新失败不否认已确认写入、返回主界面显示新账户。
3. **B03**：跨月底/年末/闰日/上海午夜的今日..+29边界；窗口内外事项、报销部分回款、手工部分/全额/差额完成、关联导入已有交易、关联作废恢复、多来源去重、内部转账、无日期/无账期及逾期说明；全部分页合计=顶部，同revision冲突正确失效，Int64边界和缺失服务不伪零。
4. **B04/B05**：Mac可見平铺选择与顶部账户大按钮真实点击，默认选中保留；快速切换不串账，窄窗口/多账户/键盘/禁用焦点；实际截图逐屏比对认可风格；iOS功能不被桌面条件编译遗漏。
5. **B06**：仅已出账、含未出账、多计划/部分已还、零/正手续费、费用与本金减免、全部减免、用户实扣不匹配、结清日期早于负债、账户归档；预览后源改变、两个并发提交、重复key异输入、token过期已成功重放、中途故障注入保证0或全部生效；金额总和/负债/分期/未来项核对；整组撤销无依赖成功、有依赖拒绝且不部分回滚。
6. **B07**：0/非法/超额输入与后端剩余改变；中文金额三项准确；网络重试只用于真实网络错误；任何输入变化清预览且未发送请求不复用旧token，已发送请求稳定恢复。
7. **迁移/归档**：空库与0039升级、0038/0039Archive双路径适配、0040正式数据导出恢复、非法实体/FK/新域数据降级拒绝；现有归档测试不回退。
8. **工程**：Backend完整pytest与Ruff/格式/Pyright；FiscalKitTests完整；iOS generic Simulator与macOS App target必须xcodebuild；关键RootSmoke真实场景截图/交互。Apple串行`-jobs 2 -parallel-testing-enabled NO`，复用已有DerivedData和主模拟器，无clean/新模拟器。

## 10. 完成结果与验证证据

### 完成范围

本版 B01–B07 全部实现，未主动延期、未扩大为自动预算或银行支付功能。目标 2.3.0（43），实施起点为 main `0dab1386b8745298998a5d0245e68a4edb5e9513`。本次完成实现与本地验证，不代表已独立复审或已发布。

| 范围 | 已完成结果 |
|---|---|
| B01 | 信用账户 on_demand、真实期初确认日、借入/无账期还款、严格债务时间前缀、导入与 AI 最终草稿、信用详情/报表/归档全链路；不生成假额度或账期。 |
| B02 | 账户/分类/商户成功、校验、失败、冲突及结果未明明确区分；新建绑定服务器 ID，失败保留草稿，成功后通过 revision 刷新；严格真实日期和引用校验。 |
| B03 | 双端顶部使用同 revision 的滚动 30 日可支配余额与来源明细，未知日期、无安排欠款及逾期单列；手工计划支持部分收付、关联已有账目、重放及作废恢复。 |
| B04 | Mac 记录、账户、信用、现金流及导入同类表单改为可见可换行选择；日期、保存、预览统一现有设计组件。保留 iOS 紧凑选择。 |
| B05 | Mac 交易页顶部独立账户按钮区，选中状态清楚；多数账户限定高度并滚动至选中项，23 账户/1000px 暗色窗口验证；全部时间入口直接可见。 |
| B06 | 账户级一次原子全额结清、费用/减免核对、永久回执、原请求恢复、整组撤销及依赖保护；已出账/未出账/剩余分期共同处理。 |
| B07 | 普通还款及结清的中文金额校验、输入变化失效、预览过期禁用；iOS sheet 错误自动滚入安全可读区域。 |

### 最终门禁

日志根目录为 `build/v2.3.0-43/qa/`，均为本轮本机证据。重复复测不叠加到全量测试数量。

| 门禁 | 最终结果 | 证据 |
|---|---|---|
| Backend 全量 pytest | **459 passed**；包含真实隔离 PostgreSQL posting、并发/故障回滚、导入重放、迁移和归档 | `backend-full-2.log` |
| Backend 静态检查 | Ruff、262 文件格式检查通过；Pyright 0 errors / 0 warnings | `ruff-final.log`、`format-final.log`、`pyright-final.log` |
| FiscalKit 全量 | **450 tests / 42 suites passed** | `fiscalkit-2.log`、`fiscalkit-2.xcresult` |
| 最终客户端专项 | **14 passed**，属于上述 450 项；最后 fixture/界面调整后复测 | `macos-final.log`、`macos-final.xcresult` |
| macOS 实际 App target | **BUILD SUCCEEDED**，FiscalmacOS Debug / platform=macOS | `macos-final.log` |
| iOS 实际 App target | **BUILD SUCCEEDED**，FiscaliOS Debug / generic iOS Simulator，arm64 与 x86_64 | `ios-app-final.log` |
| Mac 相关 UI | **6 个不同场景通过**：长期时间范围、23 账户窄窗、结果未明恢复、记一笔/切换账户、预测明细、结清→回执→整组撤销 | `mac-ui-2.log` 中 4 项通过；修复另 2 项断言后 `mac-ui-3.log` 2 项通过 |
| iOS 相关 UI | **2 passed**：总览预测/明细、结清 sheet 校验完整位于安全区 | `ios-ui-2.log`、`ios-ui-2.xcresult` |
| 产物/工作区 | 双端 Info.plist 均 **2.3.0 /43**；6 个预存 scheme 原字节保留；309 个 Backend 文件与最终门禁 hash 快照一致；6 个新增 Swift 源文件已加入工程；diff 空白检查通过 | `built-product-versions.json`、`backend-verified-hashes.json`、`verification-state.json` |

Backend 有 1 条 Starlette/httpx 依赖弃用提示；Apple 测试编译存在未使用返回值/多余 await/测试宏 actor 隔离警告，另有未依赖 AppIntents 的元数据跳过提示。上述不是门禁失败，本记录不宣称全工程零警告。旧基线 31 项测试及中间重跑只用于定位，不计入最终数量。

UI 使用隔离 RootSmoke bundle 与合成 fixture，截图和点击验证真实 SwiftUI 窗口；业务写入正确性由真实隔离 PostgreSQL 测试验证。未用用户生产账本进行端到端写入，未做 iOS 真机安装或本轮生产迁移演练。部分专项 UI 在失败修复后定向复跑，通过范围按上表逐项合并，不将中间有失败的整批日志描述为全绿。

### 关键集成修正

- 0040 除 API/模型外同步替换旧延迟 posting shape 校验函数，否则无账期借入/还款会被数据库拒绝。迁移前校验并排空已有延迟触发事件，随后恢复延迟约束；不禁用约束绕过存量错误。
- 旧 cash-flow 单次结算和历史 revision 关联回填为明确的关闭剩余记录；取消、金额修改、作废/恢复重算均保留原行为，避免把历史完成项重新计算成欠额。
- 归档先按来源版本认证、校验，再在副本补新正式关系；0038/0039 原文件不变。0040 有新域数据时拒绝直接降级，回滚必须使用一致备份。
- 新交易枚举/可空信用字段同步覆盖非 V15 兼容模型、AI 草稿和导入适配器；避免仅新界面编译而旧入口崩溃。
- Mac Layout/父容器标识传播曾覆盖子按钮可访问 ID，已限定容器并保留子控件身份；NavigationStack 根标识不稳定的测试改为真实内容标题与窗口位置断言，未删结清/撤销业务断言。
- 截图发现日期窄列换行、月份重复菜单和 iOS 错误贴近底部后已修复；iOS 增加错误完整 frame 的安全区断言。预览过期只在到期点唤醒视图，不进行每秒整页重绘。

### 截图核对

以下均为合成数据的应用窗口原图，来自上述 XCTest attachments；不包含用户截图或整桌面录屏。已人工查看布局、金额、选中状态与错误位置，保留供本版复审。

| 页面 | 原图 |
|---|---|
| Mac 顶部 30 日余额 | [mac-overview.png](screenshots/mac-overview.png) |
| Mac 记一笔可见选择 | [mac-record-choices.png](screenshots/mac-record-choices.png) |
| Mac 顶部账户切换 | [mac-account-switcher.png](screenshots/mac-account-switcher.png) |
| Mac 23 账户窄窗/暗色 | [mac-account-overflow-dark.png](screenshots/mac-account-overflow-dark.png) |
| Mac 全额结清预览 | [mac-payoff-preview.png](screenshots/mac-payoff-preview.png) |
| Mac 预测来源明细 | [mac-forecast-detail.png](screenshots/mac-forecast-detail.png) |
| iOS 顶部 30 日余额 | [ios-overview.png](screenshots/ios-overview.png) |
| iOS 结清表单校验 | [ios-payoff-validation.png](screenshots/ios-payoff-validation.png) |

### 接班与发布边界

实施交接时 B01–B07 均已实现；后续独立复审的待修复项见 §11。用户六个 scheme 的原有未提交修改必须继续保留，版本实现提交应排除这些文件。资源/原字节与最初 Backlog 快照位于 `build/v2.3.0-43/preflight/`。所有本轮 PostgreSQL 测试使用 `fiscal_v230_43_tests_20260912` 串行执行；Apple 构建串行、`-jobs 2 -parallel-testing-enabled NO`，复用既有 DerivedData 与主模拟器。

金额和迁移实现与本地验证完成后，主会话建议独立复审；随后用户已要求并完成本版复审，见 §11。后续修复须逐项复查；如请求一条龙发布，先核对生产实际 revision 和 0040 依赖，按既有发布路径备份、迁移、验证后协调双端更新。当前尚未部署、推送发布标签或替换 `/Applications/Fiscal.app`，用户取消的真实借款未录入。

## 11. 2026-09-12 独立复审：1 个 P1、4 个 P2 待修复

用户在实施提交完成后明确要求“做一次独立复审”。由未参与方案/实施的独立 reviewer 执行，主会话负责版本证据核对及指定边界复现；本轮未修业务代码、未发布。审查固定范围为已发布源码 `60efa4b3c7e932967e1754ad9fd42b5cbf8a5882` 至 `22c3cb68d4560a7c05c83fc8f52b90f2d875265f`。部署源码至实施基线 `0dab1386` 仅文档不同，业务累计差异完整包含。六个预存用户 scheme 改动排除且原字节保留。

| ID | 严重度 | 定位（目标提交行号） | 已确认触发/影响 | 修复及复查要求 |
|---|---|---|---|---|
| R1 | **P1** | `V15/Features/Settings/MasterData/V15MasterDataModel.swift:338`；同类类别344、商户269 | 保存A挂起时Mac列表仍允许切到B；A成功回包无上下文守卫地把选择切回A，字段却是B草稿。再次保存把B名称和期初金额写入A，可能改变错误账户的余额。 | 捕获编辑会话/generation，迟到响应仅更新对应记录，不抢当前选择或草稿；账户/分类/商户横向修复。复查延迟成功/失败、切换及二次保存的目标ID。 |
| R2 | P2 | `V15/Features/Settings/MasterData/V15MasterDataModel.swift:238,340` | 未知PATCH结果回读只对比名称/期初金额/周期模式，漏额度、账期日与期初日期。请求额度200000分、服务仍100000分，却显示“已确认保存成功”。 | 对本次提交的全部字段及相应版本进行确认；证据不足保持结果未知。逐一覆盖被遗漏字段。 |
| R3 | P2 | `Backend/src/fiscal_api/services/reporting.py:727–730` | 旧固定信用账户有欠款但两期初日期NULL：债务接口能标记配置缺失，disposable只按额度为空识别未排期，漏掉此类欠款提醒。现金1000000分、欠款500000分时三项caveat均0。 | 披露无周期覆盖的旧欠款/配置缺口，预测明确说明尚未纳入；不补造到期日，也不把全部负债直接扣入30日数字。 |
| R4 | P2 | `Backend/src/fiscal_api/services/credit_payoffs.py:502–506` | 三期中首期8/22正常还清，9/1提前结清剩余两期时，首期也被写入9/1 settled_early_at，状态由cycle_settled变settled_early，改写已完成历史。 | 提交前确定实际仍有余额的期，仅标记本次提前关闭的期；已还清期及撤销后的历史应保持。 |
| R5 | P2 | `V15/Features/Credit/V15CreditPayoffView.swift:143` 与 `Backend/src/fiscal_api/services/credit_payoffs.py:664–670` | 真实API撤销回执把after改为原欠款却保留before；共享UI再交换二者。实际欠款0→20000分，回执显示20000→20000。余额恢复正确，回执展示错误；fixture仍保留D→0，掩盖契约差异。 | 统一永久撤销回执前后值语义，使用真实API JSON验证双端展示；不要仅修改fixture让测试自洽。 |

App 定位均相对 `App/Sources/FiscalKit/`。完整审查覆盖 B01–B07 代码、测试、工程变更及直接调用边界，包括资金写入/失败回滚、迁移/归档、幂等恢复和双端状态。没有以风格偏好列问题。

验证：两个临时 Swift probe 直接链接目标已构建 FiscalKit.framework；隔离 PostgreSQL/真实 HTTP 三个缺陷断言按预期失败，另一个候选通过并排除（全部正常还清的计划仍保持 completed，不被后续结清改写）。[精简复现证据](qa/independent-review-reproductions.json) 保存实际请求/输出及框架哈希；临时脚本/原日志在 `build/v2.3.0-43/review/`。以上仅合成数据，无生产财务写入。

既有459后端、450客户端、8项UI及双端构建记录已核对，本轮没有重复全套；这些通过结果不能覆盖本次新增边界。UI原有证据使用FixtureTransport，尚无真实后端驱动实际App的完整结清/部分收付/恢复验收。本次复审已完成，**R1–R5均未修复，不能作为发布通过结论**；后续修复应保留当前固定审查范围，并对修复及影响范围重新复审。


## 12. 2026-09-12 R1–R5 修复与复查

用户明确要求“直接修复”，沿用尚未发布的 2.3.0（43）；修复起点 `3f79bdb61466bed59cfc63ec89296466d7ad2ea1`。不修改生产财务数据、不安装 App、不部署服务。

| 项目 | 修复结果及新增边界 |
|---|---|
| R1 | 主数据账户/分类/商户的选择与草稿具有编辑 generation；迟到成功仅刷新服务器事实，不抢新选择/草稿。失败、冲突、未知结果及归档/恢复采用同样归属检查；确定成功仍刷新全局 revision。 |
| R2 | 未知 PATCH 回读跳过账户缓存，校验目标 ID、版本前进和全部提交字段（含额度、账期日、期初日期与显式 null）；证据不足维持 unknown，不重发写入或猜测新建 ID。 |
| R3 | 提醒金额按每个信用账户实际欠款扣除全部已知账期覆盖金额计算，包括窗口外/逾期账期，披露旧固定信用账户缺期初日期的余额；双端明确“尚未确定还款日期的信用欠款（未计入以上预测）”。不伪造日期、不全额扣入 30 日数字。 |
| R4 | 提交前根据实际剩余分配确定本次关闭的账期与分期期次；已正常还清期不写提前结清日期、不改版本，撤销只还原本次保存的期次。完全付清计划不纳入关闭清单。 |
| R5 | 永久回执统一为完成时 D→0、撤销时实际 0→D；后端核对真实欠款，双端直接展示前后值，fixture 与重放同步遵循契约。真实 PostgreSQL HTTP JSON 作为客户端资源经过解码及服务/模型链验证。 |

新增主数据专项含 6 个测试函数、56 个参数场景；真实回执契约 2 项；后端旧欠款提醒 5 项、结清历史/回执 4 项、归档撤销状态新增 1 项。初轮全量客户端发现旧商户测试模拟 PATCH 成功却回读相同 version=2，已将成功回读修为 version=3，原断言和严格版本守卫保留，并恢复既有“已确认商户”提示。

日志位于 `build/v2.3.0-43/repair/`。后端针对性 26 项、全量 **469 项**通过；Ruff 与 270 文件格式检查通过；Pyright 指定项目 `.venv/bin/python` 后 0 errors / 0 warnings（首次未指定环境的依赖解析错误不计为通过）。两个原始独立复现 Swift probe 已重新链接修复框架：迟到 A 响应后保持 B 的选择/草稿且二次 PATCH 为 B；未生效额度修改显示 unknown。

当前下一步：完成修复后客户端全量、双端 App 构建和实际回执界面验收，再对固定修复提交交原独立 reviewer 复查。正式通过结论在本节后续结果中记录。


复查固定 `3f79bdb` → `4d2b67570aaa6befeba22be4d9a07a300901bb58` 时，独立 reviewer 确认 R2–R5 可关闭，但 R1 新建期间仅修改字段会丢失已创建身份。独立 probe 已确认原补丁连续两次 POST（期初 10000/12500 分）。补充区分 editorSessionGeneration 与字段 generation：同一会话成功绑定服务器 ID并保留新输入，显式切对象/新建草稿仍隔离；新增三类对象 POST→PATCH 回归。补充后 **FiscalKit 459 tests / 44 suites 全量通过**（`client-full-3.log`），原 probe 为一次 POST 后同 ID 的 PATCH（`new_draft_identity-after.json`）；独立 reviewer 将对新固定提交复查此项。
