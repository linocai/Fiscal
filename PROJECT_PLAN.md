# Fiscal · PROJECT_PLAN

> 控制面版本：v1.3.0 施工版 ｜ 更新：2026-08-11 ｜ 状态：P21 已完成 Automated / Production / macOS + Kurisu 读取链路验证；真实余额 checkpoint 写入须由用户提供余额后验收。P22 可开始施工。异地备份未配置为 carried risk，真实告警已延期
> 本文件只保留现行目标、决策、门禁与下一步；历史实施证据以 `docs/qa/p*/results.md`、发布 tag 与 Git 为准，不从本文件追写。

## 1. 当前事实与 P20 审计起点

- 仓库检查时：`main...origin/main` clean，HEAD=`cdc4037`；`v1.2.4^{commit}`=`7c221ec`，不是 HEAD；`apple/project.yml` 为 `1.2.4 (Build 20)`。
- `README.md` 仍称 P11 进行中并描述 device token；P18/P19 QA 记录、旧大计划和当前 HEAD/Build 有漂移。它们是待核验证据，**均不等于当前生产事实**。
- P19 记录过 transition 鉴权、`access_credential` 与 `device_tokens` 过渡；后续 Build 18–20 快修记录又暗示不同状态。P20 必须通过受控生产查询、已安装 App 与精确 revision 重建事实，禁止臆测或把旧记录直接改成“完成”。
- 历史 PostgreSQL 全量组合测试曾有 11–13 个失败；P20 必须以 fresh DB/head 重新测量并清零/逐项修复，不能继续以“既有失败”作为 v1.3.0 发布豁免。

## 2. 发布列车与不可变规则

- P20→P21→P22→P23 是同一发布列车：最终唯一版本为 **v1.3.0 / `CURRENT_PROJECT_VERSION=21`**。P20 的首个可构建批次统一升版本；之后所有候选包都保持 1.3.0 (21)，不得再占用 Build 22。
- 四期全部完成，且自动门禁、生产验证、macOS + 实体 iPhone **Kurisu** 验收、稳定观察均闭环前：**不得创建 tag、不得 push**。中间只做小而可回退的本地 commit；部署仅允许来自已提交的精确本地 revision。若受控部署无法在不 push 的前提下完成，先停下请求用户裁决。
- 最终顺序：冻结干净树 → 记录所有 QA 证据 → 创建 `v1.3.0` annotated tag → `git push origin main v1.3.0`。不建 P20/P21/P22 阶段 tag，不追标历史 P18/P19 tag。
- 每批 commit 必须可编译、范围单一、附自动验证；提交后把 revision/命令/结果写入该期 `docs/qa/pNN/results.md`。不重写历史、不 reset、不以未提交文件部署。
- 稳定边界：仅 CNY、单人私用；VPS PostgreSQL 是唯一正式真相源，双端原生 SwiftUI 按 `design_handoff_fiscal_app/` 视觉合同实现；不做登录/多人/投资。
- 统一账本、正式流水、posting、金额精度、业务服务是唯一金额真相；AI、Attention、导出、缓存与客户端状态均为派生层，不能绕开正式服务或私自改余额。
- 每个数据库变更均需：upgrade/downgrade/re-upgrade、fresh DB、影子恢复/金额对账、旧客户端读取兼容与生产前验证备份。数据库 head 不同不得用应用 rollback；改从已验证备份恢复到隔离新库后切换。

## 3. 范围、顺序与共同验收

| Phase | 主题与依赖 | 本期交付 | 明确不做 |
| --- | --- | --- | --- |
| P20 | 可信基线；前置 | 可审计生产/发布/恢复基线、鉴权收口、测试债务清零 | 新业务模块、历史账本重写 |
| P21 | 依赖 P20 | 账户/账期余额核对点、差额诊断、Attention Center | 独立会计对账系统、自动平账 |
| P22 | 依赖 P21 | 可恢复 Fiscal Archive、全局 revision、保守离线 | 现有库合并导入、离线写入队列、实时推送 |
| P23 | 依赖 P22 | AI 原始判断/修正/结果闭环、质量与策略 | AI 聊天、模型训练、绕过正式记账 |

- 每期结束有三类独立证据：Automated Verified（测试/迁移/构建）、Production Verified（精确 revision 的备份、部署/冒烟/数据对账）、Physical Device Verified（macOS 与实体 iPhone Kurisu 真机主链路、截图）。四期后另有 Observed Stable 观察期；任何一步不得替代另一步。
- 全局自动门禁基线：锁文件、格式/静态检查、默认与 fresh PostgreSQL 全量测试、Alembic SQL/往返、Swift 单测、iOS/macOS Debug 与签名 Release 构建、签名验证、相关 UI/视觉回归。具体命令与计数只在本轮实测后记录，不能沿用历史数字。
- 用户网页操作清单：无固定网页 URL。需要人手的受控动作见 P20（自选/输入访问口令、解锁并安装 Kurisu）及各期生产部署授权；凭证绝不进聊天、命令参数、git 或 QA 记录。

## 4. P20 · 可信基线收口

**目标**：证明正在运行什么、能否安全发布/恢复，并删除已经完成迁移的过渡层；不把文档修订当成生产验证。

**当前状态**：P20 按用户裁定通过：`81d5881` 已部署至生产、Alembic `20260811_0020`，自动与隔离恢复门禁已通过，旧 device-token 兼容层及表已移除，macOS 与 Kurisu 的新包均已连通生产。真实告警接收器由用户明确延期，不阻塞 P21；异地副本 provider 仍未配置，作为 carried risk 进入后续阶段，不得写成已完成。

- **P20-A 事实审计（先做）**：只读采集生产 release commit、Alembic head、鉴权模式/凭证行/旧 token 是否仍可用、备份/异地副本/告警接收器状态、macOS 与 Kurisu 的实际 bundle/build/连接结果；逐项与 HEAD、tag、README、P18/P19 QA 比对，写成带时间和命令的 P20 证据。任何冲突先标风险，不猜测修复结果。
- **P20-B 发布状态源**：将 README 改为入口说明；新增短的 release manifest/状态契约（生产 revision、DB head、App build、鉴权、设备、备份/恢复/告警最近证据、开放门禁、回退点），并将历史细节保留在各期 QA。状态仅由实际证据更新。
- **P20-C 鉴权最终态**：先由用户在已装 App 安全设置/确认访问口令；证明 macOS 与 Kurisu 能以 access key/口令连接、改口令使旧 key 401、忘记口令 CLI 恢复可演练。仅在此门通过后，移除 device-token 表/model/config/认证分支/迁移桥与遗留文档；最终只保留 personal passphrase + generation access key。
- **P20-D 发布与恢复**：修复 fresh PostgreSQL 全量组合测试及顺序污染；建立不可豁免的发布状态机和 exact tag/commit 对应关系；配置并实际送达 API、备份、恢复、磁盘告警；完成加密异地副本、保留期、隔离恢复及账本/posting/关键汇总对账，记录 RPO/RTO 和人工 runbook。
- **P20-E 领域风险收口**：将“平账”从名称匹配改为稳定领域属性且保留历史口径；账户账期设置与其派生变更使用单一事务，预览列出 old/new 日期、受影响账期和逾期变化，禁止静默重排已逾期债务。
- **契约/兼容**：P20-A/B 不能声称已改生产；鉴权移除是一次不可逆 migration，旧客户端将明确 `authentication_required` 而非降级；平账迁移以稳定 ID/属性回填，名称可改、历史流水及账户影响不变。
- **施工提交**：A 审计与证据 → B 状态源/版本 1.3.0(21) → C 测试基线与领域修复 → D 鉴权最终迁移 → E 备份/告警/恢复收口；每个 migration 与应用切换分开 commit，均不打 tag。
- **验收/回退**：所有全量门禁绿；生产事实能从 manifest 重现；异地 dump 恢复到隔离库后 head、数量、posting 与汇总一致；真实告警送达；macOS 与 Kurisu 核心录入/查看成功。认证/迁移失败立刻回到同 head 的旧应用；head 不同则从验证备份恢复新库，绝不盲目 downgrade。
- **决策门与风险**：必须先完成用户口令/Kurisu 动作，才可删除旧鉴权；远程生产写操作在执行时另取授权。最大风险是历史状态漂移和单机备份伪装成 DR，P20 不闭环不得进入 P21。

## 5. P21 · 账户核对与财务关注中心

**目标**：使账本能被现实账户余额验证，并把现有待办/异常收敛为一个派生入口。

**当前状态**：`4686e44` 已部署，生产 head `20260811_0021`。影子 0020→0021、账本/posting/余额/报表守恒、备份、服务 smoke 及 macOS + Kurisu 的核对读取/导航均已验证；生产没有虚构真实余额。用户真实余额输入后的 checkpoint 写入验收仍保留，P22 工程可开始。

- **范围**：为现金/借记/信用账户及信用账期提供按时点的核对记录；显示账面额、用户输入真实额、差额、状态、备注和创建信息；差额区间诊断；账户/账期内历史；跨领域 Attention Center；iOS 快速核对/处理，macOS 历史/差额分析。
- **核对契约**：`checkpoint` 永不改 ledger/posting 或覆盖账户余额。账面额按核对时点和业务时区可重复计算；状态只有 open（有差额）与 reconciled（差额为零）。修正必须走普通正式流水，确有余额调整时走显式 `balance_adjustment` 语义、来源为核对、从消费报表隔离，禁止生成隐形“平账”。已归档账户只读历史。
- **诊断与 Attention 契约**：候选仅提示待归类、近期编辑/恢复、重复金额时间窗、AI 自动执行、跨时点交易、信用/还款归属和期初缺失，不能自动判错。Attention 是服务端派生 read model：稳定 `source_type/source_id`、severity、金额/日期、解释、建议动作、双端深链和到期忽略；只汇集余额差异/久未核对、待归类、AI 待确认/失败、信用/现金流逾期、报销逾期、运维异常，不复制任何状态机。
- **接口与迁移**：新增 checkpoint/attention 读写 API 和新表；现有账户、流水、信用、报销响应只追加字段。差额按服务端计算，客户端不得二算；新表无历史余额回填，首次核对是用户锚点，旧客户端可继续使用。
- **施工提交**：A schema + 余额重算 service/测试 → B checkpoint API/差额诊断 → C Attention 派生 API/失效规则 → D iOS/macOS 流程、深链和视觉回归 → E 生产迁移/真实样例 QA。
- **验收/回退**：同一时点账面余额重复计算一致；任何 checkpoint 不改变账本；补录/编辑后差额重算；零差额记录可追溯；Attention 无重复且深链正确；两端以现金、借记、信用、归档、差额/零差额样例验证。迁移后回退按 P20 规则；可禁用新入口但不删核对证据。
- **风险/门**：期初余额、时区、信用“欠款/账单余额”语义和余额调整口径须在 API 契约测试中锁死；Attention 不得成为第二真相。真实账户样例、生产核对和双端真机通过后才进入 P22。

## 6. P22 · 数据自主与一致性框架

**目标**：用户可完整、可验证地恢复数据；任意正式写入后双端可确定收敛。

- **Fiscal Archive v1 契约**：独立导出密码、加密 payload、版本化 manifest（archive/API schema、导出时间、业务时区/币种、DB revision、实体计数、哈希、AI 原文包含标记）；覆盖账户/分类、ledger/postings、信用/账期/还款、分期、报销/回款、现金流、P21 checkpoint 和必要的 ID/幂等/来源关系；明确排除口令哈希、access key、provider key、环境变量与敏感运行日志。
- **恢复契约**：选择→解密/哈希/兼容检查→dry run（数量/金额/关系报告）→用户确认→只写入空库/隔离新库→全量一致性验证→切换。v1 禁止合并导入和覆盖现有账本；AI 原始文本默认不出档，只有显式选择才含入加密档。
- **数据 revision 契约**：服务端持久化单调 `data_revision`，每次已提交的正式 mutation 原子增加一次；响应以兼容的 header/metadata 返回 revision + 受影响 scope（ledger/accounts/credit/reimbursements/cash_flow/reconciliation/attention/reports/ai），并提供只读当前 revision 端点。客户端前台/写入后按 scope 刷新，不靠手工 fan-out 猜测；旧客户端忽略新增信息仍可读写。
- **离线边界**：只显示加密的最近只读快照及数据时间/离线标识，可保存未提交草稿；联网后须用户确认，绝不后台重放、不建冲突队列、不把过期快照伪装成最新余额。
- **施工提交**：A archive 格式、密码学/manifest/导出测试 → B 隔离恢复与损坏/兼容测试 → C revision schema、服务端 mutation receipt → D 双端 scope 收敛/离线只读与草稿 → E 生产恢复演练与 QA。
- **验收/回退**：完整档→空库恢复后数量、余额、负债、报表和 P21 核对一致；篡改/错误密码/不兼容必须写入前失败；档案无秘密；并发/跨端写入后 revision 单调且页面收敛；离线不产生正式流水。Archive/revision 均为新增兼容层，回退应用不破旧数据；导入切换失败保留原库且不触碰。
- **风险/门**：密码学实现、部分导出和导入可用性是高风险，先审计库/格式选择再编码；必须在隔离恢复和双端 revision 回归通过后才进入 P23。

## 7. P23 · AI 质量闭环

**目标**：把 AI 提案的原始判断、人工修正、执行结果和策略效果变为可测量、可回溯、可自动收紧的安全闭环。

- **数据契约**：每个提案保留不可覆盖的原始输入、首次结构化 parse snapshot、最终确认值及字段级 diff；另记录 unchanged/edited confirm、ignored（可选原因）、execute failed、automatic/manual execute、undo、provider retry/final failure。旧提案不伪造历史，标为 `historical_unavailable`。
- **隐私/领域边界**：原文与快照仅留在 Fiscal 数据库/显式加密 archive，不送第三方分析；质量事件不可编辑且不是面向用户的复杂审计产品。AI 只能调用手工录入同一正式服务、相同校验/幂等/撤销，不能直接写 posting。
- **指标与策略**：按来源、模型/提示词版本、交易类型、金额区间计算解析成功、无修改确认、字段修改、忽略、失败、撤销、自动撤销、延迟/错误率；策略版本化并记录生效时间。来源/类型的阈值可不同；样本不足不提权，新模型/提示词先跑脱敏 shadow corpus；异常率只能自动收紧/关闭自动执行，放宽需用户确认。
- **确定性学习**：仅建立可见、可撤销、需重复证据的 merchant→category、标题→账户、分类别名/来源上下文规则；绑定稳定 ID，不自动创分类、不以单次修正永久改变行为，不训练或微调外部模型。
- **施工提交**：A snapshot/diff/event schema 与旧数据兼容 → B 质量聚合/API/隐私测试 → C 策略版本与自动降级 → D 双端提案解释、规则管理与指标 → E shadow corpus、端到端真机 QA。
- **验收/回退**：可还原 AI→修正→正式记录链；指标分母守恒；策略版本/生效时刻可查；新模型无评估不得替换；异常可自动降级；OCR/快捷指令→提案→确认/自动→流水→撤销在两端真机完成。关闭自动执行或回退策略不删除事件；schema 回退按 P20 规则。
- **风险/门**：原文隐私、错误统计和自动化扩大风险最高；必须完成 P22 archive/revision、shadow 回归和生产观察，才可允许最终发布候选。

## 8. v1.3.0 收口、决策与恢复入口

- **最终发布门**：P20–P23 的所有状态必须为 Observed Stable；fresh PostgreSQL 全量零失败；生产 exact revision/head/备份/恢复/告警证据齐；macOS 与 Kurisu 在生产连通下完成核心录入、核对、导出恢复、AI 链路与截图；README、release manifest、App build、tag 指向一致。任一缺失即只保留 commits，不打 tag/push。
- **观察期默认值（可翻案）**：生产部署后连续 7 天无 P0/P1 数据正确性、鉴权、恢复或自动执行事故，且每日备份/告警健康，才满足 Observed Stable。
- **可翻案默认决策**：P21 只做账户/账期内核对，不做独立对账中心；零差额才 reconciled；P22 只支持空库恢复、独立档案密码、只读离线；P23 只做确定性学习且策略只自动收紧；所有默认值可在相应 Phase 的编码前调整，但变更须更新本文件与 QA 契约。
- **尚需用户动作（非方案决策）**：P20 执行时安全地设定/确认访问口令、解锁并配对 Kurisu；涉及生产写入、部署、迁移或恢复切换时，由用户按当时风险单独授权。无其他产品方向待拍板。
- **Backlog（明确不插队）**：投资/订阅、泛化附件、AI 聊天、多人协作、实时 WebSocket、离线写入队列、复杂导入合并、更多仪表盘。它们不提升当前可信性，不进入 v1.3.0。
- **恢复顺序**：先读本文件 → `git status --short --branch` → P20-A 的最新 QA 证据与生产 manifest → 再决定下一批；若事实不一致，停在审计，不以旧聊天或历史计划覆盖现场。
