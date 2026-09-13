# Fiscal — 项目施工须知

权威计划见 `PROJECT_PLAN.md`（唯一入口）。历史计划、审查报告、版本契约与验收证据统一进入 `archive/`。

## 工程与门禁

- Apple 工程用 xcodegen：改 `App/project.yml` 或增删源文件后必须 `cd App && xcodegen generate`（会重写 xcodeproj；重生成会顺带改 scheme 文件，通常 `git checkout -- Fiscal.xcodeproj/xcshareddata/xcschemes/` 还原噪声）。
- 单测仍为 `FiscalmacOS` / `FiscalKitTests`（无 SPM Package），统一经 `scripts/test_artifacts.py run` 调用 xcodebuild，登记用途、源码及清理状态；命令示例见 [脚本说明](scripts/README.md)。
- 改 SwiftUI View 的批次收口，必须 `xcodebuild` 跑 iOS 与 macOS App target（`FiscaliOS` generic iOS Simulator + `FiscalmacOS` platform=macOS）；只跑 FiscalKit/test 不暴露 View 层问题。
- 后端在 `Backend/`；疑似项核实以后端 schema/service 为准（见各 `api/*_schemas.py`、`services/*.py`）。

## 前端反复踩的四条横向规律（改一处必按模式全扫，见 2026-07-17 审查 §五）

1. **双端防护不对称**：作废/valid/selection 收敛/错误横幅等校验，漏的几乎都在 iOS 侧；mac 常已有正确样板。修 iOS 时对照 `MacTransactionWorkbench` 等 mac 端同点，反之亦然。
2. **预览/派生状态不随输入失效**：报销预览、分期 eligibility、报表 drillDown 是同一类。编辑器 dismiss 要清预览；任何输入变化（含非法文本）要使服务器预览失效并禁用提交；切换口径/账户要清派生状态。
3. **缺 generation 竞态守卫**：异步 load/preview 必须 `generation += 1; let current = generation`，await 后 `guard current == generation` 再写状态，`CancellationError` 分支重置 phase 也要带守卫。正确样板：`ReportingModel`、`InstallmentModel.loadAccount`。分页清 flag 用请求归属 token，避免被取消的旧请求清掉新请求的 flag。
4. **错误提示链路**：iOS sheet 内必须有错误展示区（对照 mac 的 message banner），不要只把错误写在被 sheet 遮挡的主界面上。

## 金额 / 记账写入

- 金额一律走 `CNYAmountParser`（元，两位小数），禁止把「元」当「分」或反之；报销回款与报销单必须同单位。
- 切换交易类型必须清理方向/账户类型不兼容的引用（`TransactionEditorModel.changeKind`），并在有账户/分类上下文处做类型一致性校验（`validateReferences`），不能只查非空。
- 转账/还款/结算等写入前校验来源与目标账户非空且不同、且账户类型匹配（信用 vs 非信用）。
- 分期资格、期间锁定和修改校验都按消费与还款/减免的业务时间判断；结清后同账期的新消费不能被旧还款锁住。资格响应自带账期选项，前端直接复用，避免后续请求把业务否决覆盖成读取失败。
- 高危金额/记账改动收口跑针对性 `swift test`，并手动走一遍真实 posting/回款/还款/入账路径确认写入方向与金额。

## 时区

- 业务日期用 `Asia/Shanghai`；CSV 导出文件名等对用户可见的日期也用东八区，别用默认 UTC 的 `ISO8601Format()`。

## 发布与换包

- “一条龙发布”按生产当前 revision 到目标 revision 的**累计差异**决定范围，不能只看最后一个快修提交是否改了 Backend。先读目标 `RELEASE_STATE.md` 的未执行项，并只读核对生产 revision、Alembic head、服务与备份状态。
- 新前端依赖尚未上线的 API 或 migration 时，必须把后端 dry-run、迁移前备份、apply、迁移后备份、readiness/public smoke 与 App 换包作为同一发布链记录；不能把前端换包单独宣称为完整发布。
- 既有版本标签不可移动；同营销版本追加构建号时使用独立不可变 build 标签（如 `v1.5.5-build32`）。

## 测试证据与清理

- `scripts/test_artifacts.py run` 管理每次 Apple 测试的结果路径、日志、结构化摘要和 `run.json`；复用既有 DerivedData，串行两 job，不默认导出附件。视觉用例截图仍属验收证据，不能为省空间删除断言或把必要截图全部关掉。
- 每轮问题闭环和发布收尾，分类所有 `.xcresult` 及包外图片/视频：最终验收、未解决问题代表证据保留；其他轮次先保存按测试项的摘要和替代依据，再列入精确删除清单。保留运行日志及重要源码版本，禁止用“final”文件名或修改日期代替结果核实。
- 附件只为当次检查按需导出；定位失败可用 `xcresulttool export attachments --only-failures`。确认原件位于保留结果包或正式归档后删除导出副本；废弃轮次附件随该轮次一起处理。不要重复保存整包与全量导出视频。
- 清理先 `plan` 后 `apply`，再 `check`，用同一脚本校验未跟踪范围、指纹、保留证据、在用文件与未分类产物。计划/回执/检查结果写入当前版本 `archive`；主 Plan 只记一行结果。新测试产生的 `cleanup_status=pending` 必须收口，资源检查未通过不能宣称清理完成。
- 当前使用及回退的 App/安装包/dSYM、待通过 Xcode 安装的 iOS 产物、真实账本/数据库备份、用户 scheme 修改受保护；本脚本不自动删除它们。设备支持文件按全局规则另行核验，保留项不能和测试垃圾混删。
