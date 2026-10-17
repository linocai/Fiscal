# Fiscal Build58：Build52–57 独立审查与修复

日期：2026-10-17（Asia/Shanghai）｜tag `v2.4.0-build58` → `5c45ec3`｜状态：NB Backend、HZ MCP/Web/Nginx 已上线

## 审查

- 用户要求对已上线版本做独立 review。范围 `29ab5ec..321be76`（Build52–57；后端线上 5dc3349 与 321be76 树相同）。结论：无 P0/P1；2 P2、4 P3、2 待确认。写入窗口与 Session 绑定、只读 Session 防提权、写工具窗口覆盖、XSS、错误透传、金额单位均核实无问题。
- 修复后两轮复查（`321be76..9e3f48d`、`9e3f48d..1d8af59`），最终无新 P2；剩余见“接受的残留”。

## 修复（用户授权快修）

- P2-1 待批申请被匿名占满：匿名 session 申请按来源 2 条、总 20 条；write_window 每 Session 仅保留最新一条且不计入匿名配额；面板错码复用同一申请；来源 IPv6 按 /64、IPv4 映射地址还原。
- P2-2 回款/取消重试不安全：后端 receipt create 与 cancel_outstanding 判重哈希去掉一次性 preview_token；网关 preview 返回确定性 4xx 时以随机 token 探测重放 commit，取回原结果或抛原错误。新增 `Backend/tests/test_build58_reimbursement_replay_postgres.py`（撤修复即失败）。
- 复查新引入 P2：全局错码预算会挡住写入窗口批准 → 全局预算只作用于匿名 session 批准；写入窗口仅按来源限流（猜中只为发起它的 Agent Session 开窗）；去掉“错码撤销申请”（最便宜的定点阻断）。
- P3：TOTP 同一时间步只接受一次（`totp_reused` 409）；畸形 kind/scope 返回 400；confirm 工具去掉后端不支持的 scope；历史现金流按账户过滤；分类别名上限 40；面板账本正负号（`loan_principal` 等为内部）、东八区日期、100 条截断提示、当月日均按已过天数、存储文案、Safari 延迟 revoke、线上忽略 `?demo`；批准页与面板登录中文错误提示；说明页改为“不得向用户索取验证码”；console Nginx 增加 `frame-ancestors 'none'` 与 `X-Frame-Options DENY`。

## 验证

- MCP unittest 46/46、ruff；Backend ruff format/check、pyright 0、一次性 PostgreSQL 全量 449/449；Web tsc+build。
- 真实 Backend app + MCP service（一次性库）：回款原样重试返回同一回款单、余额只加一次（82,000）；同 key 改参数被拒；取消剩余重试返回原结果。
- 生产：NB `deploy.sh --apply --public-smoke`（门禁 174 passed/275 skipped），release `/opt/fiscal/releases/99cc25da7ee7`，无迁移，前后备份 `fiscal-20261017T01362{5,6}Z.dump` 已验证；HZ MCP `releases/20261017-build58-5c45ec3`（`0.1.0+build58`，preflight 通过），Web `releases/20261017-web-build58-5c45ec3`；Nginx 先备份 `sites-available/fiscal-web.conf.bak-20261017-build58`、`nginx -t` 通过后 reload。公网：页面/discovery 200、CSP/XFO 头生效、畸形申请 400、过期 Session 401、`?demo=empty` 仅显示登录页。生产 `FISCAL_MCP_API_KEY` 为空（break-glass key 按设计全权限）。域名无 AAAA 记录。

## 接受的残留（P3）

- 与用户同一出口来源（NAT/VPN/同一 /64）的攻击者可按来源限流挡住批准 5 分钟；不引入第二个秘密无法消除。
- 匿名可从多来源阻断会话申请（全局预算/名额），已持有会话与写入窗口不受影响。
- 被注入的 Agent 可反复申请写入窗口供外部猜码；仅按来源限流（IPv4，期望约 33 万次猜测）。根本修法为“配对码作为第二秘密”（用户需在批准页同时输入配对码），待用户决定。
- 待确认：Safari 实测面板 CSV 下载。

## 回退与资源

- 回退：NB `current` 指回 `releases/2a0c8d92aaa9`；HZ 指回 `20261016-build57-321be76` / `20261016-web-build57-321be76` 并重启 `fiscal-mcp`；Nginx 用上述 .bak 恢复后 reload。
- 资源：删除 NB 部署源与 release `6876d204738b`、HZ Build56 release、上传包；本地一次性库、构建包已删；数据库备份按规则保留。

## Build59：账目报销关联、编辑工具与面板账户页（同日）

- 来源：记账 Agent 报告“豆豆”交易的账目查询 `reimbursement_relations` 为空但作废被 `reimbursement_claim_in_use` 拦截；缺少改交易标题与改报销方的工具。用户另要求面板恢复各账户余额与信用欠款。
- 根因与修复（tag `v2.4.0-build59` → `5287051`）：
  - 后端 `TransactionService.responses_with_capabilities`（列表/总览）只算关联标记不填明细；现对有报销或分期关联的行调用 `response_with_relation`，与单笔响应一致。报销单更新的判重哈希同样去掉一次性 preview_token。
  - MCP 新增 `fiscal_update_transaction`（只改标题/备注/分类，其余字段从当前版本原样回传）与 `fiscal_update_reimbursement`（改标题/报销方/预计日期/备注或整组消费，保留分配 id，网关内 preview→commit），共 27 工具。
  - 面板新增“账户”首页：资金合计、信用欠款合计（含逾期）、净资产；资金账户余额；信用账户欠款/额度/可用额度、逾期金额与下一期应还。说明页补账户字段规则（后端对此只返回笼统的 `invalid_account_configuration`）。
- 验证：新增 `Backend/tests/test_build59_ledger_relations_postgres.py`（撤修复即失败）；Backend 全量 450/450、ruff、pyright 0；MCP 47/47；Web tsc+build。真实 Backend + MCP 复现报告场景：账目关联可见；改标题后金额/账户/分类/关联不变；报销方改“公司”后仍 pending、待回款 140000，原样重试不重复；仅 1 张报销单、余额与待入账正确。面板账户页本地全链路核对（资金 21,051.00、欠款 3,156.50、净资产 17,894.50、逾期 450 与下一期 10/23 分开显示），手机宽度无溢出。
- 上线：用户授权“一起直接上线”，未做复查（已建议）。NB release `/opt/fiscal/releases/5dca7810c3b1`，无迁移，前后备份 `fiscal-20261017T03121{5,6}Z.dump` 已验证；HZ MCP `releases/20261017-build59-5287051`（`0.1.0+build59`），Web `releases/20261017-web-build59-5287051`，Nginx 未变。公网：页面/discovery 200、27 工具、写入窗口覆盖 13、防嵌入头仍在、过期 Session 401、面板登录页无控制台错误。
- 回退：NB 指回 `releases/99cc25da7ee7`；HZ 指回 Build58 两个 release 并重启 `fiscal-mcp`。资源：删除 NB `2a0c8d92aaa9`、HZ Build57 release 与上传包，本地临时库与构建包已删。
