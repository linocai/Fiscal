# v1.5.0 · P32 QA 结果

日期：2026-08-14（Asia/Shanghai）
状态：**Independent Review Verified。** 初审 2×P2、二审 1×P2 + 1×P3 均已修复；第三轮 Independent Review 为 **0 findings**。P32 已完成；P33 可作为下一施工块，P34 与任何 V15 View 仍未获准启动。

## 交付

- `GET /api/v1/reports/facts` 仍是当前首页唯一 read model；未改动遗留 `/reports/overview`，P32 不依赖也不复制它。
- 四个主事实 `cash`、`credit`、`reimbursements`、`completeness` 均追加 schema-versioned scope（`schema_version="1"`、`expected_data_revision`、安全 HTTP read path、app deep link）。客户端不使用分钟级 stale 阈值；离线只需使用 snapshot 的 `meta.as_of`。
- 新增受认证的 `GET /api/v1/reports/facts/drill-down`。请求必须携带 scope 与首页 snapshot 的 revision；读取前后对 revision 收敛，任何变更返回稳定 409 `report_facts_scope_changed`（含 safe reload path），不会混合新旧事实。cursor 为 scope/schema/revision/filter/sort-key 全绑定的 opaque keyset，错误 payload 收敛为 422 `invalid_facts_scope_cursor`。
- 账户下钻只返回昵称、余额、最近核对时间与单账户 read/deep link，不复制 institution 或 `last_four`。信用下钻返回账期、已还、剩余、到期日；报销下钻返回参与方、预计/已收/未收及 claim link；完整性只在实际存在问题时返回 issue count/amount 和处理入口。
- 二审修复后，四个下钻均走各自 repository/service 路径：账户、账期和报销各自使用 SQL keyset `LIMIT limit + 1`，完整性只由独立聚合形成至多四个稳定 issue；不会调用完整 `_facts_snapshot()`、不会读取 known-future events，也不会把全量 ORM 对象取回后切片。
- 守恒由服务端再次检查：资产账户和为当前现金；账期剩余和为当前信用负债；活跃报销主体未收和为待回报销。没有完整性问题时 scope page 是空列表，不生成 Attention。

## 二审发现与修复

- P2：P32 的 PostgreSQL `SUM(bigint)` 会返回可超出 Int64 的 numeric，而 aggregate 出口此前直接转换为 Python `int`。现已对现金、待回报销、未分类金额及相关 P32 page/count 派生值统一通过 `checked_int64`，超界稳定为既有 409 `derived_amount_out_of_range`，不会进入 JSON/Swift 解码。
- P3：cursor 的等值比较会把 Python `True == 1`、`False == 0` 误当作版本/修订号。现在先严格验证 payload 是 object、`v` 和 `revision` 为非 bool 的 `int`（revision 非负），其余 schema/scope/filter/sort/key 都是 string，之后才比较值；非预期 `RuntimeError` 不会被误折叠为 422。

## Independent Review 收口

- 初审：2×P2（下钻读取完整 snapshot、cursor 未严格绑定），已改为独立 repository keyset/aggregate 路径与全绑定 cursor。
- 二审：1×P2（aggregate Int64 溢出）与 1×P3（cursor bool/int 混淆），已通过 `checked_int64` 边界与精确类型检查修复。
- 第三轮：**0 findings，P32 Verified。**

## 验证

| 命令 | 结果 |
| --- | --- |
| `uv run ruff check src tests`、`uv run ruff format --check src tests` | 通过；193 个文件已格式化 |
| `uv run pyright src` | 0 errors，0 warnings |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p32_20260814_build uv run pytest tests/test_p7_schemas.py tests/test_p7_postgres.py tests/test_p7_api_postgres.py tests/test_p30c_api_postgres.py tests/test_p31_api_postgres.py tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py -q` | 62 passed；上游 TestClient 弃用警告 1 条 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p32_20260814_build uv run pytest -q` | 318 passed；上游 TestClient 弃用警告 1 条 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p32_20260814_build uv run alembic downgrade -1 && upgrade head && current`，随后复跑上述 targeted suite | 成功；head `20260814_0030`；62 passed |
| `uv run ruff check src tests`、`uv run ruff format --check src tests`、`uv run pyright src`（二审修复后） | 通过；193 个文件已格式化；Pyright 0 errors，0 warnings |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p32_r3 uv run pytest tests/test_p7_schemas.py tests/test_p7_postgres.py tests/test_p7_api_postgres.py -q`（二审修复后） | 27 passed；上游 TestClient 弃用警告 1 条 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p32_r3 uv run pytest -q`（二审修复后） | 329 passed；上游 TestClient 弃用警告 1 条 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p32_r3 uv run alembic downgrade -1 && upgrade head && current`，随后复跑 P30-B/P30-C/P31/P32 suite（二审修复后） | 成功；head `20260814_0030`；64 passed |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p32_r4 uv run pytest tests/test_p7_schemas.py tests/test_p7_postgres.py tests/test_p7_api_postgres.py -q`（三审修复后） | 53 passed；上游 TestClient 弃用警告 1 条 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p32_r4 uv run pytest -q`（三审修复后） | 355 passed；上游 TestClient 弃用警告 1 条 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p32_r4 uv run alembic downgrade -1 && upgrade head && current`，随后复跑 P30-B/P30-C/P31/P32 suite（三审修复后） | 成功；head `20260814_0030`；90 passed |

测试使用新建的专用本地 PostgreSQL `fiscal_p32_20260814_build`，未使用项目或生产数据库。

## 覆盖的不变式

- 合成账本夹具的现金 `24,300`、信用 `1,500`、待回报销 `600` 分别与四个 scope page 精确复算；cash scope 以 `limit=1` 续页，证明 cursor 不重复/漏项。
- 新建 checkpoint 后，旧 cash scope 必须返回 `report_facts_scope_changed`；错误 revision 与 malformed cursor 分别覆盖稳定 409/422。
- 空完整性 scope 为空；`review_required` 与 `failed` 导入会分别产生守恒的 issue count；不以 Attention ignore 状态改变客观 facts。
- 新增 220 个资产账户的大数据夹具：监听到数据库 keyset 查询带 `LIMIT 26`（请求 `limit=25`），ORM identity-map 在第一页不超过 26 个账户；续页无重无漏，账户余额和精确等于 facts cash。
- 测试会禁止 `_facts_snapshot()` 后读取四个 scope，以防下钻回退为整页快照或读取 known-future。cursor 对 scope/schema/revision/filter/key 的错误类型、错误值与跨 revision 都稳定拒绝，不会变成 500。
- 两个合法 Int64 最大值的现金、报销 allocation、未分类 posting 聚合分别越界时，均验证 `derived_amount_out_of_range`；不以静默截断或无界 JSON 数值代替。cursor 覆盖 `v=true`、`revision=true/false`（分别在 expected 1/0 下）、以及每个 string 字段的 bool/float/list/null；decoder 的 `RuntimeError` 保持透传。
- P30-C 报销候选和 P31 merchant/category/Archive/revision route matrix 的定向回归均通过；本切片无 migration、无写入语义、无 Apple View。

## 残余风险与下一步

- scope page 保持与 `facts` 相同的全局 revision 边界：在用户点击下钻前发生任何正式写入会要求重新读取首页，不承诺跨 revision 拼接旧分页；这是保护金额守恒而非客户端 stale 策略。
- endpoint 为 additive read contract。后续 F2 必须按 scope 的 409 安全刷新、对 404 的历史/已删除对象做通用安全降级，并且只展示服务端金额；不得回退到 `/reports/overview` 客户端拼装。
- P32 不再有待修复审查项；下一步为 P33 Builder。P34 与任何 V15 View 继续受计划前置门约束。
