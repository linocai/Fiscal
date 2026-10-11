# Fiscal Agent-first 阶段三工程收尾记录

日期：2026-10-10（Asia/Shanghai）  
状态：工程资产完成；未部署、未接触生产数据，等待用户执行环境与真实账单验收。

## 本阶段目标

把阶段二的本地实现收成可交接的工程包：运维可以知道哪些环境变量必须存在，
Agent 主机可以先做不泄露密钥的配置检查，静态 Web 可以在不改源码的情况下选择
HTTP/MCP 后端，同时明确 migration、回滚、CORS、密钥和真实账单验证仍由用户执行。

## 已完成

- `Backend/ops/compose.staging.yml` 将 `FISCAL_TOKEN_PEPPER` 和
  `FISCAL_IMPORT_CONFIRMATION_SECRET` 显式注入 API；staging、production、local
  示例均写明 secret 用途和 fail-closed 行为。
- 新增 `MCP/ops/fiscal-mcp.env.example`、`MCP/scripts/preflight.py` 与操作说明。
  preflight 只检查 URL、`/api/v1` 根路径、批次路径、scope、mock 策略和确认 secret
  形状，不发网络请求、不打印任何 secret，也不冒充 token/DNS/migration 验收。
- Web 新增 `runtimeConfig.ts` 与 `public/runtime-config.js` / example。默认仍是 mock；
  静态宿主覆盖 runtime config 后可选择 HTTP 或 MCP，页面可提示输入短期 key，且不会
  使用 URL、localStorage、cookie 或 Vite `VITE_*` 变量保存密钥。
- 运维文档补充 Agent-first 交接顺序：后端 0043 migration 与 readiness、静态 Web、
  MCP stdio 进程、`commit:imports` 的显式开启条件和 0043 不做 live downgrade 的回滚边界。
- `PROJECT_PLAN.md` 状态更新为阶段三工程收尾完成，未改变版本号、原生 App 源码或生产数据。

## 工程验证

- `PYTHONPATH=MCP/src Backend/.venv/bin/python -m unittest discover -s MCP/tests -v`：14 passed。
- `Backend/.venv/bin/ruff check MCP/scripts/preflight.py MCP/tests/test_preflight.py`：通过。
- `npm ci --no-audit --no-fund && npm run build`（`Web/`）：通过，生成静态 `dist/`。
- `git diff --check`：通过。
- 使用一次性临时 env 文件运行 preflight：通过；临时文件已删除。

## 用户验收清单

以下项目本阶段没有代用户执行，也不由本地构建结果推断通过：

1. 为 staging/production 生成真实且独立的 token pepper、数据库密码和 import confirmation secret，确认安装文件权限。
2. 按现有生产流程执行 0043 migration 前后备份、readiness、public smoke、回滚可行性和备份恢复核验。
3. 为 Web 静态宿主配置 HTTPS、CORS、`runtime-config.js`，确认页面不含密钥且浏览器会话可读取报告/账本。
4. 为 Agent 主机配置 MCP backend token、Agent key 与 scope，运行 `MCP/scripts/preflight.py`，确认 stdio Agent 能完成读取和暂存。
5. 用真实一周账单完成“创建 → 校验 → 网页确认/忽略 → 月报/账本/CSV 对齐”的闭环；重复请求、错误版本、撤销 key 和 `commit:imports` 才能在此后决定是否开放。

## 未执行与边界

- 未运行生产命令、未迁移或写入生产数据库、未启动公网 MCP HTTP 服务、未替换原生 App。
- MCP 当前仍是 Agent host 管理的 stdio 进程；公开 HTTP MCP transport、持久化多用户 key 管理和
  AIProposal 关联不属于本阶段收尾。
- `public/runtime-config.js` 中的默认 mock 配置是可提交的安全基线；部署环境应在静态宿主上覆盖，
  覆盖文件和 MCP env 文件均不得回写仓库。
