# Fiscal Build56：Agent 现金流计划与只读用户面板

日期：2026-10-16（Asia/Shanghai）｜tag `v2.4.0-build56` → `f4f9297`｜状态：HZ 已上线（后端未变）

## 需求与决定

- 用户：原生 App 的“未来待入账”需要 Agent 能写入，同时自己在面板里能看到。数据一直在后端 `cash_flow_items`，只是 App 退役后无入口。
- 面板登录改用 Google Authenticator（只读 Session：`read:reports/read:ledger/export:reports`），数据全部经 MCP，不在浏览器放个人 API key；Session token 存 sessionStorage（仅当前标签页）。控制台线上 `runtime-config.js` 由历史遗留的 `mock` 改为 `session`。

## 实施

- MCP 新增 6 工具（共 19）：`fiscal_list_cash_flow_items`（活动计划或 `month` 历史）、`fiscal_get_cash_flow_outlook`（`/reports/facts`，as-of 口径）、`fiscal_create_cash_flow_item`、`fiscal_confirm_cash_flow_item`、`fiscal_settle_cash_flow_item`、`fiscal_cancel_cash_flow_item`；写工具需写入窗口；新建/入账的 `idempotency_key` 经 uuid5 派生为后端要求的 UUID `Idempotency-Key`。后端规则：计划为 expected，须先 confirm 才能 settle（联调发现，已补 confirm 工具）。
- 只读 Session 不能申请写入窗口（需 `stage:imports`），面板无法被提升为写入方。
- 面板：新增“现金流”首页（未来 30 天汇总 + 待入账/历史两栏，逾期与未定日期单列，已入账显示实收金额与实际日期）；月报读 v2 `daily` 并按 4 天分组、计算分类占比；账本与现金流显示账户/分类名称；月份默认东八区当月；CSV 导出直接下载；会话过期自动回登录页；修复网格溢出与手机宽度表格。
- 文档与 discovery：工具清单、确认→入账流程、写入窗口覆盖范围、面板入口。

## 验证

- MCP 单测 41/41；ruff 通过；Web `tsc -b` 与构建通过。
- 本地全链路（一次性 PostgreSQL + 真实 Backend app + 本地 MCP HTTP + 面板静态页）：模拟 Agent 经 TOTP Session + 写入窗口建账户/分类、6 条计划（含 4 期月度房租、转账、逾期话费）、确认并入账稿费（计划 3,000 实收 2,800）、取消健身卡、提交两笔消费批次；outlook 现金 23,498.50、30 天 +15,000/−4,500、预计 33,998.50、逾期 128 单列，人工核算一致。浏览器：面板登录、现金流两栏、月报、账本名称、刷新保持登录、网关重启后自动回登录页、375px 手机宽度均验证。
- 生产：HZ MCP `releases/20261016-build56-f4f9297`（`0.1.0+build56`，preflight 通过），Web `releases/20261016-web-build56-f4f9297`（`runtime-config` session）；公网页面/discovery 200、19 工具、CORS 预检允许 console 携带 Authorization、过期 Session 401、线上面板显示登录页且无控制台错误。真实账本数据的面板登录需用户本人验证码，未代做。

## 回退与资源

- 回退：HZ `current` 指回 `releases/20261016-build55-6ae1a3e` / `20261016-web-build55-6ae1a3e` 并重启 `fiscal-mcp`（面板回到 mock 控制台）。
- 资源：删除 HZ 上传包与 Build54 release（约 22 MiB）；本地一次性库、预览副本、临时 launch 配置与构建包已删；`.claude/settings.local.json` 为用户权限配置，未动。
