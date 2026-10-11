# Fiscal Agent-first Backend 0043 生产部署记录

日期：2026-10-11（Asia/Shanghai）  
状态：已完成 NB 生产部署、迁移、重启与 Web 只读验证；真实账单批次仍待用户验收。

## 目标与边界

- 为已经上线的 Web Console 和 HZ MCP gateway 提供 `import_batches` API。
- 只修改 NB 上 Fiscal API 和 Fiscal 数据库；不修改原生 App、HZ 其他服务或账本既有表。
- 本轮不开放 `commit:imports`，不写入真实账单，不创建测试批次。

## 变更来源

- 本地 Git 提交：`ffaa23a82b2e8f8b51b9fae12580b5fd3c8b719d`。
- Backend 发布快照在 NB 上以部署源提交 `53906818483e0d8e0c023b0bcb522278ed87c2e7` 执行；快照只包含本地提交的 `Backend/` 树。
- 本地门禁：Backend 全量测试 `171 passed / 272 skipped`；新增批次 schema 测试 `2 passed`；Ruff format/check 通过。

## 生产执行

- NB 当前 release：`/opt/fiscal/releases/53906818483e`，`/opt/fiscal/current` 已原子切换到该目录。
- 生产迁移：`20260926_0042 → 20261010_0043`，Alembic transactional DDL 成功。
- 迁移前备份：`/var/lib/fiscal/backups/fiscal-20261011T033805Z.dump`，已验证。
- 迁移后备份：`/var/lib/fiscal/backups/fiscal-20261011T033806Z.dump`，已验证。
- `fiscal-api.service` active/enabled，部署脚本 readiness、备份新鲜度和 public smoke 通过；部署源临时目录及测试缓存已清理。

## 验证结果

- PostgreSQL `alembic_version=20261010_0043`，`public.import_batches` 存在，当前行数为 0。
- `https://fiscal.linotsai.top/api/v1/import-batches`：带用户 access key 返回 200，空集合。
- `https://console.fiscal.linotsai.top/api/v1/import-batches`：经 HZ 同源代理返回 200，空集合。
- Web 账本读取仍为 200，认证状态为 200；首屏不再因批次路由 404 显示“暂时无法读取 Fiscal”。
- 月报历史接口仍可能因既有历史余额基础返回 `historical_balance_unavailable` 409；这是历史数据口径问题，不是本次连接或迁移失败。

## 待用户验收

1. 刷新 Web Console，输入 Fiscal API access key，确认待确认页显示空状态而不是连接错误。
2. 从 Agent 暂存一小批真实账单，网页查看并校验；先使用忽略或只读流程。
3. 完成一周闭环后，再单独决定是否配置 `FISCAL_IMPORT_CONFIRMATION_SECRET` 与开放 `commit:imports`。
