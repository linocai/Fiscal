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

## Build57：Agent 记录报销（同日）

- 用户需求：原 App 的“可报销”——把一笔或多笔消费标记为可报销（可部分金额），进入待入账；回款与取消剩余也由 Agent 记。后端报销接口原样沿用。
- 实施（tag `v2.4.0-build57` → `321be76`）：新增 6 工具（共 25）：`fiscal_list_reimbursements`、`fiscal_list_reimbursable_expenses`（读）；`fiscal_create_reimbursement`（默认创建后立即提交，因后端仅已提交报销进入现金流；幂等重放时先重读当前状态再决定是否提交；提交失败返回草稿 `claim_id`）、`fiscal_submit_reimbursement`、`fiscal_record_reimbursement_receipt`、`fiscal_cancel_reimbursement_outstanding`（写，需写入窗口；回款与取消的后端 preview→commit 两步在网关内完成，幂等键派生为 UUID）。面板报销待回款行账户显示“回款时确定”。
- 验证：MCP 单测 42/42；本地一次性 PostgreSQL + 真实 Backend + 本地 MCP：机票（储蓄卡）+ 酒店（信用卡）合并报销 2,060、晚餐部分报销 160；重放同 key 不重复建单；超额报销 `reimbursement_expense_overallocated`、超额回款 `reimbursement_receipt_exceeds_outstanding` 被拒；回款 1,500 生成 `reimbursement_receipt` 交易，储蓄卡 8,480→9,980；取消剩余后状态 `partially_received_cancelled`、待入账移除；月报应报销 1,660、已收 1,500、个人预计 720、已实际 880，人工核算一致；面板待入账显示报销回款与未定日期提示。
- 上线：HZ MCP `releases/20261016-build57-321be76`（`0.1.0+build57`，preflight 通过），Web `releases/20261016-web-build57-321be76`；公网页面/discovery 200、25 工具、health 200、过期 Session 401。后端未变。回退指向 Build56；删除 Build55 release，本地临时库与构建包已删。
