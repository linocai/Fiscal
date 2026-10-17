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
