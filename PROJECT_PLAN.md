# Fiscal · PROJECT_PLAN

> 更新：2026-10-11（Asia/Shanghai，Agent-first 改造）｜当前发布：**V2.4.0（51）**｜下一阶段目标版本：**待定**｜状态：**MCP、Web 与 Backend 0043 均已上线，待用户做真实业务验收**

## 概述

将 Fiscal 从需要用户主动打开的原生记账 App 转为 **Fiscal Ledger Service + MCP Server + Web Console**：Agent 负责周期性批量整理账单，网页负责待确认、月底分析、查询和导出，后端与数据库继续作为唯一事实源。iOS/macOS 以 Build51 为冻结基线，不再新增产品功能。
用户已确认完全取消 PDF 账单导入与多人报销分摊，明确保留手机截图 OCR，其余按本轮精简方案实施。Build49 完成精简，Build50 修复独立复审两项 P2；一条龙发布真实读取发现的旧快照兼容遗漏在 Build51 闭环。交付与恢复证据见 [发布记录](archive/releases/v2.4.0/RELEASE_STATE.md)，产品契约见 [执行记录](archive/releases/v2.4.0/execution.md)。本轮方案详见 [Agent-first 改造方案](archive/plans/2026-10-10-agent-first-mcp-web.md)。

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
- 后端和数据库继续作为唯一账本事实源；MCP 只调用 service 层，不直连数据库，不暴露任意 CRUD/SQL。网页不复制财务规则。
- Agent 以导入批次工作；批次先生成待确认候选，校验、幂等、版本、撤销和审计沿用现有 AI proposal/ledger 语义，默认不自动直写。
- 第一阶段网页只保留待确认、月度报告、账本搜索、设置/导出；Agent 密钥按读、暂存、提交、导出 scope 分层，支持撤销和轮换。
- 原生 App 冻结期间保留源码、Build51 安装包和回退能力；连续完成真实月度闭环后再决定是否归档发布入口。
- 远程 MCP 网关只部署在 HZ，通过 HTTPS 转发到 NB 上唯一的 Fiscal API；HZ 不保存账本数据库、不开放 MCP loopback 端口。Agent 通过 Google Authenticator challenge 获取 Session，写入再用一次性 operation approval；个人 API key 仅作人工 break-glass。

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
- 第一阶段独立骨架已建立：新增 `MCP/`（9 个工具契约、stdio JSON-RPC、scope/API key、确认凭证、HTTP/Mock adapter、审计和测试）与 `Web/`（待确认、月报、账本、设置/导出四页及 mock adapter）。
- 第二阶段本地实现已完成：后端新增 `import_batches` 持久化、幂等/版本校验、隔离校验、原子提交/忽略路由及 0043 迁移；MCP HTTP adapter 和 Web HTTP/MCP live adapter 已接入，原生 App 业务源码未修改。
- 阶段二验证已在一次性本地 PostgreSQL 库完成迁移与真实闭环：创建 → 校验 → HMAC 确认提交 → 重放只返回同一结果；生产只读/暂存边界见 0043 部署记录，未写入真实账单。
- 阶段三工程收尾已完成：staging/production 环境示例接入 token pepper 与批次确认密钥，MCP 提供无网络 preflight 和 stdio 运行模板，Web 静态包支持宿主覆盖 `runtime-config.js` 选择 HTTP/MCP 并保持会话密钥只在内存；回滚/迁移/人工验收边界写入运维文档。
- 阶段四远程 MCP 工程已实现并部署到 HZ：新增 JSON-RPC HTTP/ASGI transport、TOTP session/operation challenge、Bearer 兼容、session header、CORS 白名单、请求体上限、健康检查；HZ 上 systemd active、loopback 8050、DNS、Let's Encrypt、Nginx HTTPS、NB 连接和公网读写授权 smoke 均通过；未写入真实批次。
- 网页控制台已部署到 HZ `/opt/fiscal-web/current`，`console.fiscal.linotsai.top` DNS、Let's Encrypt、Nginx HTTPS 和同源 `/api/v1` 只读代理 smoke 均通过。
- 网页默认 fetch 上下文热修已部署到 `/opt/fiscal-web/releases/20261011-web-4bb08594`；截图中的 `Illegal invocation` 已由 HTTP/MCP adapter 共同修复，公网页面与鉴权接口 smoke 通过。
- Web 凭证入口已补强：原控制台保留内存凭证兼容；新公开 `/agent/` 说明、`/agent/approve/` 批准页和 `/.well-known/fiscal-agent.json` 不包含密钥，面向 TOTP Session 流程；discovery 已公开 request digest 规则。新包 `/opt/fiscal-web/releases/20261011-web-totp-c1bf49a` smoke 通过。
- Backend 0043 已部署到 NB：生产 release `/opt/fiscal/releases/53906818483e`，Alembic `20261010_0043`，迁移前后备份、171 项测试/272 项 PostgreSQL 缺失跳过、readiness、重启及 `/import-batches` 只读 smoke 均通过；没有真实批次写入。
- 工作区原有用户未提交的 `AGENTS.md` 与 scheme 改动已保留；本轮只新增独立目录和计划记录。

## 当前 Plan

阶段四远程 MCP、TOTP Session 与公共 Agent 接入见 [TOTP 执行记录](archive/plans/2026-10-11-fiscal-totp-session_execution.md)；网页上线见 [Web 控制台记录](archive/plans/2026-10-11-fiscal-web-console_execution.md)；Backend 0043 生产部署见 [后端记录](archive/plans/2026-10-11-agent-first-backend-0043_execution.md)；阶段三工程包见 [阶段三记录](archive/plans/2026-10-10-agent-first-mcp-web_phase3_execution.md)，阶段二施工见 [阶段二记录](archive/plans/2026-10-10-agent-first-mcp-web_phase2_execution.md)。用户已完成 Authenticator 绑定，下一步只剩真实账单暂存/校验/忽略/提交闭环；原生业务源码未修改。

## Backlog

### Agent-first 改造（当前优先）

- **批次导入契约**：导入批次及其状态、版本、指纹、校验错误、交易回执和审计已落地；正式账本仍由既有 TransactionService 写入，不建立第二套账本。
- **MCP 层**：月报/年报/账本搜索/导出、批次创建/查看/校验/忽略和受控提交已由 TOTP Session 与一次性 operation approval 保护；Bearer 只作兼容/人工 break-glass。
- **网页控制台**：实现待确认、月度报告、账本搜索、设置/导出四个入口；先只读，再接入整批确认。
- **第一阶段验收**：Mock、隔离后端、生产 `/import-batches` 和 TOTP challenge/session/operation 公网 smoke 已覆盖契约边界；真实一周批次、生产月报/年报/CSV 一致性与扫码后首轮业务闭环留待用户验收。
- **非目标**：不删除原生 App、不删除历史数据、不开放任意 CRUD/SQL、不做多用户和新的复杂财务规则。

其中独立契约、MCP stdio 入口、Mock 批次生命周期、真实后端批次写入与 Web live adapter 已完成；MCP、Web 与 Backend 0043 已生产部署并通过公网只读 smoke，真实账单月度闭环和 `commit:imports` 开放仍未执行。

### 原生端冻结期间暂缓

2026-10-02 用户反馈，以下问题已在 Mac 现场核实，但随原生端冻结暂不施工；若网页/Agent 试运行后仍有真实需求，再单独立项。

- **计划收支入口可发现性**：当前“管理现金流计划”藏在交易流水最底部。提供稳定、明显的入口，不随流水长度或月份筛选难以找到；用户无需先滚完整个交易列表。
- **跨月未完成计划持续可见**：逾期计划仍在管理页，但从总览/时间线的未来日期范围消失，“未来事项”又混放逾期记录。明确区分“逾期待处理”和未来计划，未完成事项跨月后仍可发现、打开与处理；不因日期过去自动完成或取消，也不把逾期金额直接混入未来30天预测。
- **关联已有账目的操作直达**：目前需“查看确认影响 → 确认本次 → 兑现入账 → 关联已有账目”，用户难以找到。让计划详情明确提供关联已有收入/支出的入口，必要状态确认在同一流程解释清楚；关联后更新计划完成进度，不重复创建交易或改变既有金额，部分完成保留剩余计划。
- **未来还款事项直达还款**：信用账单详情目前仅提示“请到还款页面处理”，缺少跳转。点击未来还款事项可进入对应信用账户/账期的还款流程，允许按实际还款日期提前登记，保留金额、付款账户及影响预览校验；操作后刷新未来待还金额。区分“还本期/部分还款”与“整个账户及未来分期提前结清”，后者进入既有全额结清流程，不把未来分期当作普通现金流直接入账。
- 真机选图、通知横幅及快捷指令交互仍未新增验证；iOS 最终安装由用户通过 Xcode 完成。

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
