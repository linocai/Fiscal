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
- **P27-A 已冻结，尚未实施：对正式交易/ledger 是 read-only，但会持久化可归档的确定性校验报告和 resolution 草稿。** 输入只能是指定 `validated_result` snapshot 与其 P26 source rows；批次保持 `review_required`，行只呈现 `unresolved`/`create_new`/`match_existing`/`ignore_non_transaction`/`ignore_intentional` 草稿，绝不转 `ready_to_confirm`、写 `confirmed_at` 或 `confirmation_operation_id`。最小 DTO 为 `POST /statement-imports/{id}/validation-runs {expected_batch_version, provider_snapshot_id}`（先核当前 batch；同 snapshot/evidence hash/算法版重放同一不可变 run）、`GET .../review`，以及 `PUT .../rows/{row_id}/draft-resolution {expected_batch_version, expected_row_version, expected_resolution_version: 0|current, resolution, matched_transaction_id?, ignored_reason?}`；改变时 scope 仅 `statement_imports`，陈旧版本冲突、同语义重放不增 revision。
- P27-A 校验/匹配契约：每项账单公式、行余额、日期窗口、页/行连续性都给 `passed`/`failed`/`unavailable`；缺项或无法证明绝不算通过、不得补零推断。document SHA 是文件强重复（返回既有 batch）；同 batch page/row number 是行身份，跨文件只有证据中可证明的稳定 external reference 才是行强重复；同日同额、账户/方向/金额/日期窗/规范化摘要/来源关系仅形成排序候选。已有 transaction 只可读、不可自动选择；多候选须人工选择，`match_existing` 仅保存草稿链接且不改其字段。`create_new` 是未执行意图；`ignore_non_transaction` 为非交易，`ignore_intentional` 必填原因，`unresolved` 清除选择；均保留 source row→snapshot→run→草稿 provenance。
- P27-B 已锁定但不在本切片：唯一 `confirm` 以 batch expected version、每行/草稿当前版本和 UUID `Idempotency-Key` 预检后，把所有 create/match/ignore 全有或全无落地；相同 key+同 payload 返回原结果、不同 payload 冲突。没有自动 `balance_adjustment`；`match_existing` 只最终化来源链接，`create_new` 必须经既有 transaction/credit/reimbursement 服务及原 posting 语义，才可写实际 affected revision scopes。P27-A/P27-B 均不改 P24/P25/P26 业务语义、PDF/Provider 或生产。
- 当前：P24–P26 停在 review-only/候选证据边界；下一最小块为 P27-A，P28 只读审核 UI 只可消费其稳定 review DTO。P27-A 通过不解除 P24 整期或生产门。
- 后续：v1.5（P30–P35）仅保留在 [执行记录 §4](docs/BACKLOG-v1.4-v1.5.md#4-v15--事实展现升级)，不得插入 v1.4。预算、建议、预测、银行连接器、通用附件、多人和投资仍明确不做。
- 每次状态替换本文件当前事实/阶段/下一步；长篇测试输出和实现过程留在对应 QA 结果或 Git，不在此追加。

## 8. Builder 下一实施块

执行 **P27-A：确定性 validation / candidate resolution（backend 主责；Apple 只接 review DTO seam）**。Builder 只拥有新的 P27 validation/matching/resolution 模块、独立 migration、DTO/route、Archive adapter 和定向 PG tests；不得改动 P24/P25/P26 业务文件或语义。第一步：以 P26 `validated_result` snapshot 的 source-row references 为唯一输入，定义不可变 validation-run/report 与 `GET review`，使每个公式/结构检查显式返回三态和证据 row IDs；无 snapshot、缺余额/合计或不可证明字段返回 `unavailable`，不计算猜测值。随后提供候选只读 finder 和 draft-resolution 写入：file SHA 命中只返回既有 batch，只有可证明 external reference 才强去重；相同日期/金额永不自动匹配；草稿必须同时检查 batch/row/resolution version，且不改变任何正式 transaction。确认 endpoint、`ready_to_confirm`、transaction source/provenance 最终化、ledger/posting、balance adjustment、PDF/Provider/网络及生产均不做。

验收门：synthetic P26 snapshot fixtures 覆盖 passed/failed/unavailable、重复/多候选、五种草稿语义、陈旧 version/同语义 replay、草稿前后 transaction/posting=0 和 revision 仅 `statement_imports`；fresh PostgreSQL migration upgrade/downgrade/re-upgrade、定向测试及 fresh 全量回归必须全通过（当前基线 259）。Archive 往返须精确保留 run/check/candidate/草稿与 snapshot/source-row links、计数/hash，并证明无 PDF/image/raw Provider body；历史/恢复后只读不生成新 revision。Apple 仅解码并展示三态、候选和草稿的 versioned review DTO，断言没有 confirm/ledger transport，并通过其 DTO tests 与 macOS/iOS Debug builds。记录命令、精确 revision、scope 和未覆盖边界到新建 `docs/qa/p27/results.md`；通过后才规划 P27-B confirm。
