# V2.4.0（49）精简工程执行契约

> 2026-09-26，Asia/Shanghai。状态：Build49 已完成本地工程与验收；未 Review、未发布。

## 1. 授权、边界与基线

- 用户明确进入正式工作流，指定 V2.4.0 Build49；授权完成 Build 后停止。主会话直接推进，无待用户决定项。
- 用户明确从未使用、以后也不需要 PDF 导入和多人报销分摊；手机截图 OCR 必须保留。其余采用已确认的十项精简方案。
- 本轮不 Review、不提交推送、不打标签、不部署、不访问或修改生产账本、不换装当前 App、不做真机安装。以后发布时再从实际部署状态核查累计差异。
- 基线 `main` / `2d5cc840c4a558ced3fa5753606a9542c0f92618`。旧 Plan 记载已发布 2.3.0（48），后端 `20260922_0041`；本轮未查生产，不能推断其即时状态。
- `AGENTS.md` 和六份共享 scheme 已有用户修改，主会话已保存 `build/v240/protected-inputs/` 快照和 manifest。生成工程后按快照逐字节核验并恢复用户版本，不执行 `git checkout -- ...schemes`。
- 项目 AGENTS 优先，全局工作流引用 `/Users/linotsai/.codex/AGENTS.md`。工程不是 SwiftPM：金额逻辑单测通过 FiscalKitTests 执行，不运行不存在的 Package。
- Apple 构建串行、复用现有 DerivedData。主模拟器按名称及实际 iPhone 18 Pro/iOS27 解析。生产凭据、真实离线缓存和钥匙串不进入测试。
- 基线逐文件 sha/lines/bytes 在 `build/v240/baseline.json`；App 正式源码统计144文件/41216行，Backend/src 144文件/37437行，包含空行注释与夹具。测试另计，不删测试凑精简收益。

## 2. 事实、决定与未知项

### 已核实事实

- `App/project.yml` 为 2.3.0/48，最低双端 OS27；FiscalKit 目标直接包含整个 `Sources/FiscalKit`。
- 正式根为 `IOSRootView` / `MacRootView` → `V15LiveAppShell` → `V151*Workspace`，当前四主空间；并非由旧 Features model 驱动。
- `V15RecordView` 演示初始化直接使用 `V15F1AFixtures`；Gallery、Fixtures 与正式源码耦合，不能先删目录再补假数据。
- `FiscalShortcuts.swift` 调用 `LatestScreenshotPhotoLibrary` → `VisionOCRService` → `AIInputSubmissionService` → 旧 `RemoteAIProposalRepository`，不能整批删除旧 Domain/Data。
- 正式录入页未接照片选择；`FiscalNotifications.didReceive` 只处理撤销，普通点击未打开 proposal；App 未装配对应 onOpenURL 路由。
- 报销当前 parties → allocations → receipt allocations，party ID 参与 future-events、cash-flow override、交易关系和归档；UI 限一人不构成完整精简。
- 报表同时有 monthly/yearly 与 v2 两组，CSV/PDF 也重复；v2 复用共同计算，不能删共享基础。总览 facts/future-events 并不因无 v2 前缀就是旧接口。
- `archive.py` 按 Base.metadata 校验实体集合，支持 0038/0039/0040/0041；改表须处理旧实体/列的版本形状，不能只改 CURRENT_DATABASE_REVISION。
- PostgreSQL 测试会清空指定库甚至重建 public；本轮须独立数据库。Build48 未决背景像素断言位于 `V15RootSmokemacOSUITests.testWideOverviewCanvasAndHeaderActions`。

### 决定

- 减少真实能力与重复实现，不以隐藏入口、放到未调用目录或新增复杂抽象层代替删除。
- 单对象报销扁平化，但保留费用与回款内部归属：报表需按原消费计算报销影响，撤销需精确还原；内部自动归属不是多人分摊功能。
- 共享交易编辑字段/规则，AI proposal 保有自身状态机和溯源；不能 execute 后再创建第二笔手工交易。
- 前后端按 2.4 契约协同升级，旧运行协议不为未知客户端永久保留。历史 archive/迁移/enum 的必要兼容限定于数据恢复。
- 不新增通用框架、后台任务、第二个账本、第三方 OCR、同步系统或设计语言。

### 未知但不阻塞施工

- 未查生产 PDF/多人记录或旧客户端；用户明确未使用作为需求事实，迁移仍有数据守卫。
- 前轮“11文件/2273行旧模型”只是候选；Builder 查引用确认删除集合，不作为承诺目标。
- 真机在线、符号和权限以收尾审计为准；无真机安装授权，不能宣称本轮真机运行通过。

## 3. 产品与接口契约

### 3.1 三主空间和未来收付款

- 双端仅总览、交易、账户三个顶级空间；记一笔为动作，设置独立可达。月/年报从总览进入，返回保留选择；负债/分期/账期从账户详情进入。
- 总览保留当前资金、未来30天预计可支配余额、近期收付与分析入口，沿用现有图表视觉，保留真实负债和缺口提示。
- 统一“接下来要收付”，复用 future-events/cash-flow 边界，含信用到期、分期、报销待收和手工计划。手工计划仅补无其他来源事项，不复制自动来源。
- 自动来源保留来源ID/口径/详情；只有允许的日期/备注覆盖可编辑。取消、部分回款、还款、撤销后按同一 revision 更新，不重复计入。
- 报销未来来源改 `reimbursement_claim`，`source_id=claim_id`，locator 为 `fiscal://reimbursements/{claim_id}`；新DTO无partyID。旧单对象 override 由partyID无损映射到claimID，冲突拒绝。
- 旧通知/深链可窄适配到claim，不恢复多人编辑器。普通页面不显示内部关联ID。
- 保留导航状态，数据刷新与详情打开独立；重复打开同笔详情用新请求token，总览不共享被交易筛选污染的模型。参照现有 `.learnings/LEARNINGS.md` 对应经验。

### 3.2 简单报销

沿用 `/reimbursement-claims`、`/reimbursement-receipts` 路径与 preview/commit/version/idempotency；新形状：

```text
ClaimDraft: title, note?, counterparty_name, expected_date?,
            expenses: [{id?, transaction_id, amount_minor}]
Claim: id, title, note?, counterparty_name, expected_date?, expenses,
       total_claimed_minor, received_minor, outstanding_minor,
       status, expense_count, receipt_count, version, lifecycle timestamps
ReceiptDraft: expected_claim_version, amount_minor, received_at,
              destination_account_id, title, note?
ReceiptReplace: ReceiptDraft + expected_receipt_version
Preview/Commit: 沿用 expected version、input digest、preview_token 绑定
```

- 不接受/返回 parties、party_id、party_count 或用户指定的回款分摊矩阵；extra forbid 拒绝旧多对象请求。
- 一单一对象，可关联多笔实际费用、部分申请但不能超过可报销容量；每次回款仅账户、金额、日期、可选备注。
- 回款不超过未收余额，到账账户是有效非信用资金账户；每次生成一笔真实记账，部分/全部/替换/作废/恢复保留原子操作与幂等回执。
- 内部回款按费用关联稳定 position/id 顺序填补剩余容量，保留 receipt→expense 归属用于报表和撤销，客户端不编辑矩阵。有有效回款时不得删除/减少到低于已归属金额的关联，也不能靠重排改变历史归属。
- 保留草稿/提交/取消、归档、撤销与恢复；取消只释放未回款部分，真实到账不删除。恢复回款重新验证容量，过期 preview 拒绝。
- 活跃 `ReimbursementParty` 模型与表退役，claim 持对象名/预计日；`reimbursement_allocations` 可保留表名但变无party费用关联；receipt移除party FK；内部receipt allocations保留，避免纯重命名扩大迁移。
- reporting、cash_flow、transaction relation、深链、缓存与归档同时改claim；历史revision JSON保留原样，通过集中只读适配读旧单对象快照，不能重写事件时间/金额。

### 3.3 录入、截图 OCR 与人工确认

- 记一笔有手工/文字解析；iOS增加系统照片选择器选截图并本机Vision OCR，保留快捷指令最近10分钟截图规则；手选截图不套此限制。
- 图片bytes/文件名/路径/PhotosID不上传、不进普通日志；只通过现有AI路径发送识别文字，`source=ocr`。保留来源开关、provider配置与具体错误。
- 空/超长文字、拒绝权限、受限照片、取消、读图失败都在页内可见；解析失败保留可修正文本，取消不后台提交。
- PhotosPicker按所选项目读取；快捷指令所需照片/通知授权入口保留，不因手机OCR重引PDFKit或文档工作台。
- 手工和proposal复用交易字段模型、校验与视图组件：元/分、种类切换清引用、信用/现金账户限制、源目标不同、分类方向、日期、错误横幅与preview失效。
- proposal创建/修改/确认/execute沿用action receipt及稳定重试，保留source/proposal→transaction；不把proposal复制成手工账后遗留可再次execute的提案。
- 未确认/失败结果从记一笔中的待确认列表恢复，不再独立AI管理空间；已执行历史可追交易，撤销仍检查当前版本。
- 普通通知点击和 `fiscal://ai/proposals/{uuid}` 打开草稿；冷启动/鉴权未完成保存一次待打开目标，通过鉴权后加载，不重复创建。无效/已删除目标有可读错误与返回。
- shortcut/通知旧DTO迁当前共享契约或窄适配后再删旧层；不能只根据正式View无调用删传递依赖。
- 新提案永不自动execute；历史executed可读但文案不承诺自动记账。退役自动额度/置信阈值/策略、quality metrics/events管理、shadow运行管理；保留开发解析回归和必要失败原因。
- AI settings活跃字段仅来源开关、provider是否配置、version/timestamps；provider secret保护沿用现有边界，merchant/category识别映射保留。

### 3.4 完整退役清单

| 能力 | 必须退役的活跃部分 | 必须保留的边界 |
|---|---|---|
| PDF账单导入 | 双端页/入口、PDF提取、review/final draft/provider/confirmation服务、路由/DI/schema/repository、专属DB模型/测试/依赖 | 真实交易/source枚举、历史迁移/归档、通用请求恢复 |
| 多人报销 | 多对象/矩阵UI、DTO、party服务/查询/表/future身份 | 简单报销、内部费用回款归属、历史金融事实 |
| PDF报表 | 双端PDF选择/保存、四组PDF路由、生成函数/专属资源和测试 | CSV、必要分析与归档 |
| 旧月/年报 | `/reports/monthly/*`、`yearly/*`、旧period-drill-down、旧封装/专属服务 | v2报告、正式总览/facts/future使用的接口和共同计算 |
| 分类拆分 | split/split-preview/split-commit路由/UI/DTO/专属服务 | 新增/改名/归档/恢复/合并与merge preview/恢复 |
| 商户复杂管理 | 独立列表/编辑/合并/重映射工作台及其专属写API/状态机 | 名称/识别别名/交易历史映射/报表追溯/必要内部解析读写 |
| AI运行管理 | execution policies/自动配置/shadow/quality endpoints及UI/状态 | 人工proposal、provider配置、来源授权、识别映射、失败原因、开发回归 |
| 旧客户端/画廊 | 无调用旧model/专属DTO/repository、重复总览/交易页、正式fixture依赖 | OCR/通知/认证/缓存/幂等、正式页测试覆盖 |

- 删除前按正式入口/快捷指令/测试/归档/SQL分类。必要历史引用无需字符串归零，但列明用途，不能用白名单掩盖运行能力。
- 专属功能测试退役；金额/竞态/校验/恢复的有效断言先迁现行实现，不能为减少失败数删仍适用测试。
- PDF专属pending-write退役不能令整个journal解码失败：窄legacy读取旧条目并提示功能退役/需核对原请求，禁止自动重放或丢弃；核心pending继续恢复，旧PDF提交入口移除。

## 4. 迁移、归档与回退

- 基于现场head添加Alembic revision，不覆盖旧迁移；模型/schema version/operations status与Archive revision同步。
- 同事务先审计后变更：PDF各表非空量、每claim party数、关联/回款金额、override冲突和孤儿关系；不输出原文/凭据。提供可重复dry-run及migration前置校验。
- PDF表全空才删活跃表；发现任何导入/工作台/确认历史则拒绝自动删除，保留数据并明确阻塞。独立金融交易不可级联删除，历史TransactionSource值保留。
- 恰好一party时搬name/expected_date到claim；零party仅允许既有合法空草稿；多party/容量不一致拒绝，不自动合并或抹除。
- 保持receipt/allocation/transaction ID、金额/posting/状态/业务时间；override映射不重计。历史revision JSON与正式财务回执不删除后伪造重建。
- AI策略/质量等非金融配置可按契约退役，但proposal/action的未知结果恢复与金融引用不可级联删；不承诺downgrade能恢复已删除运行审计。
- 0038/0039/0040/0041旧加密归档按对应revision先验证shape，再转换到新head。单对象/空PDF无损转换并给摘要；多人/非空退役数据拒绝新head导入，指向隔离旧工具恢复，原文件不变，不默默漏实体。
- 旧工具恢复说明固定基线commit和head，在独立空库恢复后保持历史可读；不能用当前表结构加载旧实体。合成旧归档演练守卫及旧工具恢复。
- 全部演练用本轮合成数据，无生产dump；新head导出→pristine restore→余额/posting/claim/receipt/revisions对账通过。
- 回退靠迁移前整库快照+基线代码，验证可恢复再回收临时副本；不靠不完整downgrade拼回历史。未来发布须同步升级后端和客户端，本轮仅演练说明。

## 5. 旧层、画廊与共享规则

- Gallery/fixture移入测试预览支持target，可用项目内轻量support framework，不换包管理；正式FiscalKit不引用。保留现有六个scheme用户版本，target名尽量不改。
- 正式View接受真实draft/参数，演示由测试装配注入；不能改名fixture后留正式源码。
- Gallery复用正式总览/交易/功能组件及合成service/transport，不另维护同义页；仅暴露必要测试注入，不散布演示业务分支。
- 旧Features逐一检查App/Framework/Data/Domain/Test引用，特别OCRInputService、AIInputSubmission、CaptureAuthorizationModel；有效测试转向现行模型后删空壳和无用途封装。
- 规则共享基于现有Swift类型，只抽真实重复的领域规则，不建通用表单框架；双端保持原生布局。
- 输入含非法金额/选项撤销/dismiss均使preview失效；async成功/错误/取消均有generation守卫，分页状态清理有归属token；sheet内错误可见。

## 6. 验证与产物登记

- 工作产物 `build/v240/`，Apple结果 `build/test-runs/v240-*`，长期摘要/迁移/清理证据 `archive/releases/v2.4.0/qa/`；不建第二根目录state/plan。
- 开工登记源码范围、用途、目录、数据库/端口与进程所有者；独立库使用本轮前缀，URL只进环境不打印凭据，严禁默认/真实数据库跑测试fixture。
- 主会话已创建空测试库 `fiscal_v240_build49`（PostgreSQL14，本机socket `/tmp`，用户linotsai），尚未迁移，无真实数据；测试URL为 `postgresql+asyncpg://linotsai@/fiscal_v240_build49?host=/tmp`。此库才可truncate，测试串行；迁移演练另建同前缀专用库，收尾结束连接后drop本轮库。
- 前后对比正式Swift/Python源码行数、活跃路由、正式fixture引用及删除文件，区分移动和删除，不设百分比KPI。
- 不建远端目录；系统临时目录只处理确证本轮文件，不泛清共享缓存。

## 7. 施工拆分与顺序

1. **Builder集成负责人第一步**：核对Git/保护快照，记基线，列退役依赖闭包与新接口映射，冻结§3 schema/深链，建立隔离数据环境。普通实现自主调整，改变保留核心/关键行为才交主会话。
2. **后端责任块**：独占 `Backend/` API/schema/service/模型/迁移/归档及测试；报销影响reporting/cash_flow归同块。顺序为迁移守卫→简单报销→退役/报表→综合验证。
3. **客户端共享业务块**：拥有FiscalKit Domain/Data/Features、V15/Foundation、各功能Model/Contracts、共享校验/State、iOS FiscalShortcuts/FiscalNotifications与对应单测；先DTO/路由再OCR/草稿/报销，负责journal兼容。
4. **客户端界面块**：拥有V15/AppShell、各双端View/Components、Settings/MasterData视图、Gallery/Fixtures移动装配、UI测试及App根路由装配；先三空间/编辑组件再对齐契约；改Model/Contracts找所属负责人。
5. **集成负责人独占**：project.yml/生成工程/版本Info/支持target、构建/测试/资源调用、Plan与本记录。其余块提配置需求，不并行xcodegen/xcodebuild；源码增删后统一生成并恢复保护scheme。
6. 后端与客户端可基于冻结契约并行；共享字段未稳定时界面先做导航/删除独立PDF页，不另造DTO。每个责任块明确不是独自在仓库，不撤销他人修改；交接列产物和进程。
7. 集成后针对性校验→§8完整门禁→资源收尾→写实绩和未发布状态→停止Build；失败修根因并重跑影响范围。

## 8. Build验收

### 后端与数据

- `uv run ruff check .`、格式检查、`uv run pyright`、专用PostgreSQL全量 `uv run pytest` 通过；缺数据库而skip不能充作验收。
- 合成0041→新head：普通交易/信用/分期/车贷/单对象多费用多回款/取消作废与快照金额一致；空退役数据成功，多party/非空PDF/override冲突拒绝且事务无半迁移。
- 隔离真实API流程：消费→报销→两次回款→撤销/恢复；借入/还款/信用消费/分期/全额结清与CSV读取。检查实际postings/余额/收入消费口径/未来30天去重。
- 幂等重试和未知结果只一笔；非法账户/超额/过期preview/版本改变/恢复容量拒绝，失败不丢输入不提前成功。
- 新归档往返、旧归档转换、不能转换的拒绝与隔离旧工具恢复有证据；失败演练源校验和不变。
- OpenAPI/注册路由无PDF导入导出、分类拆分、旧月年报、AI策略/运行质量管理，正式调用集合不使用这些endpoint。

### Apple与界面

- 使用 `scripts/test_artifacts.py run` 执行FiscalKitTests；APITransport隔离TestSnapshotScope，不碰正式shared缓存/钥匙串；测试覆盖删除风险和真实行为，不只镜像实现。
- 最终源码双端App target构建通过：FiscaliOS generic iOS Simulator、FiscalmacOS platform=macOS；有效版本2.4.0/49、Deployment Target/SDK≥27；不产IPA不替换 `/Applications`。
- 合成截图真实本机OCR，传输仅文字；正式记一笔识别→编辑→确认→一笔交易通过。shortcut至少App target编译/业务链验证，通知URL冷/热启动路由通过；未安装真机的未覆盖项明示。
- OCR无权限/空/超长/取消/失败可见，来源关闭提示准确，授权入口可达，通知可继续草稿；手工/AI共用字段校验通过。
- 双端三空间/分析可达，导航状态保留，数据刷新不乱开详情；来源不重计，报销/错误对称；CSV/分类合并/商户识别保留。
- 正式target不编fixture或重复Gallery页，Gallery验证正式组件。四空间期望改三空间合理，保留功能断言/视觉保护不可删除。
- Build48宽屏背景先复现真实整窗并核对取样/坐标/颜色，修布局或有证据的取样错；保持浅深色和边缘一致验收目的，不弱化阈值凑通过。最终Mac宽窄/iOS关键画面保留代表截图，含金额可读性；未通过不得说全部UI通过。

### 资源与交付

- Apple结果按来源/替代关系分类，保留最终及未解决代表证据；清理plan→apply→check写本版qa，pending状态全收口。
- 停本轮服务/数据库进程后清理隔离DB、原始输入、临时导出；保留复现源码/摘要。废弃构建轮次/附件用精确清单，不删用户App/唯一历史/回退物。
- 执行 `python3 ~/.codex/scripts/apple_device_support.py --output archive/releases/v2.4.0/qa/device-support.json`；本轮仅审计，不加apply/prepare，pending_devices如实交付。
- 核查本轮目录/系统临时/进程，记录前后占用、保留理由；保护快照须确认七文件逐字节一致后才回收。无核验不称清理完成；远端明确无本轮操作。
- 交付完成范围、源码/路由实测减少、门禁、迁移升级风险、未覆盖真机、产物清理、准确下一步；注明Build结束、未Review、未发布。强制门禁仍失败时如实阻塞，不能提前称完成。

## 9. 用户网页操作清单

无。本轮无外部能力开通或人工网页事项。

## 10. 执行证据与重要偏离（Builder更新）

本轮在 `main` / `2d5cc840c4a558ced3fa5753606a9542c0f92618` 上施工，未提交、推送、打标签或访问生产。实际目标为工作区全部未提交变更及未跟踪新源码、迁移和版本记录；用户原有 `AGENTS.md` 与六份 scheme 的 SHA-256/大小在最后一次 xcodegen 后 7/7 逐字节一致，清理原始副本后只留 [哈希清单](qa/protected-inputs.json)。`App/project.yml` 对外 2.4.0 / Build49，后端版本 2.4.0；双端最低 OS、SDK 均为 27.0。

工程完成 §3–§5 十项精简：PDF 导入/报表与多人报销结构退役，报销改单对象、多费用/多次回款；三主空间、分析下沉，旧分类 split、独立商户管理和 AI 自动运行管理退役；截图 OCR、快捷指令来源、人工 proposal/确认、通知路由、CSV、账户与债务能力保留。正式 FiscalKit 不再编画廊 fixtures、手绘旧页或仅 Gallery 使用的旧 Today 双端页；测试支持移至独立 PreviewSupport。正式源码使用同口径物理行数（含注释/空行）从 App `144/41,216` 文件/行降到 `78/27,413`，Backend `144/37,437` 降到 `126/30,585`，合计正式源码少 84 文件、20,655 行；其中迁出正式目标的测试支持仍有 `17/2,664`，不能把全部减量称为纯删除。快照 `build/v240/baseline.json`、`build/v240/after-metrics.json`；HTTP OpenAPI operation `188→142`，净减 46，路径快照 `build/v240/routes-before.json` 与 `build/v240/backend/routes-after.json`。

[后端验收](qa/backend-build49.md)：隔离 PostgreSQL 全量 `436/436`、0 skip，ruff/format/pyright 通过；0041 非空单对象两费用两回款/override 到 0042 保留 ID、postings 与归档 revision，六类不能转换的数据预检与迁移均拒绝且源指纹不变；旧 0041 加密归档原 SHA 不变地转换恢复，旧工具隔离恢复与新归档路径均有回归。真实 API 两回款、幂等、撤销/恢复和 CSV 通过；两隔离库已在零连接后删除。生产是否有非空 PDF 或多人数据本轮未查询，未来发布必须先备份并运行只读 0041 预检；0042 无 downgrade，回退依赖验证过的 0041 整库快照。

[Apple 验收](qa/apple-build49.md)：最终 FiscalKitTests `329/329`、0 skip，含合成 PNG 经真实 Vision OCR→文字→`source=ocr` 提案→人工编辑确认→单笔 execute；双端正式 App、Gallery、RootSmoke 与 snapshot tool 最终构建通过。iOS 正式三空间/账户/OCR 设置 `3/3`，隔离 `fiscal-qa` 冷/热草稿链接 `2/2`，iOS Gallery 五项 `5/5`；macOS 正式三空间/宽屏 `4/4`，Gallery 报销/CSV `3/3`。测试发现并修复报销提交成功反馈被滚出视区、通知链接到 Workspace 后提案 ID 与 sheet 状态竞态；宽屏旧失败为取样误落卡片，保持原三点/±1 RGB 验收阈值。照片库权限、系统选图、通知横幅和快捷指令安装未在真机覆盖，不宣称真机通过。

资源经 `scripts/test_artifacts.py` 精确 [删除计划](qa/cleanup-plan.json)→[回执](qa/cleanup-receipt.json)，又对既有历史证据做 [完整保留分类](qa/cleanup-closeout-plan.json)；最终 [check](qa/cleanup-check.json) 为 complete，未分类产物/未关闭运行/保留变化/残余删除均空。17 个被替代 xcresult、5 个导出媒体已回收；额外 115 个任务 scratch 文件和 12 个系统临时合成 archive/CSV 文件按哈希清单回收。`build/test-runs` 逻辑大小 `690,075,710→99,893,911` bytes，`build/v240` `42,203,665→1,115,903` bytes；整盘可用空间变化约 `+676,360,192` bytes，APFS 差值不当作精确释放量。保留六个 Build49 最终结果包和既有历史结果，原因见计划；[设备支持审计](qa/device-support.json)仅只读，`pending_devices=[]`，本轮无远端目录或进程残留。


## 11. 2026-09-27 独立复审及 Build50 快修

- 用户追加授权独立复审并要求“快修搞定”；营销版本仍 2.4.0，build 递增至 50。不提交/推送/部署/换装正式 App。
- 复审基线仍为 `2d5cc840c4a558ced3fa5753606a9542c0f92618`，覆盖 Build49 全部未提交/未跟踪实现；Build49 内容快照 SHA256 `3e6053d4fe6b33fbf4552a4d70dfb3fb903b08a545aa794558ac16ab79442608`。独立结论为主要目标达成，两项 P2：新商户映射无写入路径；通过接口重排费用后，同额编辑旧回款会改变历史归属。
- 修复商户边界：仅恢复交易级 GET/PUT/DELETE merchant-mapping，不恢复独立管理工作台。GET 返回 `{mapping,suggested_merchant}`，规范化名称/别名精确匹配只给建议，用户确认后才写入。PUT 接受 `merchant_name, aliases, expected_mapping_version`，原子创建必要名称/新增别名并确认或纠正映射；DELETE 解除本交易关联。沿用 generation、幂等键、revision 与报表读取，不增加迁移或篡改交易原文/postings。双端交易详情共用小型编辑器。
- 修复回款边界：有效旧回款的归属优先保留，同额编辑不变；减少按稳定原归属裁减，增加仅分配差额。
- 验证/资源已完成，详细证据集中在 [Build50 QA](qa/build50.md)：后端 438/438，客户端全量 335/335 与最终定向 6/6，双端真实商户 UI 各 1/1，最终正式 App Debug 双端构建成功；独立 reviewer 判定两 P2 关闭，最终 editor 生命周期微调另经复查无 finding。
- 真实 UI 验证发现保存后的全局刷新会使 iOS 嵌套编辑器提前消失；将刷新延后至关闭编辑器，保持成功回执可见，原断言重跑通过。商户别名输入仅追加新值，不把旧商户全部别名随更正转移。
- `cleanup-build50-check.json` complete；清理被替代的 4 份结果包、3 份截图导出及 12 份临时副本/合成文件，保留最终验收原件和每轮摘要。唯一隔离库已删除，系统临时文件与任务进程复查为空，用户 AGENTS/六 scheme 7/7 不变。未提交、推送、部署或换装。

## 12. 2026-09-27 一条龙发布与 Build51 兼容修复

用户追加授权完整发布。Build50冻结 `0bd45b25`，首次迁移和备份恢复通过，但正式月报只读验收发现旧claim/receipt revision内嵌transaction关系仍为party字段。Build51冻结 `b006ed90`，七文件修复与回归经独立复查（内容指纹 `680042b5604ce02da2b30705b68da55aa540199a77d1cbc9686989e7de98ce01`），仅纯读适配旧JSON，不改历史快照或金额，不放松当前响应模型；补齐旧操作回执同类边界。后端全量441/441、0skip；三组签名Release构建与生产月报/年报/CSV、Mac正式总览及分析通过。具体源码标签、备份恢复、签名与资源证据集中在 [发布记录](RELEASE_STATE.md)，不复制发布流水。
