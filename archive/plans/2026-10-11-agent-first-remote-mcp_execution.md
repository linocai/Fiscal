# Fiscal Agent-first 阶段四远程 MCP 工程记录

日期：2026-10-11（Asia/Shanghai）  
状态：HZ MCP gateway、DNS、TLS 和公网只读 smoke 已完成；真实 Agent 多终端账单闭环待用户执行。

## 架构决定

根据 `/Users/linotsai/Lino/hz_info.md`，Fiscal 生产 API 和 PostgreSQL 已迁到 NB，
HZ 只保留 Nginx 与其他独立服务。因此远程 MCP 采用 HZ 边缘网关：

```text
Agent -> HTTPS mcp.fiscal.linotsai.top/mcp -> HZ Nginx
      -> 127.0.0.1:8050 fiscal-mcp.service
      -> HTTPS fiscal.linotsai.top/api/v1 -> NB Fiscal API/PostgreSQL
```

HZ 不成为账本写入者，不开放 8050，不复制数据库。MCP gateway 只转发已有
service contract；Agent key 仍由 scope 和后端 confirmation boundary 控制。

## 已完成的工程资产

- `MCP/src/fiscal_mcp/http_server.py`：JSON-RPC POST transport、Bearer Key 注入、
  `Mcp-Session-Id`/protocol headers、health endpoint、body limit、CORS allowlist、
  405/413/401/404 边界。
- `MCP/pyproject.toml`：增加 Uvicorn runtime 与 `fiscal-mcp-http` entry point。
- `MCP/ops/systemd/fiscal-mcp.service`：HZ loopback systemd unit，硬化边界，环境文件
  从 `/etc/fiscal/mcp.env` 注入。
- `MCP/ops/nginx/fiscal-mcp.conf`：`mcp.fiscal.linotsai.top` 的 HTTP challenge、TLS、
  `/health`、`/mcp` 代理、限流和请求头转发；不开放 8050。
- `MCP/ops/fiscal-mcp.env.example`：NB backend URL/token、Agent scope、HTTP path/port、
  CORS 和确认 secret 的安装模板。
- `MCP/ops/clients/fiscal-remote-mcp.example.json` 与 `MCP/ops/README.md`：多终端 URL/Key
  配置、DNS/TLS、Nginx、service 安装顺序和用户验收边界。
- `MCP/tests/test_http_server.py`：健康、认证、session、tool call、notification、404/413 回归。

## HZ 部署回执

- HZ release：`/opt/fiscal-mcp/releases/20261011-remote-mcp-aba6b683`，`current` 已指向该 release；Python 3.12 venv、Uvicorn 和依赖安装完成。
- `fiscal-mcp.service` 已安装、enabled、active；仅监听 `127.0.0.1:8050`，常驻内存约 22 MiB。
- `/etc/fiscal/mcp.env` 已由 root 写入、`root:fiscal-mcp 0640`；NB URL 和现有有效 Fiscal access key 已注入，MCP 仅启用 `read:reports,read:ledger,stage:imports,export:reports`。
- HZ 本机验证：`GET /health` 200；`initialize`、`tools/list`（9 tools）和 `fiscal_search_ledger` 读取均 200；NB `/api/v1/health/live` 200，真实 ledger read 返回有效数据。
- `mcp.fiscal.linotsai.top` A 记录已解析到 `118.178.122.194`；Let's Encrypt 证书已签发，有效至 2027-01-09；完整 Nginx site 已启用，HTTP 自动跳转 HTTPS。
- 公网验证：`GET /health` 200、无 Bearer 的 `/mcp` 401、未知路径 404；带真实 MCP key 的 `initialize`、`tools/list`（9 tools）和 `fiscal_search_ledger` 均 200。
- 8050 保持 loopback；HZ UFW 仅开放 22/80/443，NB 到 HZ:8050 连接超时，未形成公网直连入口。

## 本地验证

- `PYTHONPATH=MCP/src Backend/.venv/bin/python -m unittest discover -s MCP/tests -v`：20 passed。
- `Backend/.venv/bin/ruff check MCP/src/fiscal_mcp/http_server.py MCP/tests/test_http_server.py MCP/scripts/preflight.py MCP/tests/test_preflight.py`：通过。
- `python3 -m compileall -q MCP/src MCP/scripts`：通过。
- 本地测试只生成 Python 缓存，已在收尾时清理。

远程部署后补充：HZ/NB 已连接进行只读 smoke；没有修改 NB 数据库、Fiscal API、原生 App 或现有 HZ 站点。HZ Nginx `nginx -t` 通过，保留既有 `protocol options redefined` warning。

## HZ 用户执行清单

1. DNS、证书和 Nginx HTTPS site 已完成；保留 `dig +short A mcp.fiscal.linotsai.top` 与 `/health` 检查作为日常回归。
2. 用 preflight 检查真实 env；确认 `FISCAL_BACKEND_URL=https://fiscal.linotsai.top/api/v1`，backend token 有效，
   Agent key 只授予 `read:reports,read:ledger,stage:imports,export:reports`。
3. 从两个不同终端配置 `https://mcp.fiscal.linotsai.top/mcp`，完成 initialize、tools/list、月报读取和账本搜索；MCP key 从 HZ `/etc/fiscal/mcp.env` 的 root-readable secret store 取出后分别保存到 Agent secret store。
4. 用真实一周账单完成暂存、校验、网页确认/忽略及重复请求测试；通过后再决定是否授予 `commit:imports`。

## 未执行与风险边界

- 已 SSH HZ 并部署 MCP/systemd/DNS/TLS/Nginx；没有迁移 NB 数据库、没有开放 8050。真实账单写入、`commit:imports` 开放和多终端业务验收仍未执行。
- 当前 API key registry 是进程环境中的配置 key；多终端可以共享同一 key，但若要每终端独立撤销/审计，
  后续应增加持久化 key registry，再替换环境单 key 模式。
- 远程 transport 当前返回 JSON-RPC JSON 响应并兼容 session header；如某个具体 Agent 只接受 SSE 旧 transport，
  需要针对该客户端增加适配，不改变 Fiscal service contract。
