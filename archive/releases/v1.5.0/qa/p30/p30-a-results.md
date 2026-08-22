# v1.5.0 · P30-A QA 结果

日期：2026-08-14（Asia/Shanghai）
状态：三轮独立 Review 已完成，终审 0 findings；P30-A Verified。

## 交付

- 新增只读 `GET /api/v1/reports/facts`，窗口为 1–90 天，响应包含固定时区/币种、`data_revision`、窗口、现金、信用债务、报销待回款、完整性、统一未来事件与可复算聚合。
- `KnownFutureEvent` 只投影信用账期、已提交报销主体和未结算的人工现金流；内部转账不进入总现金扣减。信用事件以单一 `credit_cycle` 为来源，避免与遗留 cash-flow 系统投影重复。
- `after_confirmed_outflow_minor = cash - exact_due - confirmed_outflow`；预计/计划支出及预计回款不进入该公式。
- 读取前后采样 `DataRevision`；若读取期间正式数据变更，回滚读事务、清空 identity map 后重读一次，以稳定错误拒绝混合快照。
- 生产端点只以服务端 `Asia/Shanghai` 业务日确定窗口；`facts_today` 仅为服务层受控测试时钟，不是 API query。
- 完整性将未终态导入与失败导入分开计数；对账差异直接按最新 checkpoint 的客观账面差额计算，不受 Attention 忽略态影响。

## 验证

| 命令 | 结果 |
| --- | --- |
| `uv run ruff check src/fiscal_api/db/session.py src/fiscal_api/repositories/reconciliation.py src/fiscal_api/services/reconciliation.py src/fiscal_api/services/reporting.py tests/test_p7_postgres.py tests/test_p7_api_postgres.py tests/test_p7_schemas.py tests/test_p21_api_postgres.py tests/test_p21_schemas.py tests/test_p22_archive_revision_postgres.py` | 通过 |
| `uv run ruff format --check`（同上文件） | 通过 |
| `uv run pyright src` | 0 errors, 0 warnings |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30a_20260814 uv run pytest tests/test_p7_postgres.py tests/test_p7_api_postgres.py tests/test_p7_schemas.py tests/test_p21_api_postgres.py tests/test_p21_schemas.py tests/test_p22_archive_revision_postgres.py::test_p22_revision_receipts_are_formal_once_and_concurrent -q` | 18 passed；FastAPI/TestClient 上游弃用警告 1 条 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p30a_20260814 uv run alembic downgrade -1 && uv run alembic upgrade head && uv run alembic current` | 成功回退 P29、重新升级；head 为 `20260813_0029` |

数据库测试使用全新、专用的 `fiscal_p30a_20260814`，未使用任何既有测试库或项目数据库。

## 覆盖的关键不变式

- 单一信用账期只生成一个 `credit_cycle` 事件，且其金额等于 `exact_due_outflow_minor`。
- 合成夹具验证现金 24,300、信用债务 1,500、报销待回款 600，及 confirmed/expected/scheduled 三类人工未来事项和预计报销共同可复算。
- API smoke 验证 `facts` 路由、响应窗口、现金余额、空事件和已提交的 `data_revision`。
- 读者第一轮已加载初始余额为 100 的账户；第二个正式 API request 以 mutation scope PATCH 同一账户至 400 并递增 revision。第一个 `facts` 读到 revision 变化后必须重新加载，最终现金为 400、revision 为 1，证明不会将旧 identity-map facts 配新 revision。
- failed 与 review-required 导入分别计入 `failed_import_count`、`unresolved_import_count`；已忽略但仍 open 的 checkpoint 在 `facts` 中仍计为差异。

## 初审修复

| Finding | 修复与证据 |
| --- | --- |
| P1：重试可能复用旧 ORM identity map | mismatch 后 `rollback()` + `expire_all()`，再开始新的读事务；双 session PostgreSQL 并发写入回归通过。 |
| P2：客户端可传 `today` | 从 route signature/OpenAPI 删除；schema 回归断言 `/reports/facts` 仅暴露 `window_days`。 |
| P2：失败导入遗漏 | 增加明确的 `failed_import_count`，未终态与失败分离；PostgreSQL fixture 覆盖。 |
| P2：对账事实受 Attention ignore 影响 | 增加不读取 dismissal 的 checkpoint 差异计数；API 回归先忽略 Attention 再验证 facts 仍为 1。 |

## 二审修复

| Finding | 修复与证据 |
| --- | --- |
| P3：revision 重试未充分证明同一 identity map 的刷新边界 | 并发夹具改为 reader 首轮已加载的既有账户，writer 走正式账户 PATCH；`facts()` 在 revision 后检查和重试前均 `rollback()` + `expire_all()`，确保新的 PostgreSQL 读事务和 ORM 状态。同步 ORM autoflush 曾绕过 AsyncSession `flush()` 的 P22 receipt 标记，已以 `Session.before_flush` 最小修复，故 PATCH 真实递增 `data_revision`；P7 并发回归与 P22 并发 receipt 回归均通过。 |
| P3：客观对账差异仍扫描所有历史 checkpoint | repository 新增 PostgreSQL `DISTINCT ON` 的 `latest_by_target()`，差异只计算每个账户/账期的最新 checkpoint。多历史 checkpoint 夹具验证旧 open + 新 reconciled 不计、新 open 计入；忽略该 Attention 后计数仍为 1。 |

## 三轮独立 Review 结论

| Review | Finding 与处置 |
| --- | --- |
| 初审 | 1×P1、3×P2；均已在“初审修复”中记录、修复并复验。 |
| 二审 | 2×P3；均已在“二审修复”中记录、修复并复验。 |
| 终审 | 0 findings；P30-A 独立 Review Verified。 |

## 风险与下一步

- 该端点是 additive read model；没有新增 migration、action/candidate/UI，也未更改既有写入语义。
- 非阻断风险：`latest_by_target()` 采用 PostgreSQL `DISTINCT ON`，与本项目生产及 fresh-PostgreSQL 测试目标一致；若未来引入其他数据库方言，需为该查询提供等价实现并补方言回归。
- 下一步为 P30-B；P30-C、P31–P34 和任何 V15 View 仍受其前置门限制。
