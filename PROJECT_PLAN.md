# Fiscal · PROJECT_PLAN

> 更新：2026-09-27（Asia/Shanghai）｜目标：**V2.4.0（51）**｜状态：**一条龙发布进行中**

## 概述

将 Fiscal 收敛为个人记账、账户与真实负债、近期资金安排。用户已确认完全取消 PDF 账单导入与多人报销分摊，明确保留手机截图 OCR，其余按本轮精简方案实施。
Build49 已完成精简，Build50 两项 P2 快修已验收与独立复查。用户已追加授权一条龙发布，按 [发布记录](archive/releases/v2.4.0/RELEASE_STATE.md) 完成后端与双端交付；详细产品契约见 [执行记录](archive/releases/v2.4.0/execution.md)。

## 稳定技术决定

- 延续原生 SwiftUI、绿色视觉、Swift 6、xcodegen、FastAPI/PostgreSQL；iOS/macOS 与工具链最低 27，不重写技术栈。
- 主空间为总览、交易、账户；分析下沉总览，信用/借款/分期从账户进入；设置独立可达。未来收付款统一展示，来源事实继续区分。
- 手工、文本解析、截图 OCR 使用同一套交易字段与校验；截图在本机识别，只发送文字，必须人工确认，不恢复自动入账。
- 简单报销为一个对象、一组关联费用、多次实际回款；移除多人对象与分配接口。内部费用归属保留，以支持金额校验、撤销和历史报表。
- 金额输入为元、领域/API 为 Int64 分，统一 CNYAmountParser；业务日期 Asia/Shanghai。借款本金和本金还款不计收入/消费，余额由真实 postings 派生。
- 保留固定账期、随借随还、分期与全额结清；不虚构额度、日期或历史余额。预览与确认、幂等键、请求结果不明恢复、备份恢复不削弱。
- 未来 30 天为上海今日至 +29 天，现金与储蓄加剩余流入减剩余流出；同 revision、不重复统计来源事项，未知日期/逾期/缺口单列。
- 报表只留当前 v2 月/年报及 CSV，保留必要分析与交易追溯；取消 PDF 导出、分类拆分及独立复杂商户管理，保留分类合并、名称与识别映射。
- 旧运行接口随 2.4 同步升级契约退役；历史枚举、金额事实、原始归档不篡改。迁移遇到不能无损转换的数据明确拒绝，不静默删账。

## 当前状态

- **Build50 两项 P2 快修及独立复查完成**：交易详情恢复商户识别建议/确认，编辑回款保留历史费用归属；最终双端 UI、构建与资源收尾通过，见 [Build50 QA](archive/releases/v2.4.0/qa/build50.md)。未提交、推送、部署或换装正式 App。
- 实施基线：`main` / `2d5cc840c4a558ced3fa5753606a9542c0f92618`；本轮初始业务源码无未提交修改。
- 已发布状态沿用 2.3.0（48）记录：客户端 `825705e`，后端 `db95c13` / `20260922_0041`；本轮未核查生产，不能把文档记录称作现场验证。
- Build50 正式源码净少 82 文件、19,981 物理行（App `144/41,216→79/27,632`，Backend `144/37,437→127/31,040`）；其中有 PreviewSupport 移出正式目标，非纯删除。OpenAPI `188→145` operations；[最新统计](archive/releases/v2.4.0/qa/build50-metrics.json)。
- [后端 QA](archive/releases/v2.4.0/qa/backend-build49.md)：隔离 PostgreSQL `436/436`、0 skip，0041→0042 非空迁移/拒绝回滚、旧加密归档恢复及真实 postings/CSV 通过；两测试库已删除。
- [Apple QA](archive/releases/v2.4.0/qa/apple-build49.md)：FiscalKit `329/329`、0 skip；双端正式 App 与支持目标构建通过，iOS 正式/深链/Gallery `3/3`、`2/2`、`5/5`，macOS 正式/Gallery `4/4`、`3/3`；真实 Vision 合成截图→人工确认→仅一笔通过。真机照片权限、系统选图、通知横幅与快捷指令安装未覆盖。
- [资源核验](archive/releases/v2.4.0/qa/cleanup-check.json) complete、无未分类/未关闭项；保留最终证据及既有历史包，任务临时库、导出物和系统临时合成文件已清理。用户原有 `AGENTS.md` 与六份 scheme 末次 xcodegen 后 7/7 逐字节一致，哈希证据在 [protected-inputs.json](archive/releases/v2.4.0/qa/protected-inputs.json)。
- Build50 后端 `438/438`，客户端全量 `335/335` 加最终定向 `6/6`，双端商户 UI 各 `1/1`，最终双端 App Debug 构建通过；独立复查两项 P2 关闭，[本轮资源核验](archive/releases/v2.4.0/qa/cleanup-build50-check.json) complete，新增隔离库已删除、设备审计无 pending。
- 一条龙发布已获授权，正在核查生产并冻结源码；0041 只读预检拒绝时必须停在旧版本，0042 回退依赖验证过的 0041 整库快照。

## 当前 Plan

Build50 上线只读验收发现旧报销 revision 中嵌套交易关系字段未完全转换，当前月报 500；只读兼容修复与合成回归进行中。最终交付递增 Build51，保持旧标签，修复复查后重新冻结、部署及双端 Release 构建，完成线上读取与资源收尾。不得改写历史快照或生成真实测试账目。

## Backlog

真机选图、通知横幅及快捷指令交互仍未新增验证；iOS 最终安装由用户通过 Xcode 完成。

## 里程碑索引

- V2.2.0（40–41）界面重构及视觉快修；[执行历史](archive/releases/v2.2.0/execution.md)、[Build41](archive/releases/v2.2.0/build41/RELEASE_STATE.md)。
- 2026-09-10：2.2.1（42）修复、复查与发布；[发布记录](archive/releases/v2.2.1/RELEASE_STATE.md)。
- 2026-09-12：2.3.0（43）Backlog 完成、复审和发布；[执行记录](archive/releases/v2.3.0/execution.md)、[发布记录](archive/releases/v2.3.0/RELEASE_STATE.md)。
- 2026-09-13：测试资源和设备支持清理规范落地；[记录](archive/releases/v2.3.0/RELEASE_STATE.md#2026-09-13-资源补清与工作流修正)。
- 2026-09-13：2.3.0（44）结清后新消费转分期修复；[发布记录](archive/releases/v2.3.0/RELEASE_STATE.md#2026-09-13-build44-紧急发布完成)。
- 2026-09-20：2.3.0（45–46）系统兼容验证，最终双端最低 OS27；[Build46](archive/releases/v2.3.0/RELEASE_STATE.md#2026-09-20-build46-发布完成)。
- 2026-09-22：2.3.0（47）免息车贷本金/账期恢复与发布；[记录](archive/releases/v2.3.0/RELEASE_STATE.md#2026-09-22-build47-车贷修复发布完成)。
- 2026-09-22：2.3.0（48）日期轴修复发布，宽窗口背景断言留待核对；[执行记录 §17](archive/releases/v2.3.0/execution.md#17-2026-09-22-build48-每日支出日期轴快修)。
- 2026-09-26：V2.4.0（49）精简工程 Build 完成，未 Review/发布；[执行与验收](archive/releases/v2.4.0/execution.md)。
- 2026-09-27：V2.4.0（50）独立复审两项 P2 修复、复查及资源收尾完成，未发布；[验证记录](archive/releases/v2.4.0/qa/build50.md)。
