# P24-A/B · 导入基础与脱敏本地证据包（后端垂直切片）

状态：**Automated Verified**（后端 P24-A/B）；未部署，未进行真实 PDF、Provider 或设备验收。

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

## P24-B 实现与自动验证（2026-08-12）

- Alembic head：`20260812_0025`。`POST /api/v1/statement-imports/{id}/evidence` 只接受严格 JSON page/row 包（页型、脱敏文本、归一化坐标）；schema 无 PDF、字节或图像字段。
- 写入以 batch `expected_version` 和 active local-extraction `attempt_id` 同时守卫。成功时同一事务写入既有 `statement_import_pages`/`rows`，attempt 标记 `succeeded`、batch 进入 `review_required`，且只发出 `statement_imports` revision scope。相同 package 重放无重复写入且不增加 revision。
- 服务端确定性拒绝完整账号/卡号和带值姓名、地址、客户号等显式敏感字段；operation log 只保留 UUID、attempt 序号、页/行计数和稳定 error code，不写显示名或正文。Archive 覆盖 pages/rows；断言其字段不含 PDF/image，且零 transaction/posting。
- 本机隔离 PostgreSQL 14.22：`20260812_0025 → 20260812_0024 → head`，再执行 P22+P24 定向测试 → **5 passed**（仅既有 TestClient deprecation warning）；临时数据库已删除。Ruff/Pyright 均通过。

## Reviewer privacy/lifecycle follow-up（2026-08-13）

- Alembic head `20260813_0029` 将已存在的 `statement_imports.display_name` 重写为固定 `statement.pdf`，并加数据库 CHECK；register 忽略客户端传入的名称，因此 API response、DB 与 Archive 均不保留任意原文件名。fresh upgrade 测试先在 `0028` 插入旧名称再升至 head，断言其被清洗；Archive round-trip 也断言固定值。
- iOS/macOS local intake 记住 start response 的 active expected version；本地提取失败或用户取消 `/fail` 使用该值（start 后 v2 的测试断言 fail=v2，服务端进入 `failed`），成功、失败、取消和 scene cleanup 均清理本地 attempt version。
- duplicate 仅由已知状态恢复：`review_required`/`ready_to_confirm`/`partially_confirmed` 直接打开 review；`failed` 仅暴露用户明确重新开始；`extracting`/`parsing` 只显示显式查询。没有自动 start、证据重发或后台恢复。
- 定向 fresh PostgreSQL：`tests/test_p24_statement_import_postgres.py tests/test_p28_statement_import_workbench_postgres.py` → **8 passed**；后端 full JUnit → **270 passed, 0 failures, 0 errors, 0 skipped**。Ruff/Pyright 均为 0 errors。
