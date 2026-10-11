# Fiscal Agent-first 阶段二施工记录

日期：2026-10-10（Asia/Shanghai）  
状态：本地实现与隔离数据库验证完成；未部署生产，未开放可信 Agent 直写。

## 范围

- `Backend/` 新增 `import_batches` 表、0043 Alembic migration、Pydantic contract、repository、service 和受保护路由。
- 批次 API：`POST/GET /api/v1/import-batches`，以及 `/{id}/validate`、`/{id}/commit`、`/{id}/ignore`。
- 创建使用 body 幂等键和请求哈希；校验带 expected version；提交要求 HMAC confirmation credential、expected version 和 commit 幂等键。
- 提交在一个数据库事务内逐条调用既有 `TransactionService.create_ai(..., commit=False)`，所有候选成功后才提交；失败整体回滚。
- 候选在 JSONB 批次 envelope 中保存，验证错误与交易回执留痕；正式账本仍由既有 transactions/postings 表作为事实源。
- `MCP/` HTTP adapter 已能调用真实批次 API，转换后端 UUID `id` 为稳定的 `batch_id`，并保留嵌套错误码与 `Idempotency-Key` header。
- `Web/` 新增 HTTP 与 MCP live adapter，待确认页支持查看、校验、确认提交和忽略；密钥只在构造 adapter 时以内存值传递。

## 重要决定与偏离

- 结构化候选已经由 Agent 提交并通过 Fiscal transaction validation，因此阶段二直接复用 `TransactionService` 原子写入；没有为每行再生成一套 AI provider 解析流程，也没有复制账本表。批次回执保留候选到交易的映射，后续如需 AIProposal 级别的学习证据再单独增加关联迁移。
- `FISCAL_IMPORT_CONFIRMATION_SECRET` 在提交时强制要求至少 32 bytes；未配置时提交返回 `confirmation_unconfigured`，不会让生产服务启动失败，以便先部署只读和暂存能力。
- MCP 列表工具尚未新增；Web/MCP adapter 可显式配置 REST 集合路径。新增 MCP 工具属于后续契约变更，不在本阶段隐式扩大工具列表。

## 验证证据

- `Backend/.venv/bin/ruff check src tests`：通过。
- `uv run --offline pyright`（新增 schema/service/repository/transaction 相关源码）：0 errors。
- 后端契约与安全回归：75 passed；新增批次 schema 测试覆盖指纹、重复 client id 和时区。
- 一次性本地 PostgreSQL `fiscal_phase2_test`：从 base 升级至 `20261010_0043` 成功；真实 service smoke 完成创建 → 校验 → HMAC 提交 → 提交重放，交易只生成一条；测试数据库和临时脚本已删除。
- `MCP` unittest：8/8；MCP ruff：通过。
- `Web` `npm run build`：通过；构建目录与依赖已清理。
- OpenAPI 已暴露 5 个批次路径；`App/` SwiftUI 业务源码未修改。

## 未执行与下一步

- 未运行生产迁移、未替换原生 App、未写入真实账本。
- 部署前需独立复审金额写入和批次回滚路径，配置生产 confirmation secret，执行迁移前后备份、readiness/public smoke，并用真实一周账单完成一次全链路月度闭环。
- 生产阶段仍需决定目标版本号、首个 Agent 运行环境、网页部署边界，以及是否授予可信 Agent `commit:imports`。
