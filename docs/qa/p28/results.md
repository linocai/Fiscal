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
