# Fiscal — 项目施工须知

权威计划见 `PROJECT_PLAN.md`（唯一入口）。历史计划、审查报告、版本契约与验收证据统一进入 `archive/`。

原生 iOS/macOS App 已于 2026-10-12 退役移出仓库：完整源码以不可变 tag `native-app-final` 保留，可用 `git checkout native-app-final -- App` 恢复；Apple 前端施工规则随之退役，见该 tag 下的 `AGENTS.md`。

## 组成与门禁

- 现役链路：`MCP/`（HZ 远程网关）→ HTTPS → `Backend/`（NB，FastAPI/PostgreSQL，唯一账本事实源）。`Web/` 的 `/agent/`、`/agent/approve/` 和 `/.well-known/fiscal-agent.json` 是 MCP TOTP 批准链路的必需页面；React 控制台按用户决定保留。
- MCP 只通过 HTTP 调用 Backend service 路由，不直连数据库、不暴露任意 CRUD/SQL；网页不复制财务规则。
- 后端门禁见 `README.md`；疑似项核实以后端 schema/service 为准（见各 `api/*_schemas.py`、`services/*.py`）。MCP 门禁为 `MCP/tests` 与 `MCP/scripts/preflight.py`。

## 金额 / 记账写入

- 金额输入为元（两位小数）、领域/API 为整数分，禁止把「元」当「分」或反之；报销回款与报销单必须同单位。
- 转账/还款/结算等写入前校验来源与目标账户非空且不同、且账户类型匹配（信用 vs 非信用）；切换交易类型必须清理方向/账户类型不兼容的引用。
- 分期资格、期间锁定和修改校验都按消费与还款/减免的业务时间判断；结清后同账期的新消费不能被旧还款锁住。
- 高危金额/记账改动收口跑针对性后端测试，并手动走一遍真实 posting/回款/还款/入账路径确认写入方向与金额。

## 时区

- 业务日期用 `Asia/Shanghai`；CSV 导出文件名等对用户可见的日期也用东八区，别用默认 UTC。

## 发布

- “一条龙发布”按生产当前 revision 到目标 revision 的**累计差异**决定范围，不能只看最后一个快修提交。先只读核对生产 revision、Alembic head、服务与备份状态。
- 依赖尚未上线的 API 或 migration 时，后端 dry-run、迁移前备份、apply、迁移后备份、readiness/public smoke 与 MCP/Web 部署作为同一发布链记录。
- 既有版本标签不可移动；同营销版本追加构建号时使用独立不可变 build 标签。
- 真实账本/数据库备份、现役 env 文件、TOTP secret 与 TLS 私钥受保护，任何清理都不得触碰。
