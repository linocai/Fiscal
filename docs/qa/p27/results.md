# P27-A · Read-only statement review

状态：**Automated Verified**（P27-A）；仅合成 PostgreSQL fixture，未部署、未连接网络或真实账单。

- P27 新增 immutable validation run/check、review candidate 与 versioned draft-resolution 表；输入限定 P26 `validated_result` snapshot/source refs。batch 始终为 `review_required`，不会写 transaction、posting 或 balance adjustment。
- `match_existing` 仅可链接本 validation run、同 source row 所产生的既有交易候选；同日同额只是候选，绝不自动选择。五种草稿语义均是 versioned draft；同语义 replay 不增加 batch revision，陈旧 batch/resolution version 拒绝。
- Archive 自动纳入 run/check/candidate/draft 及其既有 snapshot/source row foreign-key links；导出内容不含 PDF/image/provider 原文。
- `uv run ruff check ...` 与 `uv run pyright ...` → **passed / 0 errors**；fresh PostgreSQL `head → 20260812_0026 → head` migration 成功。
- `FISCAL_TEST_DATABASE_URL=... uv run pytest -q tests/test_p27_statement_import_review_postgres.py` → **1 passed**，覆盖 run replay、passed/unavailable checks、五种 draft、optimistic conflict、Archive entity counts 与 zero ledger/posting。
- `FISCAL_TEST_DATABASE_URL=... uv run pytest -q` → **260 passed**（仅既有 TestClient deprecation warning）。
- Apple macOS test → **109 tests / 20 suites passed**；macOS 与 iOS Simulator Debug build 均 **BUILD SUCCEEDED**。一次 iOS 构建因共享 DerivedData build DB lock 失败，改用独立 `/tmp/fiscal-p27-ios-isolated` 后成功，未绕过编译门。

未完成：P27-B confirm、transaction source/provenance 最终化与任何正式账本写入明确不在范围内。
