# Fiscal — 项目施工须知

权威计划见 `PROJECT_PLAN.md`（唯一入口）。历史 plan / 审查报告进 `archive/`，验收记录进 `docs/qa/pN/`。

## 工程与门禁

- Apple 工程用 xcodegen：改 `apple/project.yml` 或增删源文件后必须 `cd apple && xcodegen generate`（会重写 xcodeproj；重生成会顺带改 scheme 文件，通常 `git checkout -- Fiscal.xcodeproj/xcshareddata/xcschemes/` 还原噪声）。
- 单测：`xcodebuild -project apple/Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests`（即 `swift test` 语义；无 SPM Package）。
- 改 SwiftUI View 的批次收口，必须 `xcodebuild` 跑 iOS 与 macOS App target（`FiscaliOS` generic iOS Simulator + `FiscalmacOS` platform=macOS）；只跑 FiscalKit/test 不暴露 View 层问题。
- 后端在 `backend/`；疑似项核实以后端 schema/service 为准（见各 `api/*_schemas.py`、`services/*.py`）。

## 前端反复踩的四条横向规律（改一处必按模式全扫，见 2026-07-17 审查 §五）

1. **双端防护不对称**：作废/valid/selection 收敛/错误横幅等校验，漏的几乎都在 iOS 侧；mac 常已有正确样板。修 iOS 时对照 `MacTransactionWorkbench` 等 mac 端同点，反之亦然。
2. **预览/派生状态不随输入失效**：报销预览、分期 eligibility、报表 drillDown 是同一类。编辑器 dismiss 要清预览；任何输入变化（含非法文本）要使服务器预览失效并禁用提交；切换口径/账户要清派生状态。
3. **缺 generation 竞态守卫**：异步 load/preview 必须 `generation += 1; let current = generation`，await 后 `guard current == generation` 再写状态，`CancellationError` 分支重置 phase 也要带守卫。正确样板：`ReportingModel`、`InstallmentModel.loadAccount`。分页清 flag 用请求归属 token，避免被取消的旧请求清掉新请求的 flag。
4. **错误提示链路**：iOS sheet 内必须有错误展示区（对照 mac 的 message banner），不要只把错误写在被 sheet 遮挡的主界面上。

## 金额 / 记账写入

- 金额一律走 `CNYAmountParser`（元，两位小数），禁止把「元」当「分」或反之；报销回款与报销单必须同单位。
- 切换交易类型必须清理方向/账户类型不兼容的引用（`TransactionEditorModel.changeKind`），并在有账户/分类上下文处做类型一致性校验（`validateReferences`），不能只查非空。
- 转账/还款/结算等写入前校验来源与目标账户非空且不同、且账户类型匹配（信用 vs 非信用）。
- 高危金额/记账改动收口跑针对性 `swift test`，并手动走一遍真实 posting/回款/还款/入账路径确认写入方向与金额。

## 时区

- 业务日期用 `Asia/Shanghai`；CSV 导出文件名等对用户可见的日期也用东八区，别用默认 UTC 的 `ISO8601Format()`。
