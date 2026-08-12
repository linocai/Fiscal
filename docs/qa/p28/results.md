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

- Backend 新增只读 `GET /review-workbench` 与 page evidence GET；无 migration、provider、validation-run、confirm 或 Archive 写入。无 P26 validated result 的 P28-A batch 明确返回 `review_available=false`，仅有已存 masked evidence/source-unavailable。
- macOS host 从 P28-A `reviewRequired` 路由到三栏 workbench；repository 一律 `cache:false`，离开清空 in-memory payload/selection。未添加 iOS workbench UI、自动 resend 或 confirm endpoint。
- `ruff` 与 `pyright` P28 backend files → **passed / 0 errors**；P24/P27/P28 PG targeted → **13 passed**；macOS tests → **117 tests / 21 suites passed**；macOS+iOS Debug builds 已使用隔离 DerivedData 运行通过。
