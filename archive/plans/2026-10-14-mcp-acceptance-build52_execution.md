# Fiscal MCP 首次业务验收问题修复与 Build52 发布记录

日期：2026-10-14（Asia/Shanghai）
状态：已上线 NB Backend、HZ MCP、HZ Web；首轮真实批次闭环待记账 Agent 复跑。

## 来源与决定

记账 Agent 首次远程验收提交 12 项问题（年报 409、还款缺 `credit_cycle_id`、无账户/分类发现工具、当月账期误判逾期、错误详情被吞、公开文档不足、写入授权错误码误导、approval_url 缺斜杠、授权在后端失败时被消耗、内存 Session、标准 MCP 授权、CSV 表头歧义）。用户确认：快修只加 build；#2 不做后端自动选账期，由 Agent 从 `open_cycles` 明确选择；#9 改三态；#10 仅文档说明；#11 进 Backlog。

## 实施（提交 `0958d48`，tag `v2.4.0-build52`）

- MCP：`/reports/v2/*` 及 export.csv 固定 `X-Fiscal-Report-Balance-Semantics: as-of-v1`；候选支持 `credit_cycle_id`；新增 `fiscal_list_accounts`（固定账期信用账户附未结清 `open_cycles`，按到期日升序）与 `fiscal_list_categories`（扁平化树），scope `read:ledger`；4xx 透传后端 message、`http_status`、`request_id` 与 ≤4KB 的 `backend_details`，5xx 保持泛化；operation 错误码 `operation_token_missing/invalid/mismatch/expired/used/in_progress`；授权三态（4xx 消耗，网络/5xx 释放以便同参数幂等重试）；`approval_url` 拼 `/?challenge=`；`serverInfo.version=0.1.0+build52`。
- Backend：v2 期间报表账期状态按 `min(期末, 今天)` 判断（历史月份不变，金额本就取当前值）；CSV 首列表头“分类”→“章节”。
- Web 公开页：`/agent/` 与 discovery 补 challenge/poll 请求响应、token 位置、digest 规则（`ensure_ascii=False`）与实算示例、commit JSON-RPC 示例、错误码、金额单位、重启失效说明、11 个工具清单。

## 本地验证

- MCP 单测 36/36（新增 9：报表头、4xx/5xx 错误、列表路由、列表工具与 open_cycles、credit_cycle_id、operation 三态与错误码、Session 提交释放/消耗、approval_url）。
- Backend：ruff check/format、pyright 0 错误；一次性本地 PostgreSQL 全量 426 passed / 18 failed。18 项在未改动 `main` 同样失败，均为 `ArchiveCompatibilityError`（archive 服务不识别 `20261010_0043`），属 0043 上线遗留，已另开任务。新增 `tests/test_build52_report_debt_status_postgres.py`，撤掉修复即失败。
- 端到端（MCP service → 真实 Backend app → 一次性库）：2026 年报与年度 CSV 200、revision 一致；列车贷 open_cycles → 带 `credit_cycle_id` 还款 + 消费批次校验通过 → 无 token `operation_token_missing` → operation 授权提交成功；账期还清、储蓄余额 376,750 分符合预期；重复使用 `operation_used`；漏账期校验 `credit_cycle_required`；版本冲突 details 完整透传。

## 生产部署

- 用户 2026-10-14 授权“直接上线”，未做独立 review。
- NB：部署源为 `0958d48` 的 Backend 树单提交快照 `6876d204738b3de66443f75357cb70b44488a82d`；`deploy.sh --apply --public-smoke` 通过（NB 门禁 171 passed / 273 skipped、ruff、pyright）。release `/opt/fiscal/releases/6876d204738b`，Alembic 仍 `20261010_0043`；前后备份 `fiscal-20261014T123429Z.dump`、`fiscal-20261014T123431Z.dump` 已验证；`fiscal-api` active、NRestarts=0，公网 live 200。
- HZ MCP：release `/opt/fiscal-mcp/releases/20261014-build52-0958d48`（Python 3.12 venv，httpx 0.28.1，uvicorn 0.54.0），production preflight 通过；`current` 原子切换并重启，loopback/公网 `/health` ok，未鉴权 `initialize` 401，公网 challenge 返回 `/agent/approve/?challenge=`（该 challenge 未批准、自然过期）。
- HZ Web：release `/opt/fiscal-web/releases/20261014-web-build52-0958d48`，`current` 原子切换；首页、`/agent/`、批准页、discovery（11 tools）、`runtime-config.js` 均 200。沿用线上原有 `runtime-config.js`（`mode: "mock"`，与 `Web/ops/runtime-config.production.js` 不一致，属既有状态，本次未改变控制台行为）。
- 资源：NB 部署源目录、tar 与日志，HZ `/tmp` 上传包已删除；本地 scratchpad 临时库与构建包未获删除授权，随会话回收。

## 回退

- Backend：`/opt/fiscal/current` 指回 `/opt/fiscal/releases/53906818483e` 并重启 `fiscal-api`（无迁移，无需恢复库）。
- MCP：`/opt/fiscal-mcp/current` 指回 `releases/20261011-totp-429b342` 并重启 `fiscal-mcp`；重启会清空内存 Session。
- Web：`/opt/fiscal-web/current` 指回 `releases/20261011-web-totp-c1bf49a`。

## 待办

1. 记账 Agent 复跑：重新申请 Session，验收年报/年度 CSV、列表工具，再走一周账单暂存→校验→提交闭环。
2. 修复 archive 服务对 0043 的兼容（备份恢复链路，需全量 PostgreSQL 回归）。
3. 核实控制台 `runtime-config.js` 应为 mock 还是 http（用户决定）。
4. Backlog：标准 MCP 授权（#11）、Session 持久化（#10）。
