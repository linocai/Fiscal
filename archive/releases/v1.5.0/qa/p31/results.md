# v1.5.0 · P31 QA 结果

日期：2026-08-14（Asia/Shanghai）
状态：**Independent Review Verified**。初审 1×P1、3×P2、1×P3，二审 2×P3，三审 2×P2 均已修复；第四轮独立 Review 为 0 findings。P31 已完成，当前下一步为 P32；不得启动 P33、P34 或任何 V15 View。

## 契约决定

- `Merchant`、`MerchantAlias`、`TransactionMerchantMapping` 是 additive 分析关系：确认、纠正、解除只写映射及其版本/receipt，绝不覆盖 transaction `title`、`note`、source、amount、posting 或余额。别名采用不区分大小写的全局唯一约束，映射只允许 active merchant。
- mapping confirm/correct/release 均要求 UUID `Idempotency-Key`；同 key 且同 payload 重放同一 receipt，不同 payload 返回 `idempotency_key_reused`。纠正/解除使用 mapping `expected_mapping_version`，并提供安全 reload path。
- `GET /transactions/{id}/revisions` 复用既有 `TransactionRevision`，按 version DESC keyset 分页；`GET /transactions/{id}/provenance` 只暴露稳定 source/target/deep-link，包含 statement-import、cash-flow、merchant mapping 的可读链接，不暴露账单或 Provider 原文。
- 新增 category `merge-preview`/`merge-commit`、`split-preview`/`split-commit`。preview 存持久 token 与输入/版本/依赖快照；commit 再锁定、重验版本与完整 child/transaction mapping，任一不匹配即失败且不写入。成功重分类递增每笔 transaction version，并追加到同一 `TransactionRevision` 链；commit receipt 可幂等重放。旧 P2 merge/split 保留 v1.4 兼容，新客户端必须只使用 P31 preview/commit。
- Archive 由 `Base.metadata` 自动纳入 P31 六张 additive 表；既有 v1 Archive 的 relationship preflight、空目标 restore、data revision 与 financial fingerprints 保持同一机制。

## 覆盖的不变式

- 商户确认、纠正、解除不改变账本证据或金额；Archive 解密 payload 含 merchant 与 mapping 行且外键关系可验证。
- revision 读取是既有单一历史来源；category P31 重分类写入同一链，不伪造第二份审计记录。
- merge 要逐一映射 active source children；split 要逐一映射 preview 时的全部历史交易。preview 后任一 category version、child 集合或 transaction 集合变化都会使 commit 失败；commit 是单一数据库事务。
- P31 不改变 account/category P30-B list revision 契约；所有 P31 mutation 走正式 data-revision scope。

## 验证

| 命令 | 结果 |
| --- | --- |
| `uv run ruff check src tests/test_p31_api_postgres.py`、`uv run ruff format --check src tests/test_p31_api_postgres.py` | 通过 |
| `uv run pyright src` | 0 errors, 0 warnings |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p31_20260814 uv run pytest tests/test_p2_postgres.py tests/test_p3_postgres.py tests/test_p4_migration_postgres.py tests/test_p5_migration_postgres.py tests/test_p6_migration_postgres.py tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py tests/test_p30c_api_postgres.py tests/test_p31_api_postgres.py -q` | 49 passed，12.50s；上游 TestClient 弃用警告 1 条 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p31_20260814 uv run pytest -q` | 299 passed，60.70s；同一上游弃用警告 1 条 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p31_20260814 uv run alembic downgrade -1 && upgrade head && current` | 成功；head `20260814_0030` |
| migration 后 `pytest tests/test_p31_api_postgres.py tests/test_p22_archive_revision_postgres.py -q` | 13 passed，9.16s；同一上游弃用警告 1 条 |

测试使用新建专用 PostgreSQL 数据库；未使用项目或生产数据库。

## 历史审查记录

## 初审修复（P1×1，P2×3，P3×1）

- Merchant canonical name 与 alias 已改为同一 `merchant_identifiers` 表的 `NFKC + casefold` 唯一命名空间；归档不释放标识，rename/alias replace 先删除同 merchant 旧项后 flush，再原子写入新集合。GET `/merchants` 现为 capped、filter-bound opaque keyset page，并批量读取 aliases。
- Category preview 现为 30 分钟 ephemeral operational state：不走 formal data-revision scope，`category_transform_previews` 与其 receipt 表不进入 Archive/fingerprint/restore。payload 绑定 data revision、category version/parent/archive 与 transaction id/version/category/void/kind/date/postings 指纹；commit 全局锁后重查 receipt、严格重验并只移动 snapshot IDs。
- merchant confirm/correct/release 和 category commit 都在 mutation lock 后重查 idempotency operation；operation unique race rollback 后按 key/hash 重读 receipt，避免 500。
- `20260814_0030` 已安全修订为 identifier schema，并新增 preview expiry 列；fresh PostgreSQL `downgrade 20260813_0029 && upgrade head` 通过。`pytest test_p31_api_postgres.py test_p22_archive_revision_postgres.py -q` 为 14 passed；Ruff/format、Pyright 均通过。

## 二审前补充验证

- 新建 disposable PostgreSQL `fiscal_p31_verify`：最新工作树 Ruff、format、Pyright 全绿；fresh head 上 `uv run pytest -q` 全量通过（301 collected；唯一警告为上游 TestClient deprecation）。
- `alembic downgrade -1 -> upgrade head -> current` 通过，head 为 `20260814_0030`；随后 `test_p31_api_postgres.py + test_p22_archive_revision_postgres.py + test_p22_revision_route_matrix.py` 为 **16 passed**。该组合覆盖 empty-target restore/relationship preflight/financial fingerprint 的既有 P22 gate。
- 初审 finding 对应定向证据：P31 preview 回归验证 facts revision 不变、Archive payload 不含 preview、preview 后新增分类交易导致 `category_preview_stale` 且原交易仍指向 source（零写）；merchant test 验证 NFKC 全角名称与 alias 的跨命名空间冲突、filter-bound keyset cursor；既有 P31 mapping test 验证同 key receipt replay。操作在全局 mutation lock 后重查 operation 的双 session unique-race 防护由实现路径与 full PostgreSQL suite 共同覆盖。

## 二审修复

- preview payload 仍记录 data revision 供诊断，但不再把任何无关 formal mutation 视为 stale；现在严格比较 captured category/transaction/posting 指纹，以及每个 transaction scope 的完整当前 ID 集合。因此无关 merchant mutation 后可以 commit，而新增/删除/修改相关 transaction 仍稳定 `category_preview_stale` 且零写。
- P22 route matrix 现递归展开 FastAPI `_IncludedRouter` 的真实 APIRoute，要求至少 40 条路由并断言全部明确 operational POST（包括 P31 两个 preview）无 formal scopes，其余 formal write 必须有 scope；消除了原先 `app.routes` 只含 wrapper 导致的空跑。
- Merchant page 的 PostgreSQL 回归以 SQLAlchemy `before_cursor_execute` 比较 `limit=1` 与 `limit=4`，语句数恒定且不超过 3，并断言 aliases 和多项 page 返回正确；证明 aliases 以批量查询而非 N+1 读取。

## 二审验证闭环

- 新增 `tests/test_p31_concurrency_archive_postgres.py`：两个真实 `AsyncSession` 先被 barrier 推进至相同 key 的 **pre-lock 空 operation 读取**，再竞争同一 global advisory lock。merchant confirm（创建映射）、correct（versioned mutation）、release，以及 category merge commit 都断言锁后至少发生两次 operation 重查；同 payload 返回同一 receipt、业务写入只出现一次、不同 payload 稳定 `idempotency_key_reused`，没有 `IntegrityError`/500 路径。
- 同文件以两个独立 fresh PostgreSQL 数据库验证 Archive：源库迁移 head 后创建真实 merchant canonical identifier、alias、transaction mapping（纠正至 version 2）和 merchant operation receipts，并完成一次 category merge 的正式最终重分类；导出/加密后仅按 `ArchiveService.restore_empty_target` 导入另一个 head 空库。逐行比较 identifier ID/FK/normalized key、mapping ID/FK/version、receipt ID/key/hash/body、data revision，以及账户余额和 transaction category/version 指纹；`category_transform_previews` 与其 operation 均不在 payload 或目标库。
- 本轮临时数据库均由本地 `postgres` 创建，名称为 `fiscal_p31_verify_20260814_2101`、`fiscal_p31_targeted_20260814_2115`、`fiscal_p31_full_20260814_2125`、`fiscal_p31_full_capture_20260814_2130`；每个只用于迁移/测试，已全部删除并确认不存在。Archive 测试内部 source/target 库也在 test `finally` 中删除。

| 命令 | 结果 |
| --- | --- |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p31_verify_20260814_2101 uv run pytest tests/test_p31_concurrency_archive_postgres.py -q` | 3 passed，1.99s；唯一警告为上游 TestClient deprecation。 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p31_targeted_20260814_2115 uv run pytest tests/test_p31_api_postgres.py tests/test_p31_concurrency_archive_postgres.py tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py -q` | 21 passed，10.82s；在 migration 往返后复跑仍 21 passed。 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p31_targeted_20260814_2115 uv run alembic downgrade -1 && upgrade head && current` | 通过；`20260814_0030 (head)`。 |
| `uv run ruff check src tests`、`uv run ruff format --check src tests`、`uv run pyright src` | 全通过；193 files formatted，0 errors / 0 warnings / 0 informations。 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p31_full_capture_20260814_2130 uv run pytest -q` | 306 passed，58.77s；唯一警告为上游 TestClient deprecation。 |

## 三审修复与验证

- merge preview 现在显式捕获 source root 与 target root 的完整 active child ID 集合；split preview 捕获 root 的完整 active child ID 集合。commit 在 global mutation lock 后重读这些集合，任何新增、删除、archive/unarchive 或已捕获 child 缺失都会统一 `category_preview_stale`，且在进入 mapping/创建 child/重分类前退出。因此不能将 source child 映射到 preview 后新增的 target child。
- 商户 canonical name 与每个 alias 在 `NFKC + casefold` 后、写入 `merchant_identifiers.normalized_key VARCHAR(240)` 前统一校验：必须可 UTF-8 编码且不超过 240 个字符。create 与 update（含保留旧 aliases 的 rename）共用该路径；错误为稳定 422 `merchant_identifier_invalid` / `merchant_identifier_too_long`，含字段定位。数据库约束仍为最终防线。
- `test_p31_api_postgres.py` 覆盖 merge target child add/delete/archive/unarchive、source child delete/archive，以及 split child add/delete/archive；每例断言 409 `category_preview_stale`、commit 前后 transaction revision / transform operation / data revision 三项数据库计数不变且原交易 category/version 不变。另覆盖 U+FDFA 归一后 234 字符边界、252 字符超限 name/alias/update、普通 NFKC Unicode 与无效 UTF-8 service 输入，确保不走 `DataError`/500。

| 命令 | 结果 |
| --- | --- |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p31_third_final_targeted_20260814_2235 uv run pytest tests/test_p31_api_postgres.py tests/test_p31_concurrency_archive_postgres.py tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py -q` | 32 passed，11.43s；migration 往返后复跑仍 32 passed（10.58s）。 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p31_third_final_targeted_20260814_2235 uv run alembic downgrade -1 && upgrade head && current` | 通过；`20260814_0030 (head)`。 |
| `uv run ruff check src tests`、`uv run ruff format --check src tests`、`uv run pyright src` | 全通过；193 files formatted，0 errors / 0 warnings / 0 informations。 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p31_third_final_full_20260814_2240 uv run pytest -q` | 317 passed，61.30s；唯一警告为上游 TestClient deprecation。 |

- 三审本地临时库仅用于迁移/测试：最终门禁为 `fiscal_p31_third_final_targeted_20260814_2235` 和 `fiscal_p31_third_final_full_20260814_2240`；此前迭代库也一并删除。收口后全部确认不存在。

## 第四轮独立 Review 与残余风险

- 第四轮独立 Review 结果为 **0 findings，Verified**。四轮记录：初审 1×P1、3×P2、1×P3；二审 2×P3；三审 2×P2；第四轮 0 findings。前述发现均已在对应轮次修复并经 fresh PostgreSQL 门禁验证。
- P31 只建立 merchant read/model dimensions；商户维度聚合、同比环比和报告下钻属于 P34，P32/P33 不得自行补算。
- P31 保留旧 P2 merge/split 以保护 v1.4 客户端；F4/V15 只能接 P31 preview/commit，不能把旧直接命令伪装为带 preview 的流程。
- merchant mapping 是明确用户确认关系，未加入自动 LLM/规则写入；未来建议能力必须另行保证首次确认与来源披露。
- P31 已通过 Independent Review；当前下一步为 P32。P33–P34 和任何 V15 View 继续受前置门限制。
