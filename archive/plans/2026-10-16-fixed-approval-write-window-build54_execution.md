# Fiscal Build54：固定批准页、30 分钟写入窗口与全方法鉴权

日期：2026-10-16（Asia/Shanghai）｜tag `v2.4.0-build54` → `8a36ff9`（含 `e48fed1`）｜状态：HZ 已上线

## 来源与决定

- 记账 Agent 复验 N1：`initialize`/`tools/list`/`ping` 只检查头非空，不校验凭证。N2（10 月分期计划出现）确认为 Build52 #4 的预期结果，未改。
- 用户决定：批准页改固定网址；一次批准开 30 分钟写入窗口，窗内任何提交不再批准；无 Agent 申请时页面不可输入。工程补充配对码与待批上限，防止公开列表中误批外人申请。

## 实施

- 所有 `/mcp` 请求先校验 Session/Bearer，失效返回 HTTP 401（`session_expired`/`unauthorized`）。
- 取消逐请求 operation token 与 request digest；新增 `write_window` 申请（旧 `operation` 作别名），批准后在发起 Session 上设置 `write_until=+1800s`，提交仅检查窗口；窗口只属于该 Session。
- 申请带 4 位 `pairing_code`；`GET /auth/challenges/pending` 公开列出待批申请（不含 poll token）；同时待批上限 5（`too_many_pending` → 429）；`approval_url` 固定 `/agent/approve/`。
- 批准页每 3 秒刷新列表，无申请时不渲染输入框；Agent 文档、discovery、MCP README 同步。
- 风险提示：待批申请的 `intent` 公开可见；TOTP 码在 ±1 时间窗内可重用于另一条申请（既有行为）。

## 验证

- MCP 单测 37/37（交付时误报为 39/39，2026-10-16 更正）；Web 构建通过。本地 mock 网关 + 浏览器全流程：空列表无输入框、申请自动出现且配对码一致、页面批准后列表清空、无窗口提交 `write_window_required`、开窗后两笔提交无需再批、过期 Session `tools/list` 401、手机宽度正常；预览中发现并修复空列表停在“正在读取”的初始状态 bug。
- 生产：HZ MCP `releases/20261016-build54-8a36ff9`（`serverInfo 0.1.0+build54`，preflight 通过，重启后 health ok）；Web `releases/20261016-web-build54-8a36ff9`（沿用线上 `runtime-config.js`）。公网：页面与 discovery 200；pending 200 且 CORS 允许 console；过期 Session `tools/list` 401；无 Session 申请写入窗口 401；线上批准页空列表无输入框。后端未变。

## 回退与资源

- 回退：HZ `current` 指回 `releases/20261014-build52-0958d48` / `20261014-web-build52-0958d48` 并重启 `fiscal-mcp`（旧流程要求逐请求授权）。
- 资源：删除 HZ 上传包与被两次替换的 `20261011-totp-429b342`、`20261011-web-totp-c1bf49a`（约 22 MiB）；本地预览服务已停、临时 launch 配置与构建包已删，scratchpad 无本轮残留。
