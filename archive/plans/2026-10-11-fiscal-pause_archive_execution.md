# Fiscal 暂停归档与云端收口记录

日期：2026-10-11（Asia/Shanghai）

## 目标

原生 Fiscal App 进入冻结状态，保留完整工程、Build 51 发布物、Git 历史和恢复说明；线上继续运行远程 MCP 所需的最小链路。数据库和数据库备份保持原位。

## 本地归档

归档目录：`/Users/linotsai/文稿/Claude/Fiscal-archive/2026-10-11-pause/`（原记录写作 `~/文稿/Codex/2026-10-11-fiscal-archive/`，实际生成于 `~/Downloads/`，2026-10-12 迁至现址并复核 SHA256）

- `packages/Fiscal-source-worktree.zip`：源码、文档、运维模板和当前工作树快照；排除虚拟环境、依赖缓存、`node_modules`、生成的 `dist` 和历史 `build` 目录。
- `packages/Fiscal-release-artifacts-build51.zip`：冻结的原生 App Build 51 发布物、dSYM、校验值和验证元数据。
- `packages/Fiscal-cloud-retired-releases.zip`：HZ/NB 清理前下载的发布树、脱敏 systemd/Nginx 配置和清理前后清单；不含虚拟环境、`.env`、密钥、TLS 私钥或数据库文件。
- `packages/Fiscal-main-history.bundle`：完整 Git 历史离线包。
- `MANIFEST.md`、`SHA256SUMS`、`SECRET-INVENTORY.md`：归档边界、校验值和秘密材料处理规则。

所有 ZIP 均通过 `unzip -t` 校验；发布树 tar 包已单独通过 `tar -tzf` 校验。

## 云端收口

### HZ

保留：

- `fiscal-mcp.service` 和当前 MCP release。
- 当前 Web 静态 release 中的 `/agent/`、批准页和 discovery JSON。它们仍是 MCP TOTP 流程的用户批准入口，不能删除后再宣称 MCP 可用。
- 现有 Nginx、TLS 和其他与 Fiscal 无关的服务。

已清理：旧 MCP release 和旧 Web release 目录。没有停机、重启或修改现役 MCP 环境文件。

### NB

保留：

- 当前 `fiscal-api.service` release。
- PostgreSQL、`/var/lib/fiscal`、`/var/lib/fiscal/backups` 和 `/var/lib/fiscal/operations`。

已清理：旧 Backend release 目录。没有执行迁移、重启、数据写入或数据库目录操作。

## 验证

- MCP `/health`：HTTP 200。
- 未认证 MCP `ping`：HTTP 401，符合鉴权边界。
- Agent 说明页：HTTP 200。
- discovery JSON：HTTP 200。
- Backend live health：HTTP 200。
- HZ `fiscal-mcp.service`、Nginx：active。
- NB `fiscal-api.service`、PostgreSQL：active。
- 清理后现役 release 只剩 HZ MCP、Web TOTP 支撑页和 NB 当前 Backend。

## 未纳入普通归档的材料

真实账单、PostgreSQL dump、数据库密码、Backend/MCP 环境文件、TOTP secret、break-glass key、TLS 私钥、日志和运行时虚拟环境均未下载、未写入 Git，也未删除。

工作区原有未提交的 `AGENTS.md` 与 scheme 改动保持不变；本次只提交归档说明、项目暂停状态和 README 运行模型说明。
