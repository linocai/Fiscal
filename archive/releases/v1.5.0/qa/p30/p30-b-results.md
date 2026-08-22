# v1.5.0 · P30-B QA 结果

日期：2026-08-14（Asia/Shanghai）
状态：独立 Review Verified（初审 2×P2 已修复；二审 0 findings）；P30-B 收口完成。

## 交付与契约决定

- `TransactionResponse.available_actions` 为可扩展的服务端 capability。当前覆盖高风险 `void`：正常流水可用；已作废、报销分摊/回款、system/分期关联均返回稳定 `reason_code` 与可显示 message，客户端不复制领域限制。
- 版本冲突继续使用统一 `{code,message,request_id,details}`，`resource_version_conflict.details` 固定包含 reason、当前/请求版本和 `safe_to_reload`；账户与交易还返回不含敏感字段的资源类型、ID 和安全重取路径。
- 账户/分类排序新增独立 order-state read（items + 64 位 opaque `list_revision`）。排序请求带 `expected_list_revision`；缺失或不一致均拒绝，返回稳定 reload 信息，因此旧客户端不会静默 last-write-wins。
- 新增 checkpoint ID read、migration-run ID read。migration read 仅暴露 mode/status/source system/code revision/时间/deep link，明确不暴露 manifest、scope 或 source fingerprint。
- Attention 返回 `available_actions`；账单导入 ignore 明确 disabled，未知 source type 也安全降级且 ignore route 拒绝。确认 receipt 新增逐行 resolution/outcome/transaction ID 和 created/matched/skipped counts；确认失败仍是原子错误，不伪造 partial receipt。历史 receipt 标为 `legacy_unavailable`，避免虚构旧行明细。

## 初审修复

| Finding | 修复 | 回归证据 |
| --- | --- | --- |
| P2：已被报销分摊的交易在 update、detail、overview/recent 与 void route 的 capability 不一致 | `TransactionService` 以批量 reimbursement/installment relation lookup 构建列表与 overview 响应，避免 N+1；detail/update 继续从真实关系生成 capability；各 receipt snapshot 和分期生成流水显式传递已知关联状态。 | P6 API：对已分摊 expense 作同 kind、足额 update 后，update/detail/overview 均返回 `reimbursement_claim_in_use` disabled，void 仍以同一 reason 409 拒绝。 |
| P2：分类排序冲突未提供可实际重取的 root/child scope | 缺失/stale list revision 都返回结构化 `order_scope`（`direction`、`parent_id`）和以 `urlencode` 生成的安全 `reload_path`。 | P30-B API：root 与 child 的 stale/missing-token 两种冲突均实际按返回路径 GET，均成功取得对应 order-state。 |

## 独立 Review

- 初审发现 2×P2，均已完成修复并以 fresh PostgreSQL 定向与全量回归复验。
- 第二轮独立 Review：**0 findings**，P30-B 契约门通过。

## 验证

| 命令 | 结果 |
| --- | --- |
| `uv run ruff check src …`、`uv run ruff format --check src …` | 通过 |
| `uv run pyright src` | 0 errors, 0 warnings |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30b_20260814 uv run pytest`（P2/P21/P22/P27/P28/P30-B 定向） | 20 passed；FastAPI/TestClient 上游弃用警告 1 条 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30b_full_20260814 uv run pytest -q` | 277 passed；同一上游弃用警告 1 条 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p30b_full_20260814 uv run alembic downgrade -1 && upgrade head && current` | 成功回退/重升 P29；head `20260813_0029` |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30b_r2_20260814 uv run pytest tests/test_p6_api_postgres.py tests/test_p6_postgres.py tests/test_p7_api_postgres.py tests/test_p21_api_postgres.py tests/test_p27_statement_import_review_postgres.py tests/test_p28_statement_import_workbench_postgres.py tests/test_p30b_api_postgres.py tests/test_p30b_postgres.py -q` | 24 passed；同一上游弃用警告 1 条 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p30b_r2_20260814 uv run pytest -q` | 278 passed，54.21s；同一上游弃用警告 1 条 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p30b_r2_20260814 uv run alembic downgrade -1 && upgrade head && current` | 成功回退/重升 P29；head `20260813_0029` |

测试使用两套新建专用 PostgreSQL 数据库；未使用项目或生产数据库。

## 覆盖的不变式

- 旧 list revision 的账户/分类排序返回 `list_revision_conflict`，而非覆盖后写入；缺 list revision 也拒绝。
- conflict details 只返回版本、稳定原因与可重取资源定位，不返回账户余额、备注、账单或 manifest 内容。
- checkpoint deep link 通过 ID read 闭环；migration-run read 的 privacy-safe response 不含内部 manifest/scope。
- 未作废交易的 void capability enabled；作废后 capability 以 `transaction_already_voided` disabled。账单导入 Attention 的 ignore capability disabled，未知 source action 被拒绝。
- statement-import create_new 和 intentional-ignore 分别验证 applied/skipped 行结果、计数、transaction ID 与持久 receipt replay；原子失败行为维持既有 P27 测试覆盖。

## 残余风险与下一步

- `list_revision` 是基于完整 orderable collection 的 SHA-256 opaque token；它由现有对象版本和顺序派生，不新增数据库列。未来若把排序拆成服务端分页或跨方言 cache，应保持“全列表快照 + 提交时锁内重算”的语义。
- `available_actions` 当前只冻结 P30-B 所需的 transaction void 与 Attention ignore；其他领域动作仍以现有稳定写入错误为准，后续 feature 不能自行推断 capability。
- 当前批量 relation lookup 仅服务于响应 capability；需要完整 relation detail 的单资源路径仍保持其既有精确读取，后续新增列表 capability 需复用同类批量事实加载。
- 下一步可进入 P30-C；上述三项均为非阻断风险，后续扩展相关契约时须保持既有语义。
