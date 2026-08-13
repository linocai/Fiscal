# P28-A · macOS local statement intake

状态：**Automated Verified**；仅使用合成 fixture、隔离本机 DerivedData 与本地 PostgreSQL 测试数据库。没有真实账单、生产请求或外部 Provider。

- macOS 侧栏新增“账单导入”入口：PDF 选择/拖放、security-scoped 访问期间复制至随机临时目录、后台 SHA-256/页数/大小/PDFKit/Vision 本地提取，以及发送前隐私与 consent 预览。原始 PDF、页面图像、路径、bookmark、原始文件名和未脱敏文本均不跨 repository 边界、不持久化或入日志；临时副本由既有 workspace 在成功、失败和取消后清理。
- 用户明确 consent 之前不调用 API；登记仅发送 SHA-256、大小、页数、MIME 和固定 `statement.pdf`。重复登记直接停止；开始提取严格读取 `X-Fiscal-Statement-Import-Version`，缺失/非法时不提取或上传证据。
- 唯一上传载荷为现有确定性脱敏页/行 JSON。响应丢失不会自动重读文件、重发或后台排队；用户只能显式 GET 批次，或重发同一份内存中的脱敏包。取消/本地失败仅 best-effort 发送一次 JSON fail attempt，失败则停在 remote-unknown。
- `xcodebuild -project apple/Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' -derivedDataPath /tmp/FiscalP28MacRun5 ... test` → **116 tests / 21 suites passed**，包含 P28 consent、payload redline、重复、response-loss 显式重试、缺失版本和取消覆盖；P25 临时目录 success/failure/cancellation cleanup fixture 同轮通过。
- `xcodebuild -project apple/Fiscal.xcodeproj -scheme FiscaliOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/FiscalP28iOSRun1 build` → **BUILD SUCCEEDED**。P28 intake source 仅加入 macOS target；iOS 无入口或 UI 行为变更。
- 新建 disposable PostgreSQL `fiscal_p28a`：`FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p28a uv run pytest -q tests/test_p24_statement_import_postgres.py` → **4 passed**；同一 fresh database 的全套 JUnit → **266 tests, 0 failures, 0 errors, 0 skipped**。

未完成：P28-B 审核表/编辑体验及任何 P26/P27 parse、review 或 confirm 业务；本块不上传 PDF/image、不创建账本写入，也不访问外部网络。

## P28-B · macOS review workbench

- 范围基线为 `d941eeb`（P28-B workbench 只读投影）与 `1b0d89a`（macOS inspector/P27 写入 adapter）。后续 `1f4bee6`、`baff66a` 与 `09ebaad` 仅恢复全局 static/P10 隔离质量门；不改变 P28-B 产品边界。
- Backend 只读 `GET /review-workbench` 与 page-evidence GET：P28-A 无 validated run 的 batch 返回 `review_available=false`，只能读取既存 masked evidence 或 source-unavailable；无 migration、Archive、provider attempt、validation run、PDF/image/upload 或正式确认写入。
- macOS 从 P28-A `reviewRequired` 进入固定三栏工作台。repository 读取均为 `cache:false`；退出清空 response、evidence、selection 和未保存表单。inspector 覆盖 `unresolved`、`create_new`、`match_existing`、`ignore_non_transaction`、`ignore_intentional` 五种 resolution：match 只能显式选当前 existing-transaction candidate，intentional ignore 强制理由；create-new 从空表单先选 kind，再显式输入日期、金额、标题、账户/目标账户、分类和信用字段，并只交给既有 P27 final-create-draft API。Accounts/Categories 只提供未归档稳定 ID；没有候选自动默认值。
- URLProtocol mock 覆盖 resolution 的正常 JSON decoding、先 reload 的 fresh batch/row/draft version body、409 后 reload、以及 response-loss/409 **零自动 PUT 重发**；final-create-draft 同样以 fresh version 写入并 decode 正常 JSON。测试还覆盖 evidence-only、source unavailable、masked-only/cache-free、路由、selection 与离开清理。红线扫描和 adapter 路径确认：无 PDF/image/path/bookmark/raw filename/provider body、`/confirm`、`Idempotency-Key` 或 iOS workbench UI；P28-B 不会 POST provider/validation endpoint。
- Apple 验证：`xcodebuild -quiet -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests/FiscalKitP28StatementImportIntakeTests` → **8 tests passed**；同 scheme 全量 macOS test → **exit 0**。`xcodebuild -quiet -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' build` 与 `xcodebuild -quiet -project Fiscal.xcodeproj -scheme FiscaliOS -destination 'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED**。macOS host 提供三栏 VoiceOver labels、可聚焦行与 Cmd-R Reload；既有 App 1040×700 最小和 1280×820 默认窗口约束保持生效。
- Backend 验证：P28 route/schema/service 定向 Ruff 通过、定向 Pyright **0 errors**。fresh disposable PostgreSQL 上 `tests/test_p24_statement_import_postgres.py tests/test_p27_statement_import_review_postgres.py tests/test_p28_statement_import_workbench_postgres.py` → **13 passed**。全局门在 `1f4bee6` / `baff66a` / `09ebaad` 后重新验证：Ruff、Pyright 均绿，fresh PostgreSQL 全量 JUnit → **268 tests, 0 failures, 0 errors, 0 skipped**。

P28-B 仅为 **Automated Verified** 的受限审核工作台，未完成完整 P28；没有最终 confirm/action sheet、批量确认、iOS 审核 UI、真实账单、Provider 授权、设备验收、部署或 P29 工作。

## P28-C · macOS final-confirmation sheet

- 基线为 P28-B `d941eeb` + `1b0d89a`；本块新增 migration-free 的读面：`POST /statement-imports/{id}/confirmation-preview` 仅收 1–1000 个显式 `row_ids`，行锁重验 batch/row/draft/final-create-draft 后返回服务器规范化的 P27 confirm request、resolution/count、仅已知金额、tri-state checks 与 partial/confirmed/unresolved 警告。没有 mutation lock、confirmation operation、provenance、transaction、posting、revision、provider 或 receipt 写入；既有 P27 `/confirm` 未改。`GET /confirmation-receipt` 仅按 `Idempotency-Key` 返回已持久化 P27 receipt；workbench 增加 `is_confirmed` 只用于冻结呈现。
- macOS 仅在 `review_available=true` 且用户显式选择非空、已解决、未冻结行时允许 prepare。prepare 总是 cache-free reload 后 preview；sheet 以辅助功能 label 列出所选数、batch unresolved、resolution/known-or-unknown amount、checks 和 warnings。最终确认没有默认焦点或键盘快捷键；只有点击“最终确认”才生成 UUID 并以精确 P27 request + `Idempotency-Key` 发出一次 POST。409 丢弃 preview/reload/reselect；传输或响应丢失不会重发，只能由用户明确 receipt lookup。partial/confirmed 行显示冻结且不再可选/编辑；离开清除 preview、receipt、key、选择和本地表单。
- Mock/PG 覆盖：URLProtocol 断言 preview 在 final POST 前、精确 snake_case P27 body 与 UUID header、response-loss **零**自动 resend、显式 receipt lookup；P28 PG 断言 canonical request/count/unknown amount、duplicate/unresolved rejection、preview 前后 ledger/posting/provenance/operation/frozen-row 零变化、已持久化 receipt read 与 `is_confirmed`。可访问性覆盖 sheet 和选择/最终按钮；macOS 既有 Cmd-R 仅 reload，未给确认添加键盘 shortcut，窗口最小 1040×700 约束未变。
- 验证：fresh PostgreSQL 14 `fiscal_p28c_preview`（head migration）上 P24/P27/P28 targeted → **14 passed**。fresh PostgreSQL 14 `fiscal_p28c_full2`（head migration）上全量 JUnit `pytest -q` → **269 passed, 0 failures, 0 errors, 0 skipped**。`uv run ruff check .`、`uv run pyright` → **passed / 0 errors**。`xcodebuild ... FiscalmacOS ... -only-testing:FiscalKitTests/FiscalKitP28StatementImportIntakeTests` → **10 tests passed**；完整 macOS test → **exit 0**；`FiscaliOS` generic Simulator Debug build → **BUILD SUCCEEDED**。纯 confirm DTO 保留在双 target 的既有合约文件以使 iOS 编译，iOS 没有 P28-C host、入口或 UI。
- 红线复核：P28-C preview/receipt/Apple adapter 不读取或返回 PDF/image/path/bookmark/raw filename/evidence/provider body；不调用 provider、不会自动 confirm/retry、没有生产配置、部署或 P29 声明。P28-C 为 **Automated Verified**，并不声称完整 P28 或 P29。

## Reviewer follow-up（2026-08-13）

- workbench 过滤分页以已扫描的源 row cursor 前进，并以 `limit + 1` 判断还有无源行；空过滤页不再访问 `selected[-1]`，也不会重复 cursor。定向 PG 覆盖 first page 无匹配、next cursor 前进、后续页匹配和终页 `null`。
- confirmation transport response unknown 立即冻结/清除 preview，并保留首次 UUID 与 batch；再次 `confirmPrepared` 返回 false、绝不第二 POST。用户只能显式 receipt lookup，或明确 reload 后重新预览。macOS/iOS 两端刷新按该规则清除 unknown state。
