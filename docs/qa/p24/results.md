# P24-A · 导入与隐私基础（后端垂直切片）

状态：**Automated Verified**（后端 P24-A）；未部署，未进行真实 PDF、Provider 或设备验收。

## 实现边界

- Alembic head：`20260812_0024`。新增 `statement_imports`、page、row、attempt、resolution 与仅元数据的 operation log；原 PDF bytes 没有持久化字段。
- `POST /api/v1/statement-imports` 仅登记 SHA-256/大小/页数/MIME/显示名；同 SHA-256 返回原批次而不创建第二批。start/fail/retry/abandon 只记录状态和 attempt，不解析 PDF、不调用 Provider、也不创建 transaction/posting。
- 所有这些写入只发出 `statement_imports` revision scope；不携带 ledger、accounts、reports 等 scope。
- Archive 包含导入实体及关系。`latest_attempt_id` 是可选恢复循环外键，设为 `DEFERRABLE INITIALLY DEFERRED`，并在 Archive 预检关系后于同一恢复事务中验证。
- operation log 与应用日志仅记录 import/attempt UUID、attempt 序号、状态与稳定 error code；不接受任意客户端错误文本，也不写显示名、证据或 PDF 内容。

## 自动验证（2026-08-12）

- Fresh PostgreSQL 14.22：`head → 20260811_0023 → head` 通过；验证新表存在且 `transactions/postings = 0`。
- P24 lifecycle、SHA duplicate、revision scope、零账本写入、Archive export/open/dry-run/恢复和日志脱敏：`pytest -q tests/test_p22_revision_route_matrix.py tests/test_p24_statement_import_postgres.py` → **4 passed**（仅上游 TestClient deprecation warning）。所有临时数据库已删除。
- `ruff check src tests alembic` 与 `pyright src/fiscal_api` 均通过。
- 测试以合成显示名执行日志扫描断言；捕获的 stdout 和 operation-log JSON 均不含该值。实现、迁移与本 QA 文件不含该合成值。

## 已知验证边界

- 以同一个隔离 PostgreSQL 环境执行的全量后端回归在既有 `tests/test_p10_api_postgres.py::test_p10_filter_bulk_and_csv_api` 停于 `account_not_found`；该失败发生于 P10 创建账户后写 transaction，涉及文件不在 P24-A diff 内。P24 定向门全部通过，未为该 Plan 外回归修改领域账本。
- P24-A 仍不代表 P24 phase 结束：P25 需实现本地 PDFKit/Vision 提取、临时文件清理与授权前预览；真实 PDF、Provider、生产和设备验收均未执行。
