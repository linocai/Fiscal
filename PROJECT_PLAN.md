# Fiscal · PROJECT_PLAN

> 控制面版本：v1.4 施工计划 ｜ 更新：2026-08-12 ｜ 状态：v1.3.0/P20–P23 已发布；P24-A/B 和受限 P25-A/B 已 Automated Verified；P24 整期、完整 P25–P29 均未完成、未部署。本文件仅保存当前目标、稳定决定、阶段门和下一步。详细产品/契约记录见 [docs/BACKLOG-v1.4-v1.5.md](docs/BACKLOG-v1.4-v1.5.md)；实施证据只写入 `docs/qa/p24` 至 `docs/qa/p29`。

## 1. 当前事实与目标

- `v1.3.0` tag 指向 `a18b54f`；生产后端的已验证状态仍为 P23、Alembic `20260811_0023`、data revision `2`。异地备份 provider 与真实告警接收器仍是明确 carried risk。
- `main`/`origin/main` 当前为 `fd2335c`：仅 Apple 图标包升为 `1.3.1 (22)`。这不是后端部署，**不得**据此宣称 v1.4 或 1.3.1 已生产发布。
- v1.4 目标：把一份 CNY 银行/信用卡 PDF 转为可审核候选；用户逐行决定新建、匹配或忽略，并在最终确认后才通过既有领域服务写入正式账本。
- v1.4 首发支持文本层 PDF 和 Apple Vision 本地 OCR 的扫描 PDF；只承诺用户实际使用的 2–3 个单账户版式。全量范围、字段和验收基线以 [v1.4 执行记录 §3](docs/BACKLOG-v1.4-v1.5.md#3-v14--pdf-智能账单导入) 为准。

## 2. 不变产品边界

- 仅单人、CNY、事实记录；不做预算、建议、评分、预测、投资、多币种、多人、银行连接器、通用附件或 AI 财务聊天。
- 正式 ledger/posting、余额、信用账期和报表仍是唯一金额真相。导入、OCR、LLM、匹配、缓存和 UI 都是候选或派生层，不能改余额、自动平账或绕过现有领域校验。
- PDF 永远人工确认：不存在由置信度、金额阈值、AI 自动执行开关或任何 profile 触发的自动记账路径。
- 服务端计算金额、日期边界、去重、校验和报表；客户端只显示服务端口径。金额在 API 内为 CNY `Int64` minor units，边界 decimal string 只解析一次，禁止浮点。

## 3. v1.4 核心契约与安全决定

- **导入生命周期**：`created → extracting → parsing → review_required → ready_to_confirm → partially_confirmed|confirmed`，可进入 `failed|abandoned`。失败/重试保留尝试历史；放弃不会删除已确认流水；同 SHA-256 文件复用既有批次而不复制候选。
- **数据最小化**：默认不长期保存原 PDF。仅临时使用文件/页面字节，完成、失败、取消均清理；持久化 hash、页号、必要证据文本/坐标、结构化候选、修正和 provenance。完整卡号、账号、姓名、地址、客户号、PDF 正文、Provider request/response 不进日志、Git、截图或 crash metadata。
- **Provider**：每个批次单独明确授权；先本地 PDFKit/Vision，发送前显示 Provider、模型、文本/图像、页数和脱敏范围。仅允许固定提示词、无工具的严格 JSON Schema；账单中的指令、URL、二维码或伪 JSON 一律是不可信数据。
- **候选与确认**：LLM 只能提出证据中存在的字段；确定性代码决定 `needs_review`。每行仅能为 `create_new`、`match_existing`、`ignore_non_transaction`、`ignore_intentional` 或 `unresolved`。同日同额只是候选匹配；匹配不改既有流水。
- **原子与并发**：最终确认携带 batch `expected_version` 和 UUID `Idempotency-Key`；一次选中行的 create/match/ignore 同事务，重放返回原结果，异 payload 重用 key 冲突。确认前重验账户/分类/账期状态；每次成功确认恰增一次 P22 data revision，并返回实际 affected scopes。
- **恢复与兼容**：新实体、尝试、证据、resolution 和正式流水链接纳入 Archive、实体计数、哈希和恢复关系校验；原 PDF 默认排除。新增字段/端点可追加，旧客户端可忽略；旧 AI proposal/自动执行 API 不承担 PDF 行确认。
- **确定的产品默认值**：允许部分确认，但每次确认原子、批次在全部行 resolution 前不能 `confirmed`；账单校验失败时可保存和审核，最终确认必须显著警示且持续保留 `failed`，绝不伪装为对平或生成 `balance_adjustment`。首个 v1.4 App 版本预留为 `1.4.0 (23)`，若其前有其他 Apple 构建则按顺序调整 build 号并记录。

## 4. 阶段、依赖与发布门

| Phase | 依赖与交付 | 阶段退出门 |
| --- | --- | --- |
| P24 | 导入批次/页面/行/尝试/resolution、状态机、hash 去重、隐私/授权、Archive 与 `statement_imports` revision scope；**不写账本** | fresh PostgreSQL migration 往返；创建/失败/重试/放弃零 posting；重复文件不建第二批；Archive 往返且敏感日志扫描通过 |
| P25 | Apple PDFKit 文本提取、Vision OCR、页型/上限/错误模型、发送前预览和三路径临时文件清理 | 合成夹具可重复给出页序/证据定位；未授权零外发；text/OCR/mixed 不静默漏页或重行 |
| P26 | 独立账单结构化 Provider contract、严格 schema、attempt snapshot、质量事件和 synthetic provider 测试 | 非法/超限输出在候选前失败；取消/429/5xx 无半套候选或账本写入；无自动确认配置 |
| P27 | 账单级确定性校验、行级强/候选去重、既有流水匹配、provenance 与原子正式确认 | 重放/并发/冲突不重复记账；批量任一失败零部分 posting；各种导入语义与手工领域服务的余额/账期/报表一致 |
| P28 | macOS 三栏导入工作台、证据双向定位、筛选/批量预览、最终确认 sheet 与可恢复审核 | 用多页储蓄卡及信用卡合成夹具完成端到端审核；摘要与实际写入逐项一致；无原 PDF 时诚实降级 |
| P29 | iOS 分步审核、跨端 optimistic conflict、Attention 入口、签名包与生产迁移/恢复/真机收口 | 全量自动门、备份/影子恢复/守恒、macOS+Kurisu 各完成真实受控账单主链路、production smoke 均通过后才可发布 |

各阶段只能在前一阶段的 Automated Verified 完整通过后开始其依赖写入；P28 可在 P27 API 契约冻结后并行完成只读/审核界面。每期结束必须记录 Automated、Production、Physical Device 三类独立证据；任一类不能替代另一类。

## 5. 实施与验证约束

- P24–P27 后端修改必须覆盖 migration upgrade/downgrade/re-upgrade、fresh PostgreSQL、现有全量测试、Archive 往返、revision scope/receipt 和旧客户端读取兼容。数据库 head 不同不做应用 rollback；以验证备份恢复到隔离新库后再切换。
- 解析器 fixtures 必须合成或不可逆脱敏；不得提交真实银行 PDF。真实账单只在受控本地或生产验收使用，且不进入命令回显、QA 文档或截图。
- 每个正式确认经既有 transaction/credit/reimbursement 服务产生原有业务语义与 posting；新增 `statement_import` source/provenance 仅允许导入服务创建，公开 API 不可伪造。
- P25/P28/P29 的耗时提取、OCR、哈希和大表格不得阻塞主线程；服务端对文件、页数、像素、字符、行数及 payload 设上限。记录 batch/attempt、版本、耗时、数量和稳定错误码，不记录正文。
- 发布顺序：干净已提交 revision → 生产前备份 → 影子 migration/Archive/守恒 → 精确 revision 部署 → 生产 smoke/备份恢复 → macOS 与 Kurisu 签名包真机验收 → 更新 release manifest、tag/push。部署或生产写入须在当时另获用户授权。

## 6. 用户决定与操作清单

- **P25 前**：用户提供首批实际使用的 2–3 类银行/信用卡版式名称，并只在受控设备上用于真实验收；不上传或提交原件。未给出时只交付合成夹具和通用阻止/降级行为，不宣称兼容某银行。
- **P26/真实验收前**：用户选择并逐批授权实际 Provider/模型及可发送范围；这涉及账单隐私和外部成本，不能由工程默认开启。无真实授权时使用 synthetic provider 完成全部自动门。
- **P29 生产前**：用户单独授权备份、迁移、部署与真实账单确认，并在 macOS 和 Kurisu 完成主链路验收。无固定网页操作；生产服务入口为 https://fiscal.linotsai.top ，但不得把凭证放入聊天、Git 或 QA。

## 7. 里程碑索引与 Backlog

- 已完成：P20 可信基线、P21 核对、P22 Archive/revision、P23 AI 质量；证据见 `docs/qa/p20`–`p23` 与 `RELEASE_STATE.md`。
- P24-A：`1d037bb0cd33df8bf20e060e6891c90e16956f2a` 已 Automated Verified，新增仅元数据导入基础，Alembic `20260812_0024`。范围明确排除 PDF 解析、Provider、ledger/posting、Apple、生产和设备验收。
- P24-A 验证：Ruff/Pyright 通过；fresh PostgreSQL `head → 20260811_0023 → head` 通过；lifecycle/hash duplicate/zero ledger+posting/Archive/revision/log redaction 定向测试 **4 passed**。完整命令、临时库清理和脱敏证据见 [P24 QA](docs/qa/p24/results.md)。
- 回归基线：历史 P10 `account_not_found` 已在 fresh PostgreSQL 独立复核并由 P21 测试时钟修正；P26-A fresh 全量后端为 **259 passed**，不再作为 P24/v1.4 阻断项（见 [P10 QA](docs/qa/p10/results.md) 与 [P26 QA](docs/qa/p26/results.md)）。
- P25-A：`fbf3ea3` 已 Automated Verified。Apple 本地 PDFKit/Vision 提取以合成夹具验证 `text`/`scanned_image`/`mixed`/`unsupported` 页型、行级页号/坐标、稳定错误与成功/失败/取消清理；不调用网络/Provider、不接入批次或账本。证据见 [P25 QA](docs/qa/p25/results.md)。这不代表 P24 或完整 P25 phase 完成。
- P24-B/P25-B：本地 extractor 产生确定性脱敏 page/row package 与发送前 preview；`20260812_0025` JSON-only evidence endpoint 在 batch version+active attempt guard 下原子保存既有 pages/rows，进入 `review_required`，同包重放无重复且只发 `statement_imports` revision。Archive/fresh PG/API、Apple 108 tests、macOS/iOS builds 均通过；无 URLSession/Provider、PDF/image 上传或持久化、账本写入。证据见 [P24 QA](docs/qa/p24/results.md) 与 [P25 QA](docs/qa/p25/results.md)。
- P26-A：`a2d82e3` 已 Automated Verified。固定无网络 `synthetic_statement` adapter 的脱敏 attempt/snapshot 只进入 `statement_imports`；定向 fresh PG **7 passed**、fresh 全量 **259 passed**、Apple 108 tests/macOS+iOS Debug build 通过。无真实 Provider/密钥/PDF、确认、ledger/posting 或生产；证据见 [P26 QA](docs/qa/p26/results.md)。
- P27：`68504fe`、Archive repair `54d743c` 与 P27-B `7662861` 均已 Automated Verified。`20260812_0028` 的 versioned final-create draft、atomic receipt/provenance 和内部 `statement_import` domain-service adapter 已实现；targeted **7 passed**、fresh PG JUnit **266/0/0**、Archive 空库 restore/replay、Apple 110 tests/macOS+iOS Debug build 通过，见 [P27 QA](docs/qa/p27/results.md)。无 Provider、真实账单或生产动作。
- **P28-A 已冻结，尚未实施：只提供 macOS 本地 PDF intake 与 P24/P25 evidence handoff，绝不触发 P26 parse（synthetic/real）、P27 review/confirm 或任何 ledger/posting。** 用户先在本机看到 filename、page count、byte size、SHA-256 与“尚未查询/duplicate”结果；明确同意后才注册 metadata。filename/path/bookmark 只留当前内存 UI，注册固定 `statement.pdf`，仅发送 SHA/size/pages/mime；duplicate 直接显示既有 batch，绝不启动 extraction/attempt 或上传 evidence。
- unique batch 的唯一顺序是 `register → start local_extraction attempt → 本地提取/确定性脱敏 → JSON evidence`；repository 从已有 start response 的 `X-Fiscal-Statement-Import-Version` 取得确切 expected version，缺失即停止，绝不猜版本。跨边界 DTO 仅为既有 metadata、attempt/version 和 redacted page/row package；编译与测试必须证明无 PDF bytes/image/URL/path/bookmark/raw filename/raw evidence 的 API/日志/离线缓存字段。原件只在 security-scoped 本地临时 workspace，完成、失败、取消、视图关闭和 App 终止时删除临时副本/图像、结束 scope；不持久化 bookmark 或原件。
- P28-A 状态机显式区分 local metadata、awaiting consent、registering、duplicate、extracting、uploading、review-required、local failure、remote failure/cancelled 与 remote-unknown。网络失败、响应丢失或离线绝不自动重发/后台排队：仅保留内存中的已脱敏 package，并由用户显式 Retry 或 Cancel；remote-unknown 只可用既有 `GET batch` 解析，或重发同一个 JSON evidence（不重读原件），不可新建 attempt。已启动 attempt 的 Cancel/local failure 仅尝试一次 JSON `fail(document_cancelled|client_extraction_failed)`，失败则诚实标为 remote-unknown。P28-A 不建 review/confirmation table，P28-B 才处理审核 UI。
- 当前：P27 核心确认契约已验证；下一最小块为 P28-A。本块通过只建立本地 intake/evidence handoff，不解除 P24 整期、P28 完整审核、生产或真实账单门。
- 后续：v1.5（P30–P35）仅保留在 [执行记录 §4](docs/BACKLOG-v1.4-v1.5.md#4-v15--事实展现升级)，不得插入 v1.4。预算、建议、预测、银行连接器、通用附件、多人和投资仍明确不做。
- 每次状态替换本文件当前事实/阶段/下一步；长篇测试输出和实现过程留在对应 QA 结果或 Git，不在此追加。

## 8. Builder 下一实施块

执行 **P28-A：macOS local PDF intake（Apple 主责；backend 只复用既有 P24 endpoint）**。Apple 新增 `StatementImportDTO`/`StatementImportIntakeRepository`（唯一 remote adapter）、`StatementImportIntakeModel` 与 `MacStatementImportIntake`，并在 `MacRootView`/app composition 新增可发现的“账单导入”入口；`fileImporter` 与 drag/drop 仅接受 `UTType.pdf`。repository 只用 `APITransport` JSON register/start/evidence/一次 fail，及只读 `GET batch` 解析未知终态；为 start 增加窄的 response-header metadata seam，读取 batch version header，禁止传递原件类型。不可改 P24–P27 backend 业务语义/迁移；若 header 不可读取，停止且提示用户而非上传。

本机 worker 在 `Task`/非 MainActor 流式 hash、PDFKit metadata 和按页 P25 extraction/OCR，受既有限额约束；security-scoped source access 只覆盖复制到随机 temporary workspace 的时段，所有原始 Data/CGImage 都局部且 cleanup。UI 主线程只更新 progress/可访问状态，文件选择、drop zone、consent/retry/cancel 都有 VoiceOver label、键盘焦点和明确的 local/remote 文案；大文件不能阻塞 1040×700/1280×820 窗口。验收以 synthetic PDF/URLProtocol 覆盖 consent 前零 API、合法/拒绝/锁定/超限文件、duplicate 不 start、register/start/header/evidence 顺序、红线 payload、cancel/cleanup、response-loss explicit retry 与 zero auto-resend；Apple targeted tests、macOS test、macOS/iOS Debug builds 均通过。复跑 existing P24 API contract 与 fresh PG 全量（当前 266）保持通过；不建 migration/Archive entity，证据写入 [P28 QA](docs/qa/p28/results.md)，再评估 P28-B。
