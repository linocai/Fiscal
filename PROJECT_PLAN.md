# Fiscal · PROJECT_PLAN

> 更新：2026-09-27（Asia/Shanghai）｜目标：**V2.4.0（51）**｜状态：**Build51 一条龙发布完成**

## 概述

将 Fiscal 收敛为个人记账、账户与真实负债、近期资金安排。用户已确认完全取消 PDF 账单导入与多人报销分摊，明确保留手机截图 OCR，其余按本轮精简方案实施。
Build49 完成精简，Build50 修复独立复审两项 P2；一条龙发布真实读取发现的旧快照兼容遗漏在 Build51 闭环。交付与恢复证据见 [发布记录](archive/releases/v2.4.0/RELEASE_STATE.md)，产品契约见 [执行记录](archive/releases/v2.4.0/execution.md)。

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

- **V2.4.0（51）已上线并换装 Mac**：源码 `b006ed906fb150a996499bdcbecd82063ee71723`，不可变 `v2.4.0-build51` 已推送；后端同 revision / `20260926_0042`。发布证据见 [发布记录](archive/releases/v2.4.0/RELEASE_STATE.md)。
- 累计审查覆盖实际旧客户端 `825705e`、旧后端 `db95c13` 至本次发布；实施基线 `2d5cc84`，Build49 精简、Build50 两 P2 修复及 Build51 旧历史快照兼容分别复查。
- Build50 上线读取发现旧报销快照中嵌套交易关系仍有旧字段；Build51 统一纯读适配，保留原 JSON、金额与现行严格契约，月报/年报/CSV 生产读取已恢复。
- Build51 后端隔离 PostgreSQL **441/441、0 skip**，静态检查通过；旧快照月报/年报/CSV/归档恢复回归通过，独立复查无 finding。
- 客户端功能验证沿用未改业务源码的 Build50：全量335/335、定向6/6、双端商户UI各1/1；Build51 最终三组 Release 构建、签名、架构、dSYM 与 ZIP 解包核验通过。Mac单实例启动，总览及财务分析真实读取通过。
- 0041→0042 迁移前后备份及隔离恢复已验证；Build51 再部署16张金融/历史表完整指纹及 data_revision 不变，服务与4个timer恢复正常。0042 无 downgrade，旧版回退必须用验证过的0041整库恢复集。
- iOS 签名设备构建已就绪，由用户通过 Xcode 安装；未生成 IPA。最新设备支持审计两台现用手机均通过，`pending_devices=[]`。
- 本地构建临时副本和被替代Build50 ZIP已回收，测试资源check complete；保留正式Build51包/符号、iOS构建、回退App、生产恢复集和最终证据。远端暂存及本地传输bundle均已精确回收并核验。原有AGENTS与六份scheme 7/7不变。
- 精简后的正式源码统计见 [Build50统计](archive/releases/v2.4.0/qa/build50-metrics.json)：净少82文件、19,981物理行，OpenAPI188→145；Build51仅追加旧快照兼容与回归，不扩大功能。

## 当前 Plan

本轮无未完成施工；发布功能、备份恢复、签名、Mac换装及本地/远端资源核验全部通过。iOS最终设备安装由用户完成。

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

- 2026-09-27：V2.4.0（51）旧历史快照兼容修复、441项回归、独立复查、后端升级与双端签名交付；[发布记录](archive/releases/v2.4.0/RELEASE_STATE.md)。
