# Fiscal TOTP Session 与公共 Agent 接入执行记录

日期：2026-10-11（Asia/Shanghai）  
状态：工程实现、HZ/NB 部署、公网 smoke 和用户 Authenticator 绑定完成；真实账单写入仍由用户按新 SOP 验收。

## 目标与决定

- 取消 per-Agent key 作为正常路径；Agent 先读取公开说明页和 discovery JSON。
- Agent 创建 `session` challenge，用户在 `console.fiscal.linotsai.top/agent/approve/` 输入 Google Authenticator 6 位码。
- 会话 idle 2 小时、absolute 8 小时；TOTP 每 30 秒轮换不影响已建立的 Session。
- 账单导入、校验和分析使用 Session；最终提交前创建绑定完整请求 digest 的 `operation` challenge。
- operation token 单次使用、有效 30 分钟；MCP 网关在通过 operation 后内部 mint 后端 HMAC confirmation。
- 个人 Fiscal API key 保持稳定，仅作为人工 break-glass；不写入公共页面、不自动回退、不发送给 Agent。

## 实施范围

- `MCP/src/fiscal_mcp/auth.py`：TOTP 校验、session/operation/challenge registry、空闲/绝对过期、失败限流、请求 digest。
- `MCP/src/fiscal_mcp/http_server.py`：`/auth/challenges` 创建、批准、轮询；`Authorization: Session`；健康信息和 CORS。
- `MCP/src/fiscal_mcp/server.py` / `service.py`：Session scope、一次性 operation 消费、服务端 confirmation mint；Bearer 兼容保留。
- `MCP/ops/`：preflight、env 模板、Nginx auth 路由；`MCP/README.md` 与客户端示例更新。
- `Web/public/agent/` 与 `Web/public/.well-known/fiscal-agent.json`：公开说明、批准页和机器 discovery，不含秘密。

## 验证证据

- `PYTHONPATH=MCP/src python3.14 -m unittest discover -s MCP/tests -v`：26 passed。
- Web `npm ci --no-audit --no-fund && npm run build`：通过。
- HZ preflight：production shape passed，HTTPS backend、TOTP、session scopes、TTL、approval URL、confirmation secret 均通过。
- HZ release：`/opt/fiscal-mcp/releases/20261011-totp-429b342`；systemd active/enabled，loopback `8050`；owner break-glass commit path covered by regression test。
- Web release：`/opt/fiscal-web/releases/20261011-web-totp-c1bf49a`；Nginx reload 后公开 Agent 页、批准页和 discovery 均 200，discovery 已包含 request digest 规则。
- 公网 TOTP session smoke：health、initialize、tools/list（9 tools）、月报读取通过。
- 公网 operation smoke：一次性 operation 授权被 MCP 接受，随后在不存在的 batch 上由后端返回业务错误；未产生真实账本写入。
- NB/HZ confirmation secret 指纹一致；NB API 已重启并通过 live health。
- Nginx `nginx -t` 通过；保留既有 `protocol options redefined` warning，与本次站点无关。

## 用户手动步骤

1. 打开本地一次性 enrollment 二维码 [fiscal-agent-totp.png](/Users/linotsai/文稿/Codex/2026-10-11-fiscal-totp/fiscal-agent-totp.png)，在 Google Authenticator 添加“Fiscal Agent”。不要把二维码或 secret 上传到公共位置。
2. 用任意联网 Agent 发送公开说明页 `https://console.fiscal.linotsai.top/agent/`，让 Agent 按 challenge 流程工作；用户只在批准页输入当前验证码。
3. 先完成一周账单的暂存 → 校验 → 分析 → 忽略/修正闭环；确认摘要无误后，再对真实批次走一次 operation approval。
4. 扫码确认并完成首轮真实验收后，删除本地 enrollment 目录中的 secret/URI/二维码临时材料；在删除前不要把它们加入 Git 或聊天记录。

## 回退

- 只需把 HZ `/opt/fiscal-mcp/current` 指回上一 release，恢复 `/etc/fiscal/mcp.env` 的备份并重启 `fiscal-mcp.service`；Nginx 配置可沿用旧版。
- NB 的 `FISCAL_IMPORT_CONFIRMATION_SECRET` 变更对应备份位于 `/etc/fiscal/backups/fiscal.env.<timestamp>`；如回退 MCP 新流程，不删除该 secret，避免已部署后端重启失败。
