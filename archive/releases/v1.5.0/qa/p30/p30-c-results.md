# v1.5.0 · P30-C QA 结果

日期：2026-08-14（Asia/Shanghai）
状态：Independent Review Verified（第四轮终审 0 findings）；P30-C 已收口，下一步为 P31。

## 交付与契约决定

- 新增 `GET /reimbursement-expense-candidates`：以 `{items, next_cursor}` 返回稳定 keyset page；默认 30、上限 100，支持 `query`、`date_from`、`date_to`，opaque cursor 绑定同一组过滤条件。覆盖 active `expense`/`credit_purchase`，保留 `category_id: null` 的合格垫付；每项包含 `eligibility`、稳定 reason code/message/path 与可精确复算的 amount/capacity。已满容量项也保留为 disabled candidate，避免客户端猜测不可用原因。
- 旧 `GET /reimbursement-expense-options` 保持已分类、可用项的既有语义；新增字段仅追加。这样 v1.4 DTO 的非空 `category_id` 不会因 P30-C 引入的 null 解码失败，F3/V15 应切换到新的 candidates 契约。
- `GET /transactions/{id}/reimbursement-eligibility` 保留 `reasons: string[]`，追加结构化 `reason_details`（code/message/field_path）；`not_eligible_expense` 与 `fully_allocated` 均可显示且稳定。
- 新建/替换草稿的形状错误继续使用既有 FastAPI/Pydantic `validation_error` envelope 和 `loc`；`expected_date` 只接受 `YYYY-MM-DD` 本地业务日，不接受 timestamp。唯一来源交易、非资格来源及容量不足使用既有业务 error envelope，追加 `reason`、`field_path`、source ID 与可用金额，不要求客户端复制规则。
- 新增 `GET /reimbursement-receipt-account-options`，只返回 active `cash`/`debit` 目的账户。成功空态是 `{items: []}`；仓储读取故障保持统一 `internal_error`，绝不伪装成空列表，因此客户端可对同一路径重试。receipt create/replace 的现有账户类型、归档、preview/commit、版本、幂等与金额不变式未改变。

## 初审修复

| Finding | 修复与证据 |
| --- | --- |
| P2：candidates 无分页且服务层逐项读取 transaction、capacity、allocation，响应规模与 SQL 随候选数线性增长。 | repository 按 `occurred_at DESC, id DESC` 只读取 `limit + 1` 条，并预加载 postings；service 对当前页一次批量读取 capacity 与 effective allocation。每页固定四条 SQL（候选、postings、capacity、allocation），无逐项查询。契约测试覆盖多页顺序、cursor+filter 绑定、Shanghai 日期边界、未分类、满容量 disabled、limit 边界，并以 statement listener 比较 limit=1/4，证明页内 SQL 数不随 N 线性增长。 |

Cursor 是 keyset，不承诺跨请求的长事务快照：新插入到当前 key 之前的记录不会污染已读取页；读取间被作废的记录会自然消失，创建时仍由服务端容量锁与 `reimbursement_expense_overallocated` 作为最终真相。F3 新客户端必须消费 page envelope，并以完全相同的 filters 续页；旧 options 继续仅服务 v1.4 兼容。

## 二审修复

| Finding | 修复与证据 |
| --- | --- |
| P2：candidate cursor 的 base64 长度不合法时，`binascii.Error` 未被捕获，公开 route 会返回 500。 | `_decode_candidate_cursor` 将 `binascii.Error` 与既有 base64/UTF-8/JSON/type/date/UUID 边界一起收敛为 `invalid_reimbursement_candidate_cursor` 的 422 envelope。路由回归覆盖 `x`、`abcde`、非 UTF-8、合法 base64 非 JSON、篡改 filters，以及原有 filter mismatch；所有分支均不再泄漏 500。 |

## 三审修复

| Finding | 修复与证据 |
| --- | --- |
| P2：合法 JSON cursor 的 `id` 为 int/list/dict/bool 时，`UUID(...)` 会抛 `AttributeError`，公开 route 仍可能返回 500。 | 解码后显式校验 payload 为 object、`v` 为非 bool 的受支持 int、`filters`/`occurred_at`/`id` 都是 string 且字段齐全；仅将预期的 base64、UTF-8、JSON、日期/UUID 解析错误收敛为稳定 422。参数化路由回归覆盖 id 四种错误类型、无效 UUID、occurred_at 类型/格式、filters 类型、v bool/string/不支持版本、缺字段、list/null payload；另注入 `RuntimeError` 证明真实内部错误仍上抛而非被吞。 |

## 独立 Review 收口

- 初审：1×P2（无限 candidates body 与 1+3N SQL）已通过 cursor page、页级批量事实和 query-count 回归修复。
- 二审：1×P2（base64 解码 `binascii.Error` 泄漏 500）已收敛为稳定 422。
- 三审：1×P2（合法 JSON 的错误字段类型导致 UUID `AttributeError` 泄漏 500）已通过显式 payload schema 校验修复。
- 第四轮终审：**0 findings**；P30-C Independent Review Verified。

## 覆盖的不变式

- 未分类但其他条件成立的垫付可建报销 claim；已分配满的同一来源仍从 candidates 返回，带 `fully_allocated` 禁用原因。
- 标题、主体、至少一主体/一笔垫付、正 minor amount、严格日期格式均有 Pydantic field path；重复来源交易返回 `reimbursement_duplicate_transaction`；超容量返回 `reimbursement_expense_overallocated` 和 amount field path。
- active cash/debit 账户可作为到账候选；credit/archived 账户不会出现。服务故障返回 500 envelope 而非 200 空数组。
- P6 的容量、receipt、preview/commit、Archive/revision、时区和 migration head 行为维持原有覆盖。

## 验证

| 命令 | 结果 |
| --- | --- |
| `uv run ruff check src …`、`uv run ruff format --check src …` | 通过 |
| `uv run pyright src` | 0 errors, 0 warnings |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30c_20260814 uv run pytest tests/test_p6_api_postgres.py tests/test_p6_postgres.py tests/test_p6_migration_postgres.py tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py tests/test_p30c_api_postgres.py -q` | 22 passed；FastAPI/TestClient 上游弃用警告 1 条 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30c_20260814 uv run pytest -q` | 280 passed，48.79s；同一上游弃用警告 1 条 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p30c_20260814 uv run alembic downgrade -1 && upgrade head && current` | 成功回退/重升 P29；head `20260813_0029` |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30c_r2_20260814 uv run pytest tests/test_p5_postgres.py tests/test_p6_api_postgres.py tests/test_p6_postgres.py tests/test_p6_migration_postgres.py tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py tests/test_p30c_api_postgres.py -q` | 39 passed，12.27s；同一上游弃用警告 1 条 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30c_r2_20260814 uv run pytest -q` | 281 passed，50.08s；同一上游弃用警告 1 条 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p30c_r2_20260814 uv run alembic downgrade -1 && upgrade head && current` | 成功；head `20260813_0029` |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30c_r3_20260814 uv run pytest tests/test_p5_postgres.py tests/test_p6_api_postgres.py tests/test_p6_postgres.py tests/test_p6_migration_postgres.py tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py tests/test_p30c_api_postgres.py -q` | 39 passed，14.89s；同一上游弃用警告 1 条 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30c_r4_20260814 uv run pytest tests/test_p5_postgres.py tests/test_p6_api_postgres.py tests/test_p6_postgres.py tests/test_p6_migration_postgres.py tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py tests/test_p30c_api_postgres.py -q` | 54 passed，16.54s；同一上游弃用警告 1 条 |

测试使用新建专用 PostgreSQL 数据库；未使用项目或生产数据库。P30-C 无 schema migration。

## 残余风险与下一步

- candidates 的 keyset cursor 防止同一排序/过滤序列内重复或 offset 跳项，但不提供跨请求的长事务快照；其他设备可在 create 前占用容量，服务端 mutation lock 和 `reimbursement_expense_overallocated` 是最终真相，前端须按 field path 重新读/决定。
- P30-C 未修改 Apple：F3 必须消费 candidates page、不得复用不同 filters 的 token，并为目的账户读取错误提供 retry/加载态，不能沿用现有 `try?` 静默链路。
- 旧 options 仍排除未分类来源以保护 v1.4 解码兼容；P5 merchant principal-refund 容量不变式继续依赖既有 P5 回归，本门未改变其领域流程。
- 下一步为 P31；P32–P34 与任何 V15 View 仍受后续前置门限制。
