# P25-A · Apple 本地 PDF 页面证据

状态：**Automated Verified**（受限 P25-A）；未部署、未进行真实 PDF 或设备验收。

## 范围与隐私边界

- `StatementPDFEvidenceExtractor` 只读取调用方给出的本地文件 URL。它不创建导入批次、不写入任何 repository/ledger，也不调用 API、Provider 或网络。
- PDFKit 以页为单位取得页数、页面几何与文本行/坐标；页面仅在内存中栅格化，Vision OCR 输出同一套左上原点的归一化行级 bounding box。
- 每页稳定分类为 `text`、`scanned_image`、`mixed` 或 `unsupported`；混合页仅在文字相同且区域重叠时去重，保留页号、原文和来源。规范化只压缩空白，原始金额、负号、日期和小数点仍保留于 `rawText`。
- 明确上限：20 MiB、50 页、每页 12,000,000 raster pixels、总 OCR 100,000 字符；加密、损坏、超限、OCR 失败和取消均映射为稳定的 `statement_pdf_*` error code。
- `StatementPDFTemporaryWorkspace` 的 `defer` 清理已在成功、失败、取消三条合成路径验证；生产提取本身不复制或持久化 PDF/页面图像。

## 自动验证（2026-08-12）

- `xcodebuild test -project apple/Fiscal.xcodeproj -scheme FiscalmacOS -configuration Debug -derivedDataPath /tmp/fiscal-p25-test-derived CODE_SIGNING_ALLOWED=NO` → **107 tests / 20 suites passed**。P25 合成夹具覆盖文本多页页序/坐标、扫描、混合区域去重、空白、加密、旋转、文件/页数/像素/OCR 字符上限，以及三条临时清理路径。
- `xcodebuild build -project apple/Fiscal.xcodeproj -scheme FiscalmacOS -configuration Debug -derivedDataPath /tmp/fiscal-p25-macos-derived CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**。
- `xcodebuild build -project apple/Fiscal.xcodeproj -scheme FiscaliOS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/fiscal-p25-ios-derived CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**。
- 静态边界检查：P25-A source/test 不含 `URLSession`、API transport、Provider、`statement_import`、transaction 或 posting 调用。

## 已知验证边界

- 所有夹具均为测试运行时生成的合成 PDF，未提交、未读取真实账单。Vision 的真实 OCR 入口已编译，但真实银行版式与物理设备 OCR 验收须在用户给出受控样本及 P29 门时进行。
- 此切片不含 P24 批次登记/发送前预览对接，也不使 P24 或完整 P25 phase 完成。
