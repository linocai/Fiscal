# V2.2.1（42）审计修复施工契约与执行记录

> 2026-09-10｜当前权威入口：[PROJECT_PLAN.md](../../../PROJECT_PLAN.md)。本记录承载本轮详细契约和验收证据；事实以当前文件与 Git 为准。

## 1. 目标、授权、基线与事实边界

- 用户在独立只读审计后指定“2.2.1（42），进工作流修复所有问题”。本轮包括 A01–A17 缺陷、A18–A21 四条架构优化，全部需要完成或以具体反证纠正原 finding，不能默认为建议而移入 Backlog。
- 已授权实施、本地/隔离验证及沿原审计范围复查修复。未请求本版本一条龙发布；不推送、不打发布标签、不生产迁移或业务写入、不替换已安装 App、不生成 IPA。
- 源码基线：main，`5a4991fc65e3326e411fcc96c9abfd7ec4b9bde4`；App 为 2.2.0/41；Alembic head `20260831_0038`。对外版本与 build 均由用户确定为 2.2.1/42。
- 唯一既有工作区改动为六个共享 scheme；用户原字节备份/hash 在 `build/v2.2.1-42/preflight/baseline.json`、`build/v2.2.1-42/preflight/schemes/`。xcodegen 后从这些备份恢复，绝不执行泛用 git checkout，且不暂存这些用户改动。
- 本轮唯一可迁移/truncate 的 PostgreSQL 库：`fiscal_v221_42_tests_20260910_103154`。测试 URL：`postgresql+asyncpg://linotsai@/fiscal_v221_42_tests_20260910_103154?host=/tmp`，通过 `FISCAL_TEST_DATABASE_URL` 显式传入；不得继承生产或其他现有财务库 URL。后端测试共用此库，统一串行调度。
- Apple 复用现有 DerivedData、ModuleCache 和主模拟器；准确路径/设备/磁盘前值在 `build/v2.2.1-42/preflight/runtime.json`。所有 xcodebuild `-jobs 2`、串行、关闭并行测试/克隆，不新增模拟器/runtime/DerivedData、不全局 clean。
- 主会话已取得基线：97 项后端相关 PostgreSQL 测试通过（`preflight/backend-baseline.log`）；46 项 Apple F1A/F3B1/F4A 测试通过（`preflight/apple-baseline.log`）。均只属修复前基线，不能作为 A01–A21 修复证据。
- 规划核实事实：`V15PendingWriteStore` 使用 UserDefaults 明文；`OfflineSnapshotStore` 才有 CryptoKit/Keychain 加密基础。`StatementPDFEvidenceExtractor` 已支持文本层、Vision OCR、逐行边界与脱敏。正式依赖目前构造 Synthetic parser；AI service 已有存储凭据及 OpenAI-compatible HTTP 实现。`CashFlowItemRevision.snapshot` 保存历次 `linked_transaction_id`，可以追溯旧入账而无需另造平行历史表。
- 假设/验证边界：不假定生产 AI 已配置或特定模型一定支持结构化输出；本轮采用真实适配器与本地 HTTP stub 验证。实际账户/凭据只通过既有设置解析，不读取输出秘密，不把真实财务资料发给外部服务。待用户决定项：无。

## 2. 稳定编号与逐项完成矩阵

表中“待实施”由 builder 替换为结果和精确证据，不无限追加状态；代码定位为基线入口，不把文件名当封闭改动清单。

| ID | 原问题/入口 | 本轮应实现的行为与验收 | 状态 |
| --- | --- | --- | --- |
| A01 / P1 | RecordModel `inputChanged`/`dismiss` 释放在途 key | 发送前持久化不可变请求；在途输入/关闭不释放归属，不允许同一未决草稿用新键再提交；成功回执不会被输入 generation 丢弃。延迟响应中改名称/备注、连续保存、关闭重开及终止进程后恢复，服务端始终仅一笔。 | 通过：V221Client/F1A、P31 receipt、R2→R5 |
| A02 / P1 | CashFlow.settle 覆盖关联，Transaction.restore 无历史归属检查 | 历次关联可追溯；作废→重结算后恢复旧交易必须 409；新交易也作废后，可在无其他有效入账时恢复一笔并同步事项。并发恢复/重结算仍最多一笔有效，版本/历史与回滚完整。 | 通过：P13 PG、R1 |
| A03 / P1 | ArchiveService.export 逐表读取不同快照 | 独立只读一致快照读取实体、data_revision、Alembic revision；封装前验证关联。真实 PG 两连接交错写入时产物可解密、dry-run、空库恢复，实体来自同一时点。 | 通过：归档并发 PG、R1 |
| A04 / P2 | Bootstrap retry 未释放主壳 | 初次连接、口令提交和重试统一处理 server-ready/offline-read-only 成功；失败后成功仅一次放行，失败不提前放行，两端可进入主空间。 | 通过：双端 RootSmoke retry |
| A05 / P2 | ReportingModel 展示变化使 report generation 失效 | 报表读取与 drill/page/export 分别持有请求归属；读取中切透镜可结束加载，旧明细不串入新透镜；取消和错误也按归属收尾。 | 通过：V221Client/F4A、R2 |
| A06 / P2 | Installment replacement 旧消费账期必须开放 | 已锁定前缀及原消费保持不变，允许重排/延长合法未来未锁定后缀；首账期自然过去不再阻断。预览和 commit 同规，跨日后重新验证，金额总和与尾差精确一致。 | 通过：P5 午夜 PG/指纹、R1→R2 |
| A07 / P2 | Mac 交易月份固定近四个月 | 保留近月快捷项，增加任意年月/全部时间；搜索明确沿用所选范围，切范围清分页和选择。能查到并编辑四个月前交易及跨年结果。 | 通过：Mac 月份/全部时间 UI |
| A08 / P2 | iOS 已分类交易无修改入口 | 所有可编辑且类型允许的交易可设置/更改分类，复用服务、版本及方向校验；作废/只读/未知类型不放开。手机选错分类可更正，失败在 sheet 内展示。 | 通过：iOS 已分类交易 UI |
| A09 / P2 | 双端分析期末余额取绝对值 | 余额使用带符号安全格式；负、零、正和 Int64 边界在总览/明细/导出一致，信用欠款不误用现金余额符号。 | 通过：V221Client 负余额、R2 |
| A10 / P2 | `_period_credit_debt` 忽略 opening as-of | 按 §3.3 表达已知/未知；基准前及缺基准的非零欠款不伪造金额。9 月基准对 8 月/月初/月末/年报覆盖；双端与导出一致，build41 保留明确兼容错误而不接收 null。 | 通过：历史余额 PG/导出、R1 |
| A11 / P2 | PDF 真链路：脱敏计数/Synthetic/错误 ID/旧 version | 用正式逐行证据+专用解析器，授权元数据来自后端；区分 attempt/provider-attempt/validated-result snapshot。文本与扫描 PDF 经正式 HTTP 得候选→复核→人工确认入账；超时、错误 JSON、无候选均真实展示。 | 通过：PDF/OCR→HTTP 真链、R3→R5 |
| A12 / P2 | 同 PDF 重选无条件 startExtraction | 按后端 recovery 状态续办；已接受证据不重提，已成功解析不重收费调用，review/partial 直接恢复；过期授权和仍处理中明确可恢复，unknown 不新建 key。 | 通过：provider/原 key 恢复、R3→R5 |
| A13 / P2 | partial_confirmation 剩余行不可编辑 | review/final draft/preview/confirm 同一状态矩阵；已确认行冻结，剩余行仍可补齐和继续确认。首批确认后修改余行，再确认不重复写首批。 | 通过：部分确认 PG/真链/模型、R3→R5 |
| A14 / P2 | 现金流 drill 只显示消费三数，后端现金金额错误 | external cash 为现金/借记有效 posting 之和，排除内部转账；收入/还款/信用消费/报销/退款用相应指标。过滤范围的明细合计与摘要一致，收入为正、还款为负、信用消费现金影响为 0。 | 通过：report facts/PG、R1 |
| A15 / P2 | merchant mapping 删除重建版本回到 1 | 使用交易所属持久单调 generation，释放也推进；重建后旧请求始终版本冲突，原 key 重放只取原 receipt。迁移回填最大历史代次，两设备 ABA 覆盖。 | 通过：P31 ABA/0039 PG、R1 |
| A16 / P2 | 旧分类 merge 直接 reassign 绕版本与历史 | 旧 merge 复用受保护交易移动实现和同一锁顺序；每笔版本/revision/usage-count/data_revision 一致；旧客户端持有 transaction version 不能覆盖合并，新旧接口结果相同。 | 通过：P31 merge 历史 PG、R1 |
| A17 / P2 | 登录先 KDF 后限流，阻塞 event loop | KDF 前先原子消耗尝试配额；口令校验/修改所需 KDF 进入有界线程工作，网络/health 不被计算阻塞；耗尽后请求不执行 KDF，401/429/Retry-After 与新旧密钥有效性正确。 | 通过：限流/KDF 回归、R1 |
| A18 / 优化 | 记账/还款/导入分散的未知结果恢复 | §3.1 共享加密 journal + kind-specific receipt resolver，复用到本轮四条关键提交链，保留 offline allowlist。持久化失败阻止发送、legacy 迁移不丢条目、logout/切服务不跨账本重放，跨重启恢复可达。 | 通过：V221Client/F3G/真链、R2→R5 |
| A19 / 优化 | 导入复核全量 N+1、全局锁；信用重复完整展开 | §3.5 按候选日期/金额批量匹配，锁外准备锁内复核；cycle 批量加载相关 period/plan，请求内一次展开；交易验证减少无关全历史查询。小/大数据差分金额相同，query/lock 对照有证据。 | 通过：规模/锁前/revision/批量 PG |
| A20 / 优化 | 报表参数上限、缓存无界、旧档绑定精确版本 | §3.4/3.5 支持 32,765+ source IDs 且无单条参数爆限；LRU/字节/条数/过期缓存界限有效；实际由基线 0038 生成的旧档可按受支持路径恢复并迁至新 head，旧档不修改。 | 通过：32768 来源/LRU/0038 兼容 |
| A21 / 优化 | 组件测试缺少真实契约/异常组合 | 补 Swift 编解码与正式路由同源 fixtures、真实本地 PDF、PG 并发/迁移、在途/跨期/部分成功续办覆盖。旧错误契约测试须更新；一次全套门禁和修复复查封口。 | 通过：§8 全部门禁及复查闭环 |

## 3. 跨端与高危契约

### 3.1 不可变写入与跨会话恢复（A01/A18）

1. 扩展现有 PendingWriteStore 为统一 journal 的表现/入口，持久层独立于读缓存；复用 CryptoKit AES-GCM、Keychain key 的既有模式，但使用独立文件和 key namespace，不能复用会吞掉错误/淘汰条目的读缓存存储逻辑。
2. 持久项至少保存：本地 item ID、server/profile scope、kind、schema version、创建时间、原始序列化请求、原 idempotency key、必要 resource ID/preview token、状态与恢复信息；不存密码、access key、provider key、原 PDF 或未脱敏证据。原请求和 key 不可因输入变化重写。
3. 先原子持久化，再发送。inFlight 在进程恢复后成为 outcomeUnknown；网络断开/取消/解码失败不等于服务未写入。存储失败或解密失败必须显式报错并禁止依赖日志的发送，不能静默初始化空队列或退回明文。未知项不因容量淘汰或普通关闭删除。
4. legacy UserDefaults 队列按原 ID/request 一次迁入；只有加密写入并回读验证成功后删除 legacy 键。`.queued` 保持离线队列语义；历史 `.syncing` 按 unknown 恢复。迁移遇损坏保留原数据，提示处理，不输出内容。此为格式迁移测试，不操作当前用户真实队列。
5. A01 当前编辑器的在途/unknown 请求锁住该草稿的提交；UI 可禁用编辑，模型层仍必须抵抗程序写值。关闭只脱离 UI；回执交给 journal 并触发受影响读取刷新。新一笔与旧未决草稿必须是显式独立意图，不能通过改备注隐式发新 key。
6. 普通创建新增 authenticated `GET /api/v1/transactions/by-idempotency/{key}`（放在 `/{transaction_id}` 路由前），返回原创建快照 `TransactionResponse`，不拿后续修改状态伪装原请求结果；200 为已确认，404 `transaction_operation_not_found` 仅表示尚无持久回执，不能推断原请求未运行。读取 no-store。
7. 明确重试普通创建时只允许使用原 key 和原 payload；服务继续校验同 key/hash、原子防重。还款沿用 `GET action-operations/{key}`；导入确认沿用 confirmation-receipt；解析沿用 provider-attempt 查询/重放。receipt 未找到时保留 unknown，可在原契约允许下显式同键重放，不能自动获取新预览后继续提交。
8. 将记账、还款、导入 provider attempt 与 confirm 接入同一 journal；各 resolver 保存必要的原版本/授权/request。离线仍只允许既有普通创建/分类变更，preview-dependent 写入不扩大离线能力。切服务/账号或退出登录后不自动跨 scope 重放；重新认证同一 scope 后恢复入口仍可见。
9. `F1ATests.swift` 当前把 unknown 后编辑释放 key 当作通过标准，必须改成新契约；测试旧行为失败、修复后通过，不能保留错误断言而弱化本轮目标。

### 3.2 账本保护、映射代次与分期（A02/A06/A15/A16/A17）

- 现金流归属查询先查当前关联，再按 `CashFlowItemRevision.snapshot.linked_transaction_id` 查历史；依靠现有不可变历史，不靠名称/金额猜测。所有 settle/void/restore 使用相同全局 mutation lock 和 item/transaction 锁顺序。restore 在清 voided_at、生成 posting/revision 之前检查该事项当前是否另有有效关联；冲突码 `cash_flow_settlement_superseded`，返回可供重新读取的事项/当前交易 ID。无其他有效关联且事项仍允许入账时，恢复历史交易同时切回当前链接、settled 状态并写事项 revision；已取消事项须按既有流程重新确认，不能因恢复交易静默撤销用户取消。无法唯一定位历史来源则 fail-closed，报告数据问题；不批量猜测修复既有账本。
- mapping 使用 `transactions.merchant_mapping_generation` 非负整数，当前 mapping.version 等于其有效 generation；confirm 新建/替换和 release 在事务内推进 generation。无 mapping 时客户端原 `expected_mapping_version` 的“缺失”语义不改，服务仍从持久 generation 生成新版本。release 删除 mapping 也保留 generation；回放旧 idempotency key 取既有操作 receipt，不再执行。迁移从当前 mapping 和 MerchantOperation receipts 可识别的最大版本回填，避免历史旧请求复活。
- 由单一后端负责人维护 `20260910_0039`（down_revision=`20260831_0038`）：mapping generation 及本轮有依据的必要索引；无需新建平行 cashflow 历史表。迁移与 A20 归档兼容一起评审/测试。若实现发现必须新增其它字段，先在本节补明确定义，不并行抢编号。
- 分期 replacement 保留已锁定前缀原数据；固定金额、消费日期、起始日等既有锁定规则保留。仅在真正改变原消费归属且无锁定前缀时使用 create 的开放账期 eligibility；原消费未改时用 suffix eligibility，全部新增/重分配期不得写入已关闭或已锁定范围。preview/commit 同算，跨午夜或另一设备变更后拒绝过期预览；不能简单删除日期检查。
- 旧分类 merge 采用新 `_move_transactions` 的版本/历史写入和 usage-count 处理，避免双加双减；同方向/层级/子分类冲突规则保留。不能仅关闭旧接口规避已授权修复，也不需要改 UI 路由。
- 登录及改口令在执行任何口令 KDF 前消耗有界“尝试”配额，沿用已有配置数值、不新增用户需要决定的限额；成功也计一次尝试，不在失败分支重复计费，现 access-key 鉴权失败规则独立保留。sync KDF 使用有界线程执行及队列/并发控制，不把 AsyncSession/ORM 操作移到线程。等待/取消不突破并发界限；修改口令的 hash 生成亦需覆盖。单 worker 假设保持，无关的分布式限流不在本轮。

### 3.3 报表事实与旧客户端兼容（A05/A09/A10/A14）

- build42 请求 `/reports/v2/...` 时明确发送 `X-Fiscal-Report-Balance-Semantics: as-of-v1`。后端响应同名 header 表示支持；header 纳入读缓存 key/HTTP Vary。build42 对缺少能力回显的旧后端明确显示“服务需更新”，不静默采用旧历史余额。核心页面可继续使用不依赖该能力的读取。
- 只有显式 opt-in 响应可把 summary 的 `credit_debt_at_period_end_minor` 与受影响账户的 `opening_balance_minor`/`closing_balance_minor` 设为 null。summary 新增 `credit_debt_at_period_end_status: known|unknown`、`unknown_balance_account_ids: UUID[]`、`balance_unavailable_reason: string?`（总额未知为 `historical_basis_unavailable`）；accounts 每项新增 `opening_balance_status`/`closing_balance_status: known|unknown`、`balance_as_of_date: date?`、`balance_unavailable_reason: string?`（`before_opening_as_of`/`opening_as_of_missing`）。known 值必须有整数、unknown 值必须为 null，原因在 known 时为 null。Swift DTO、聚合与导出接受 null，并把总债务含未知账户传播为未知，不能只把已知部分相加冒充总额。
- 无 header 的 build41/旧 V1 请求：全部已知时仍返回原整数响应形状；一旦存在无法确定的历史余额，返回现有 APIError 格式的 409 `historical_balance_unavailable`，说明需要新版查看明细，并带缺口上下文，不发送 null、不返回假 0。这是明确的兼容边界；旧客户端显示已有错误反馈，不能伪称其完整支持未知展示。
- 基准为 `opening_balance_as_of_date` 的上海业务日：截至时点早于该日则未知；该日起按现有 opening + 有效 posting 规则算，不重复计入基准前数额。非零 credit opening 缺基准日期时未知，不用 `created_at` 猜生效日；零 opening 延用现有完整账本假设。月初与月末分别判断，年报同规。账户历史缺口不应阻断当期收入/支出等仍可确定的指标（新客户端可分项显示）。
- 报表展示改变只清理 drill/page/export 自己的 generation；period/data revision 改变才使主报表失效。每个请求的成功/失败/取消均按所属 token 收尾，旧结果不得清新请求 loading。
- external_cash_amount_minor：非内部转账交易对 cash/debit 账户 posting 的带符号总和；credit posting 不属于现金流。transfer 外部现金为 0，其内部流入/流出保持单独统计；账户筛选时使用与摘要一致的账户范围，避免整笔交易泄漏其它账户现金。收入、还款、退款、报销各按原始 kind 和实际 posting 展示，不用消费三数套全部明细；支出透镜保留消费/退款/净消费口径。
- 期末现金余额必须保留负号；共同 formatter 使用 Int64 安全幅值逻辑，不能 abs(Int64.min) 溢出。JSON/CSV/其他报表产物使用同一事实规则，未知显示空值加原因，绝不写数字 0。

### 3.4 真实账单导入与安全恢复（A11/A12/A13/A18）

- 正式客户端改用已有 `StatementPDFEvidenceExtractor` 和 redactor；按行记录 source/page/bounding-box。PDF 原文、截图、未脱敏文本留本地临时生命周期。仅敏感字段替换为 `[REDACTED]`，保留真实日期/交易金额；redaction_count 等于将发送的 pages 文本中 `[REDACTED]` 次数，不能用行数或所有数字数替代。文本、扫描、混合、多页/上限、密码保护/取消测试复用现有规则。
- 后端新增 `GET /statement-imports/{id}/provider-authorization`，读取最新 batch/evidence + 既有 AI 配置，返回 batch_version、configured、provider/model、prompt/schema/redaction version、evidence_sha256、page_numbers、row_count、redaction_count 与待授权外发的非秘密说明。未配置时不构造 Synthetic，返回明确未配置及既有设置入口所需状态；不注册新付费服务。
- POST authorization 允许正式 `openai_compatible` 身份和实际配置 model，服务逐字段比对当前配置与证据；配置/证据变化返回 409 `statement_provider_authorization_stale`，要求重新展示并由用户授权。不得把未经授权的新模型替换入已存请求。
- 新建 statement 专用 OpenAI-compatible adapter，复用既有 base_url/model/凭据解密/HTTP timeout、响应大小和日志脱敏规则，独立 schema/prompt。只把 `StatementProviderOutboundRequest` 的脱敏证据发送；使用现有 `/chat/completions` 传输边界，校验 `StatementProviderResult` 和全部 source refs、金额精度、日期、未知字段，不能让 provider 猜账户后自动记账。Synthetic 仅允许测试注入/显式 fixture，不进入正式依赖。
- 无配置/连接错误/非法 JSON/无有效候选必须是真实失败或需要人工处理状态，不伪装成功空列表。网络调用在数据库写锁释放后进行，结果写回重新校验 attempt/batch 归属；本轮验证用本地 stub，不擅自耗用实际付费模型或真实账单。
- ProviderAttemptResponse 保留 `attempt_id`（本地/服务解析尝试）、`provider_attempt_id`（解析调用记录），新增 `provider_snapshot_id: UUID?`（validated_result）。成功必须有 snapshot，使用响应继承的 batch.version 更新本地，再调用 validation_run；禁止 UUID(provider_attempt_id) 充当 snapshot 或用解析前 version。
- 新增 authenticated `GET /statement-imports/{id}/recovery`：返回最新 batch、`next_action`、evidence digest/count、active local attempt ID、latest provider attempt/status/validated snapshot ID、validation_run_id、是否存在已确认行/confirmation 状态。配套固定 `GET /statement-imports/{id}/provider-attempts/by-idempotency/{key}`，复用 ProviderAttemptResponse 返回持久状态（无回执 404 不能被当作未执行）。`next_action` 取 `extract|authorize_provider|recover_provider|validate|review|completed|read_only`，失败另带原因；unknown next_action 在客户端只读。均 no-store，不回传凭据/原 PDF。服务根据自己的数据计算下一步，客户端不靠过期本地 phase 推测。
- 同 SHA register 返回既有 batch 后先读 recovery：created/合法失败本地提取才 startExtraction；已有 accepted evidence 直接预览授权；成功 provider 直接 validation/review；review_required/ready_to_confirm/partially_confirmed 直接加载最新 workbench；confirmed 展示结果，abandoned 按现有规则只读。仍 started 的 request-bound attempt 使用服务进程内任务归属登记（先登记再持久化 started）；活动 owner 存在时返回处理中并查原 key，不能另启调用。退出/取消按原 attempt 标失败；服务重启后无 owner 的遗留 started，在显式同键恢复 POST 中持锁核对并标记 `statement_provider_interrupted` 后返回失败，确定结束后才允许新的授权。GET recovery 保持只读，不自动后台无限重试。
- 一次解析意图或确认意图的原 key/request/version/授权保存在共享 journal；重选 PDF 只帮助匹配 digest，不代表新外发授权。重试只用原授权；需要新 attempt 时必须先让原状态终结并展示新的授权。
- DraftResolutionPut、FinalCreateDraftPut、preview 和 confirm 接受 review_required/ready_to_confirm/partially_confirmed 的可编辑余行，已确认/已有 receipt item 的行永远拒绝编辑或重复入账；使用 row/draft/batch 各自版本，修改余行立即失效旧 preview。确认首批后读取新版本，下一批单独意图/key，已确认条目不重新选中。

### 3.5 一致归档、规模上限及性能（A03/A19/A20）

- Archive export 在认证之外开独立只读 REPEATABLE READ 事务；隔离级别在第一条业务 SELECT 前设置，不能在已因认证 SELECT 开始的普通 session 上补设或 rollback 调用者 session。所有实体、data_revision、Alembic revision 同快照；不持有全局 mutation lock 直至压缩/加密完成。关系、重复主键和 schema 校验在返回文件前完成；失败不交付半有效归档。
- 归档继续保留现有加密 envelope、安全排除项及 provider_reconfiguration_required。新增 schema 字段意味着不能简单取消 entity/column/revision 检查。为 `20260831_0038` 基线归档建立显式、确定的兼容适配：按旧 schema 先验证，再补本轮新字段（mapping generation 从原 mapping/操作历史推导），最后按当前 schema 验证；原 manifest/ciphertext 留存，转换报告标识 source/target revision 和新增字段，不篡改原文件。
- 受支持恢复路径必须可执行：0038 原档 dry-run→只进入本轮独立空目标→升级到新 head→核对金额/关系/旧交易恢复保护。采用显式 allowlist 的 payload adapter 恢复到新 head，留下准确 CLI 命令与证据，不能只写未来建议；另外验证基线源码下旧档原生恢复，再升级，作为应急路径。
- 更早 schema 不推测兼容：输出具体不支持的 revision 及“匹配该源 revision 的已有源码工具恢复到空库，再按迁移链升级”的准确操作路径；至少对已知 0038→0039 真正演练。新版本数据生成后不做破坏性 downgrade；回滚采用原备份/旧档恢复到隔离空库，验证后才有资格未来切换。
- 报表 large IN 输入改成参数数有界的分块或 SQL 子查询；同一 read snapshot 中累积、去重和排序稳定，空集合、边界、混合退款/报销无丢失。所有同模式 period source IDs 查询窄扫，不能只改首个函数。批大小由总 bind 参数上限计算/保守封顶，不能把 32,765 写成业务容量限制。
- HTTPResponseCache 在 get/store/snapshot 时清除全部过期项；维护最近访问顺序、总字节与条数，LRU 淘汰，超大单响应不缓存。默认沿用 OfflineSnapshotStore 已有的 128 项/16 MiB 总量/1 MiB 单响应工程预算，构造器可注入小限制测试；TTL 30 秒上限保留。更新替换正确扣旧字节、过期/移除计数一致。此预算只属于可重取读缓存，不套用未决写入日志。
- 导入匹配用 candidate 的上海业务日期/精确金额生成有界批量 SQL，join/selectinload 一次取得所需 postings，避免全量 transactions 和逐笔 postings。不能改变既有匹配候选语义，也不能引入未经用户决定的模糊分数/阈值。准备只读结果在全局锁外完成，持锁写入前复核 batch/snapshot/data_revision；变化就返回明确可重试冲突或重新计算，不提交过期匹配。
- 信用 cycle 列表批量取相关 period totals/plan/periods，仅按请求需要的 cycle 组织响应；同一 plan 在一次响应最多展开一次。请求内 memo 不跨 data_revision 持久化，归档/作废/提前还款后不会留下旧生命周期。
- Transaction `_validate_mutation_ranges` 不再逐账户查或每次调用构建完整全历史 summary。批量读实际受影响账户、old/new kind/category 和 credit cycle；用针对性 SQL 数值聚合校验受影响的不变量，移除无关历史对象加载/重复分期展开。保留全局收入/支出及分类总额溢出保护所需的最小聚合，不通过删校验“提速”；若某项全局不变量确实要求全历史 aggregate，使用 SQL 聚合并按请求复用，单列其不可消除的读成本，不能把它谎称常数复杂度。
- 性能验收比较同一 fixture 规模扩展前后的 query 数、锁内语句/时间、相关返回对象数与金额结果；数据量大主要提升批次数或实际结果数，不因无关历史多出逐笔查询。使用 EXPLAIN 验证必要索引，只有证据支持才加入 migration。

## 4. 施工顺序与所有权

由主会话派一位 builder 负责交付和协调；可分工时明确所有权，所有人共用工作区，不回滚他人改动。推荐边界而非强制额外 agent：

- B1：builder 先锁定上述契约、复现 A01/A02/A03，登记需要新增的 schema/DTO 字段及测试入口。A01 旧错误测试必须先修预期。
- B2 后端账本负责人：transactions/cash_flow/installments/categories/merchants/auth/access/rate_limit 及对应测试；独占 0039 migration 和 models 变更。A19 交易范围验证和 credit 批量读取由该负责人合并，避免另一人同时编辑 transactions/installments/credit。
- B3 客户端负责人：Record/Bootstrap/Reports/AppShell/journal/cache 与其 tests；独占 V15Services.swift、共享 DTO、project.yml/project.pbxproj 生成与六 scheme 恢复。A11 的接口新增由导入负责人给该负责人合并，不能多人同时改 V15Services。
- B4 导入负责人：statement_import*.py、p24/p26/p27 schemas/导入 routes、客户端 StatementImportModel/Views；AI 配置解析公共提取若需改 dependencies/ai_provider，则提前移交对应文件所有权。迁移需求交 B2；client shared DTO 变更交 B3。
- B5 报表/归档负责人：reporting/repository/report export/p34 schema、archive service/CLI 及测试；A10/A14 DTO/UI 改动交 B3，索引/兼容 mapping 字段与 B2 协调。A03 可独立优先完成，A20 旧档兼容待 0039 结构定型后收尾。
- B6：唯一整合负责人收各块结果，跑后端全套与 Apple 全套、双端 App target 和相关 RootSmoke；Xcode 与全部 PG 测试均串行，避免共用 DerivedData/测试库互相破坏。更新版本后 xcodegen generate，逐一恢复六 scheme 字节/hash。最后固定修复范围交 reviewer；后续采纳修复仍由 builder 完成后回 reviewer 复查。

## 5. 验收门禁、复查与回滚

- 后端：现有 uv 环境执行 ruff、pyright、完整 pytest（包括本轮唯一 PG 测试库）；migration base/0038→head，旧数据回填、空库恢复与 API no-secret/no-raw 检查必须有证据。builder 按环境实际命令填入结果，不能只跑内存 mock 代替 SQL 并发。
- Apple：完整 FiscalKitTests；每批 SwiftUI 收口均构建 FiscalmacOS/macOS 与 FiscaliOS/generic iOS Simulator App target；相关根 UI/正式路由手动回放覆盖启动重试、在途关闭/重启、历史查询、改分类、报表切换/未知及导入续办。复用主模拟器，无 IPA/已装 App 替换。
- 真链路：用非敏感生成的文本 PDF 和扫描 PDF，通过正式提取器和 HTTP 适配器接本地 provider stub，完成授权→snapshot→validation→部分确认→补余行→确认→receipt；确认前账本零写入，重试后总写入准确。Swift fixture 采用真实后端 JSON shape，不能手写一个与后端不同的成功响应掩盖接口错误。
- 高危金额路径在隔离库通过真实 service/API posting 验证：收入、支出、信用消费、转账、还款、cashflow 重结算/恢复、跨期分期、分类合并、导入确认。核对方向/金额/版本/revision，不只看 HTTP 200。
- 用户已要求独立审计且随后授权修复：本轮收口必须独立复查 A01–A21 修复及影响范围。审查起点为上列基线，目标为整合后固定 commit，或当前文件的不可变 hash manifest+diff 快照；明确包含受影响的暂存/未暂存/新增文件，排除六个受保护用户 scheme 的既有变更。不将空 diff 或旧审查报告当通过；发现→采纳修复→针对复查闭环仍记在本记录。
- 版本验收：project.yml 与生成工程/实际构建产物均为 2.2.1（42）；六 scheme hash 一致；无生产数据变更/发布/推送副作用。本轮所有完成项在矩阵链接对应测试/日志/快照，主 Plan 仅替换当前状态和压缩完成块。
- 回滚边界：仅恢复本轮自有源文件改动，不动用户 scheme；legacy journal 迁移先写新再删旧，错误保留可恢复源。0039 含历史代次数据后不能靠丢字段降级，恢复使用已验证备份/空目标路径。未来发布时须后端能力与 migration 先就绪，再换 build42；那属于后续发布授权，当前不执行。
- 最大风险：资金重复写入与导入状态改变可能互相牵连；共享 journal/receipt 和恢复状态矩阵先实施，再接 UI，最后用 PG/HTTP/进程重启组合验证。历史档兼容及 mapping 回填失败时不修改原档或生产数据。

## 6. 用户网页操作清单

无。本轮复用已有 AI 配置能力，不需要新开通账户/购买服务；缺配置时应用给出既有设置入口。真实 provider 的秘密和用户账单不属于隔离测试输入。

## 7. 执行与验证记录（历程；最终结论见 §8）

- 主 Plan 已收口，六 scheme 备份及 xcodegen 后 hash 全部保持；四职责块首版已合并工作区，主会话独占 Xcode/PostgreSQL 调度，无发布动作。
- B1 契约按 §3 实施；0039 migration 为 `20260910_0039_mapping_generation`，字段/旧档适配统一复用 mapping generation 规则。源版本已更新 2.2.1（42）。
- 隔离数据库首批：`build/v2.2.1-42/qa/backend-integration-1.log`，60 passed、2 个新增 fixture 非法 posting 失败。补齐合法账户/分类/账期/posting 后，第二批迁移回填和历史余额通过；第二批 19 passed、4 failed 为导入依赖无配置问题及旧 version 测试，修复后进入完整后端验证。
- 已通过真实 PG：现金流重结算/旧恢复、跨期分期、mapping ABA/0039 历史回填、归档并发一致快照、32,768 真实来源（含报销/映射）、原生 0038 档经旧版恢复再升级及新适配直接恢复、历史余额 capability/legacy/export。详细断言见对应 `test_v221_*` 与 B2 既有回归。
- 主会话另外从固定基线源码生成原生 0038 合成档 `preflight/baseline-0038-synthetic.far`，SHA256 `42202b5d28b5cd9468ac508d530df6cb91e616b4a0e92f0d73921f6dc31020ed`；预期现金 348750 分、信用欠款 10000 分、2 笔交易。只含合成数据。
- Apple 集成第 1–3 轮编译发现 DTO Encodable、错误变量遮蔽、全部时间参数类型问题；按实际编译诊断逐个修复。未把 parse/局部测试替代 App 编译。文字/扫描 PDF 正式 HTTP 连通测试和根 UI 启动重试/历史月份/分类更正回归已补入，仍待执行。
- B2/B5 独立复查起点为基线 5a4991f，目标为不可变 `build/v2.2.1-42/qa/review-r1/manifest.json`（SHA256 `4890cd42ab9d1e95fb82bb9988d7851fa383585f0e90375c98fb038b53f3c35d`），包含自有暂存/未暂存/新增文件、排除六既有用户 scheme。客户端/导入仍集成中，最终范围需再次固定并复查。
- 当前下一步：完整后端门禁 → 修复失败；完整 FiscalKitTests → 双端 App target → PDF loopback 真链/相关 RootSmoke；关闭独立复查 findings 后更新 A01–A21 最终证据。当前尚无全部完成结论。

### 7.1 第一轮独立复查与真实联测

- R1 账本/报表/归档复查：A02/A03/A10/A14/A20 与交易 receipt/范围验证未发现可报告项；reviewer 对固定源码独立运行 9 个纯内存案例及 0/1/32768 UUID SQL 编译检查通过。结论不覆盖后续变更、真实生产或 PDF 版面。
- R1 A06 发现预览与提交跨午夜会静默重算分配，已采纳。新增 `preview_fingerprint` 绑定业务日期/请求/完整结果，PUT 锁内比较；旧客户端缺值返回可识别 409，正式及 legacy Swift 均回传原值。R2（manifest `d37b31121df1a8677ab4e3af621e4ed124a85398e18fa228ba6b7a7df948bb10`）纯内存针对复查通过，真实 PG 午夜测试纳入完整门禁。
- 完整后端首轮 `qa/backend-full-1.log` 为 425 passed、2 failed；P33 为旧 fixture 时钟跨期，单例固定日期；P35 为新 ORM 对旧 0037 fixture，改 head 后保留旧 auto-execute flags 注入/恢复不得复活断言。保护规则不放松，已进入全套第二轮。
- 完整 Swift 第 5 轮 423 tests 仅真实 loopback 测试地址重复 `/api/v1` 失败；其余 422 项通过。测试地址修正为 `http://127.0.0.1:18742` 后，`qa/apple-e2e-2.log` 的 F3G/V221Statement 两套 25 tests 全部通过，包含新增原确认请求恢复。
- 真实文本 PDF 与扫描 PDF 均经正式本地提取/OCR/脱敏、APITransport、后端授权/真实 HTTP adapter stub、验证、分批确认、receipt 查询完成；查询隔离库得 2 个 confirmed imports、2 笔 expense、2 条各 -1850 分 posting，证据 `qa/pdf-e2e-facts.json`、`qa/statement-e2e-server.log`。loopback 服务已关闭，无真实 provider/用户账单参与。
- R2 客户端复查新增三项已采纳：多窗口另一窗口完成 journal 后，旧编辑器不得新建 key 再记一次；关闭后迟到 success/待同步恢复需通知工作区刷新；非 report 缓存 key 必须继续读 build41 的持久离线快照。施工与新回归进行中。
- R3 导入复查目标 manifest `75038e1a606f1d49400704b25530a372b5cfd8e1041889075e3cd3c60f75758a`：已采纳“provider candidate 在前导致匹配已有提交 nil”和“明确 409 拒绝误判 unknown 导致永远不可重新预览”；双端选择与确定拒绝恢复正在补齐，将增量复查。

### 7.2 完整门禁及末轮状态收敛

- `qa/backend-full-2.log`：430 passed，128.17 秒；包含全部本轮 PG、migration、现金流/还款/跨期/分类历史/导入/归档/报表测试。`qa/backend-static-final.log`：Ruff clean、257 文件格式通过、Pyright 0 errors；六 scheme hash 保持原值。
- A19 对照 `qa/backend-scale-evidence.log`：1 笔历史、2500 笔历史、200 个候选三组均 1 条匹配 SQL、1 条真实结果；该次耗时 3.91/1.22/2.14 ms（局部实验非生产保证）。EXPLAIN 使用既有 timeline 和 posting 索引；真实并发 revision 变化拒绝陈旧候选，未新增索引。
- `qa/apple-full-6-e2e.log`：431 tests / 41 suites 全通过，含文本/扫描 PDF、真实 404→旧请求409→重建 model 释放/重新预览链。后续仅复查追加的客户端恢复/cache/UI 状态守卫修改，按影响范围继续复测。
- R2 四项已修并经 R4 静态复核主体通过；R4 补充分类恢复成功须先清读缓存，再发布刷新事件，现统一由 transport hook 失效缓存/推进 generation。
- R4 导入追加两项已修：未知原请求重放的 401/429 不再终结 journal；未知期间双端优先恢复入口，模型禁止新预览/新 key 确认，收到 receipt 清旧错误。恢复收敛只接受确认服务锁内原 key 查找后的明确业务拒绝白名单。
- 本轮最终增量复查目标 `qa/review-r5/manifest.json`，SHA256 `1ea95ce86e4a09bf5260216dea495dd1ab6a19dd63bfaa9203517233fc9345bf`；R5 targeted tests 及独立复查进行中，尚未沿用 R4 结论宣称完成。

### 7.3 R5 复查闭环与 App 验证

- R5 客户端复查无可报告项：同一生产 transport 在恢复后先推进 generation/清缓存，再发 UI 事件；旧 GET 禁止回填。R5 导入复查无可报告项：未知恢复网关拒绝保留原 key，未知期间 UI/直接模型均不能绕过未决意图。
- `qa/apple-r5-targeted.log`：65 tests / 4 suites 全通过，包含两 reviewer 的全部末轮增量及真实 PDF/404/409 重建 model。最终隔离事实仍为两份 confirmed imports、两笔 expense、每笔 -1850 分；`qa/pdf-e2e-final-facts.json`。第二个 loopback 测试服务也已停止。
- 双端 App target 构建通过：`qa/ios-app-build.log`（scheme 既有 Release / generic iOS Simulator），`qa/macos-app-build.log`（scheme 既有 Debug / macOS）；实际产物均 2.2.1（42），路径和配置见 `qa/app-build-metadata.json`。未替换已安装 App，不将 DerivedData 旧 Release macOS 产物当本轮包。
- 根 UI 首轮 macOS：启动失败→重试进入正式 workspace、分析往返保持交易选择通过；历史月份自动测试误查 AX label 两断言失败。xcresult 导出的 MenuButton title 证实实际已达“2026 年 4 月”和“全部时间”，仅修测试读取 title，不改产品行为；单例重跑及 iOS/导入 UI 继续执行。

## 8. 最终交付结论（2026-09-10）

**A01–A21 全部完成，R1–R5 追加 findings 均闭环，无已知未修问题；2.2.1（42）仅为本地候选，未发布。**

- 后端完整 430 项、静态门禁通过；Apple 全套 431 项、末轮 65 项定向回归通过。次数分别记载，不将重跑项重复相加当独立覆盖数。
- iOS/macOS App target 通过，实际构建产物版本/构建号均为 2.2.1/42。相关 11 个 UI 场景通过：Mac RootSmoke 三项（月份单项在 selector 修正后通过）、iOS RootSmoke 三项、Mac 导入两项、iOS 导入三项。日志 `qa/ui-macos-root.log`、`qa/ui-macos-month-final.log`、`qa/ui-ios-root.log`、`qa/ui-macos-import.log`、`qa/ui-ios-import.log`。
- 最终源码清单 `build/v2.2.1-42/qa/final-source/manifest.json`，SHA256 `701a23dcf4fb94902188748e827ce196fbb2449d06cce476bcfb99f02abab59a`；累计 App/Backend 98 个修改/新增文件，排除六用户 scheme；未变文件以固定基线 5a4991f 为准。生产源码与已审 R5 一致，唯一随后差异是 Mac UI 测试由 label 改精确 title（AX 证据及实际重跑通过）。
- 六 scheme 原字节校验通过；无提交、推送、标签、生产数据库访问或部署、已安装 App 换包、IPA 导出。临时 HTTP 服务停止；测试库只保留合成数据用于复核。
- 验证边界：已用真实 PostgreSQL、文本/扫描 PDF、正式客户端 HTTP、隔离 provider stub 和双端 UI；未连接用户真实 AI provider、未检查生产实时状态、未做真机安装或无边界压力测试。局部规模耗时不构成生产延迟保证。
- 下一动作仅在后续发布授权下执行：按实际生产 revision 到本候选的累计差异，一体完成 0039/API 部署及客户端发布；不可直接拿 DerivedData 中旧版本产物换装。当前无待修复或待决定事项。

## 9. 一条龙发布（2026-09-10，后续授权）

用户已明确授权本版本完整发布，覆盖此前仅修复阶段的发布限制；按 [RELEASE_STATE.md](RELEASE_STATE.md) 执行并记录结果。实际生产后端 64cb1ae/0038 与已装客户端 89cb977 到修复基线的对应源码差异为空，R1–R5 因而覆盖本轮生产累计源码范围。iOS 采用当前 Xcode 安装约定，不生成 IPA。
