# Fiscal · PROJECT_PLAN

> 更新：2026-10-16（Asia/Shanghai，Build55 Agent 新建账户/分类上线）｜当前发布：**V2.4.0（55）**｜下一阶段目标版本：**待定**｜状态：**Agent-first 运行；原生 App 已退役，业务入口为远程 MCP**

## 概述

将 Fiscal 从需要用户主动打开的原生记账 App 转为 **Fiscal Ledger Service + MCP Server + Web Console**：Agent 负责周期性批量整理账单，网页负责待确认、月底分析、查询和导出，后端与数据库继续作为唯一事实源。iOS/macOS 以 Build51 为冻结基线，不再新增产品功能。
用户已确认完全取消 PDF 账单导入与多人报销分摊，明确保留手机截图 OCR，其余按本轮精简方案实施。Build49 完成精简，Build50 修复独立复审两项 P2；一条龙发布真实读取发现的旧快照兼容遗漏在 Build51 闭环。交付与恢复证据见 [发布记录](archive/releases/v2.4.0/RELEASE_STATE.md)，产品契约见 [执行记录](archive/releases/v2.4.0/execution.md)。本轮方案详见 [Agent-first 改造方案](archive/plans/2026-10-10-agent-first-mcp-web.md)。

## 稳定技术决定

- 现役技术栈为 FastAPI/PostgreSQL 后端、Python MCP 网关与 React 静态网页；原生 SwiftUI 客户端已退役（tag `native-app-final`）。
- 主空间为总览、交易、账户；分析下沉总览，信用/借款/分期从账户进入；设置独立可达。未来收付款统一展示，来源事实继续区分。
- 手工、文本解析、截图 OCR 使用同一套交易字段与校验；截图在本机识别，只发送文字，必须人工确认，不恢复自动入账。
- 简单报销为一个对象、一组关联费用、多次实际回款；移除多人对象与分配接口。内部费用归属保留，以支持金额校验、撤销和历史报表。
- 金额输入为元、领域/API 为 Int64 分，统一 CNYAmountParser；业务日期 Asia/Shanghai。借款本金和本金还款不计收入/消费，余额由真实 postings 派生。
- 保留固定账期、随借随还、分期与全额结清；不虚构额度、日期或历史余额。预览与确认、幂等键、请求结果不明恢复、备份恢复不削弱。
- 未来 30 天为上海今日至 +29 天，现金与储蓄加剩余流入减剩余流出；同 revision、不重复统计来源事项，未知日期/逾期/缺口单列。
- 报表只留当前 v2 月/年报及 CSV，保留必要分析与交易追溯；取消 PDF 导出、分类拆分及独立复杂商户管理，保留分类合并、名称与识别映射。
- 旧运行接口随 2.4 同步升级契约退役；历史枚举、金额事实、原始归档不篡改。迁移遇到不能无损转换的数据明确拒绝，不静默删账。
- 后端和数据库继续作为唯一账本事实源；MCP 只调用 service 层，不直连数据库，不暴露任意 CRUD/SQL。网页不复制财务规则。
- Agent 以导入批次工作；批次先生成待确认候选，校验、幂等、版本、撤销和审计沿用现有 AI proposal/ledger 语义，默认不自动直写。
- 第一阶段网页只保留待确认、月度报告、账本搜索、设置/导出；Agent 密钥按读、暂存、提交、导出 scope 分层，支持撤销和轮换。
- 原生 App 已退役：源码在 tag `native-app-final`，Build51 安装包与设计稿在本地归档；后续业务入口统一走远程 MCP。
- 远程 MCP 网关只部署在 HZ，通过 HTTPS 转发到 NB 上唯一的 Fiscal API；HZ 不保存账本数据库、不开放 MCP loopback 端口。Agent 通过 Google Authenticator challenge 获取 Session，写入需在固定批准页按配对码批准一次 30 分钟写入窗口（绑定该 Session）；个人 API key 仅作人工 break-glass。

## 当前状态

- **V2.4.0（52）已上线**（2026-10-14，tag `v2.4.0-build52` → `0958d48`）：修复记账 Agent 首次验收 12 项问题中的 10 项（年报 as-of 口径、还款 `credit_cycle_id`、账户/分类列表工具、当月账期逾期误判、错误透传、写入授权三态与错误码、公开文档等）。详见 [Build52 记录](archive/plans/2026-10-14-mcp-acceptance-build52_execution.md)。
- **Build53**（tag `v2.4.0-build53` → `5dc3349`）：archive 支持 0043 并归档 `import_batches`，修复自 10-11 起不可用的归档导出/恢复；本地 PostgreSQL 全量 448/448。
- **Build54**（tag `v2.4.0-build54` → `8a36ff9`）：批准页固定 `/agent/approve/` 并按配对码列出待批申请；一次批准开 30 分钟写入窗口（绑定发起 Session）；所有 `/mcp` 方法校验凭证；Build55 增加 `fiscal_create_account`/`fiscal_create_category`（同样需写入窗口，13 工具）。见 [Build54/55 记录](archive/plans/2026-10-16-fixed-approval-write-window-build54_execution.md)。
- 线上组成：NB Backend release `/opt/fiscal/releases/2a0c8d92aaa9`（`5dc3349` Backend 快照，回退 `6876d204738b`），Alembic `20261010_0043`；HZ MCP `releases/20261016-build55-6ae1a3e`（`serverInfo 0.1.0+build55`）；HZ Web `releases/20261016-web-build55-6ae1a3e`。上一版 release 均保留可回退。
- 远程 MCP 与 TOTP Session 原始链路见 [TOTP 执行记录](archive/plans/2026-10-11-fiscal-totp-session_execution.md)；Backend 0043 导入批次见 [后端记录](archive/plans/2026-10-11-agent-first-backend-0043_execution.md)；Web 部署见 [Web 记录](archive/plans/2026-10-11-fiscal-web-console_execution.md)。
- 真实账本尚无经 MCP 提交的批次；首轮一周闭环待记账 Agent 按新文档（配对码 + 写入窗口）复跑，Build54 重启已清空旧 Session。
- 控制台 `runtime-config.js` 线上为 `mode: "mock"`，与 `Web/ops/runtime-config.production.js`（http）不一致，待用户决定；`/agent/`、批准页与 discovery 不受影响。
- 0042 无 downgrade，回退到 0041 前版本必须用验证过的整库恢复集；Build52 无迁移，前后备份 `fiscal-20261014T1234{29,31}Z.dump` 已验证。
- 原生 App 2026-10-12 退役（tag `native-app-final`，本地归档 `~/文稿/Claude/Fiscal-archive/`），见 [退役记录](archive/plans/2026-10-12-native-app-retirement.md)；V2.4.0（51）客户端发布证据见 [发布记录](archive/releases/v2.4.0/RELEASE_STATE.md)。
- TOTP 绑定临时材料仍在 `~/文稿/Codex/2026-10-11-fiscal-totp/`，首轮真实验收后由用户删除。

## 当前 Plan

1. **记账 Agent 复跑验收**：新 Session 下年报/年度 CSV 200 且 revision 与月报一致；`fiscal_list_accounts`/`fiscal_list_categories` 可直接用于候选；一周账单暂存→校验→写入窗口内提交，提交后月报/年报/CSV 一致。
2. **归档恢复演练**：Build53 后在隔离库做一次生产归档导出→恢复演练，确认 `import_batches` 往返。

## Backlog

### Agent-first 改造（当前优先）

- **批次导入契约**：导入批次及其状态、版本、指纹、校验错误、交易回执和审计已落地；正式账本仍由既有 TransactionService 写入，不建立第二套账本。
- **MCP 层**：月报/年报/账本搜索/导出、批次创建/查看/校验/忽略和受控提交已由 TOTP Session 与写入窗口保护；Bearer 只作兼容/人工 break-glass。
- **网页控制台**：实现待确认、月度报告、账本搜索、设置/导出四个入口；先只读，再接入整批确认。
- **第一阶段验收**：Mock、隔离后端、生产 `/import-batches` 和 TOTP challenge/session/operation 公网 smoke 已覆盖契约边界；真实一周批次、生产月报/年报/CSV 一致性与扫码后首轮业务闭环留待用户验收。
- **非目标**：不删除原生 App、不删除历史数据、不开放任意 CRUD/SQL、不做多用户和新的复杂财务规则。
- **标准 MCP 授权**（验收 #11）：让标准 MCP 客户端原生接入（OAuth 或免鉴权的 session 申请工具），需单独立项。
- **Session 持久化**（验收 #10）：当前 Session/授权在网关内存，重启即失效；单进程自用暂可接受。

其中独立契约、MCP stdio 入口、Mock 批次生命周期、真实后端批次写入与 Web live adapter 已完成；MCP、Web 与 Backend 0043 已生产部署并通过公网只读 smoke，真实账单月度闭环和 `commit:imports` 开放仍未执行。

### 原生端遗留反馈

2026-10-02 用户反馈的四项原生端可用性问题（计划收支入口、跨月逾期计划、关联已有账目、还款直达）随 App 退役不再施工；原文见 tag `native-app-final` 下的 `PROJECT_PLAN.md`。若 MCP/网页试运行出现同类需求再单独立项。

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
- 2026-10-10：Agent-first 阶段一、阶段二本地实现；新增 MCP/Web 独立层、原子导入批次与 0043 迁移，未部署；[阶段二记录](archive/plans/2026-10-10-agent-first-mcp-web_phase2_execution.md)。
- 2026-10-10：Agent-first 阶段三工程收尾；完成环境注入、MCP preflight、Web runtime 配置和部署/回滚交接，未部署；[阶段三记录](archive/plans/2026-10-10-agent-first-mcp-web_phase3_execution.md)。
- 2026-10-11：Agent-first 阶段四远程 MCP 工程实现、HZ systemd/Nginx/TLS 部署及公网只读 smoke 完成；[远程 MCP 记录](archive/plans/2026-10-11-agent-first-remote-mcp_execution.md)。
- 2026-10-11：Web 控制台生产静态包、DNS、Let's Encrypt、Nginx HTTPS 与同源只读 API 代理部署完成；[Web 记录](archive/plans/2026-10-11-fiscal-web-console_execution.md)。
- 2026-10-11：Backend 0043 生产迁移、备份、重启及网页批次接口修复完成；[后端记录](archive/plans/2026-10-11-agent-first-backend-0043_execution.md)。
- 2026-10-11：Web `fetch` 上下文热修重新构建并部署，公网鉴权与批次/账本只读 smoke 通过；[Web 记录](archive/plans/2026-10-11-fiscal-web-console_execution.md)。
- 2026-10-11：Web 凭证入口修正并重新部署，支持访问口令换取页面内存 key，公网认证与批次 smoke 通过；[Web 记录](archive/plans/2026-10-11-fiscal-web-console_execution.md)。
- 2026-10-11：简化认证方案落地；公共 Agent 说明/discovery、Google Authenticator Session、一次性写入授权及 HZ/NB 部署完成；[执行记录](archive/plans/2026-10-11-fiscal-totp-session_execution.md)。
- 2026-10-11：原生 App 冻结、工程与发布物归档、HZ/NB 旧发布目录清理完成；数据库、备份和现役 MCP 链路保留；[暂停归档记录](archive/plans/2026-10-11-fiscal-pause_archive_execution.md)。
- 2026-10-12：原生 App 退役移出仓库（tag `native-app-final`），本地归档迁至 `~/文稿/Claude/Fiscal-archive/`；[退役记录](archive/plans/2026-10-12-native-app-retirement.md)。
- 2026-10-14：V2.4.0（52）MCP 首次验收问题修复，NB/HZ 上线；[Build52 记录](archive/plans/2026-10-14-mcp-acceptance-build52_execution.md)。
- 2026-10-16：V2.4.0（55）Agent 经 MCP 新建账户与分类，HZ 上线；[同一记录 §Build55](archive/plans/2026-10-16-fixed-approval-write-window-build54_execution.md#build55agent-新建账户与分类同日快修)。
- 2026-10-16：V2.4.0（54）固定批准页、30 分钟写入窗口与全方法鉴权，HZ 上线；[Build54 记录](archive/plans/2026-10-16-fixed-approval-write-window-build54_execution.md)。
- 2026-10-14：V2.4.0（53）archive 支持 0043 并上线 NB，资源收尾完成；[同一记录 §Build53](archive/plans/2026-10-14-mcp-acceptance-build52_execution.md#build53archive-支持-0043同日)。
