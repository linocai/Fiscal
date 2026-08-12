# P27 · Statement review and confirmation

状态：**Automated Verified**（P27-A/P27-B）；仅合成 PostgreSQL fixture，未部署、未连接网络或真实账单。

- P27 新增 immutable validation run/check、review candidate 与 versioned draft-resolution 表；输入限定 P26 `validated_result` snapshot/source refs。batch 始终为 `review_required`，不会写 transaction、posting 或 balance adjustment。
- `match_existing` 仅可链接本 validation run、同 source row 所产生的既有交易候选；同日同额只是候选，绝不自动选择。五种草稿语义均是 versioned draft；同语义 replay 不增加 batch revision，陈旧 batch/resolution version 拒绝。
- Archive 自动纳入 run/check/candidate/draft 及其既有 snapshot/source row foreign-key links；全新空 PostgreSQL target 的真实 restore 已逐表验证 run/check/candidate/draft、snapshot/source-ref、draft/row 关系及 batch/draft version 一致，ledger/posting 仍为 0。导出内容不含 PDF/image/provider 原文。
- `uv run ruff check ...` 与 `uv run pyright ...` → **passed / 0 errors**；fresh PostgreSQL `head → 20260812_0026 → head` migration 成功。
- `FISCAL_TEST_DATABASE_URL=... uv run pytest -q tests/test_p27_statement_import_review_postgres.py` → **1 passed**，覆盖 run replay、passed/unavailable checks、五种 draft、optimistic conflict、Archive fresh-target restore 与 zero ledger/posting。
- P27-B 以 `20260812_0028` 新增 versioned final-create draft、confirm operation receipt 及 row→transaction provenance。正式写入只能经 confirm、已保存 final draft 与既有内部 `TransactionService` adapter；没有 public source 入口、Provider、PDF/image 或余额调整路径。
- Confirm 对 batch/row/draft/final-draft version 逐项预检并在同一事务中写入；同 UUID key+payload 返回 receipt replay，异 payload 冲突。create_new 保持既有 posting 语义；match_existing 只写 provenance、不改既有交易；两个 ignore 皆为零 transaction/posting。成功子集为 `partially_confirmed`，后续失败不回滚前一 chunk，confirmed row 拒绝再编辑。
- Archive 自动纳入 final draft、operation receipt 和 provenance。真实 fresh-empty target restore 后以相同 Idempotency-Key replay，posting/provenance 均维持 1（无重复）。
- Migration downgrade 在任何 `statement_import` transaction 或 provenance 存在时以明确 guard 拒绝；干净库 `head → 0027 → head` 已验证，降级后旧 source CHECK 与 P13-compatible trigger 不含 `statement_import`。
- `FISCAL_TEST_DATABASE_URL=... uv run pytest -q tests/test_p27_statement_import_review_postgres.py` → **7 passed**，覆盖 create/match/两种 ignore、idempotency replay/conflict、多行 preflight rollback、分批/freeze、Archive fresh restore/replay、P27-A review 与 system-only kind trigger 拒绝。
- `uv run ruff check ...` 与 `uv run pyright ...` → **passed / 0 errors**（P27-B files）。
- 隔离 fresh PostgreSQL schema（`DROP/CREATE public` 后迁移至 head）全套 JUnit → **266 tests, 0 failures, 0 errors, 0 skipped**。
- Apple macOS test → **110 tests / 20 suites passed**；macOS 与 iOS Simulator Debug build 均 **BUILD SUCCEEDED**，均使用隔离 DerivedData。

未完成：P27-C/P28 的用户编辑 UI、批量操作体验及其它计划外领域功能；本实现没有外部 Provider、生产调用或真实账单资料。
