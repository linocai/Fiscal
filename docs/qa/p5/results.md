# Fiscal P5 QA Results

Date: 2026-07-15 (Asia/Shanghai)

## Outcome

P5 implementation and engineering verification are complete. The phase is waiting for user visual/product acceptance; P6 has not started.

The contractual accounting rule is preserved throughout: account debt and cycle paid/remaining are exact, while installment plan/account/month projections are explicitly `scheduled_gross` values. A generic partial repayment is never invented as a plan- or component-attributed payment.

## Backend gates

- `uv run ruff check .`: passed.
- `uv run pyright`: passed with zero errors.
- Default test suite: 50 passed.
- PostgreSQL 17 full suite: 95 passed, with one upstream Starlette `TestClient` deprecation warning.
- Fresh P1 → P5 migration, empty P5 → P4 → P5 roundtrip, data-bearing downgrade protection, schema drift, and offline SQL are covered.
- Direct-SQL invariants, deterministic fen allocation, locked-prefix editing, fee/refund/system-repayment ledger shapes, optimistic concurrency, rollback, and idempotent replay are covered.
- Plan creation/list/detail/edit, eligibility/options/liabilities, settlement/reversal/cancellation preview and mutation routes are covered against real PostgreSQL.
- Pagination is stable by `(created_at, id)` and filtering occurs in the database.

## Apple gates

- Verified with Xcode 26.6, Swift 6.3.3, iOS 26, and macOS 26 deployment targets.
- macOS shared/test target: 30 passed.
- iOS simulator build: passed.
- macOS build: passed.
- Authenticated real-API iOS P5 UI test: 1 passed in 26.615 seconds.
- Production iOS navigation contains zero native `TabView` tab bars and exactly one custom bottom bar.
- Exact DTO decoding, preview request snapshots, account switching, archived read-only state, mutation refresh, edit pickers, conflicts, retries, and error presentation are covered.

## Real integration smoke

A disposable PostgreSQL 17 database and authenticated API were used with this scenario:

- Debit account: 招行储蓄卡, ¥25,000.
- Credit account: 招行信用卡, ¥50,000 limit.
- Expense category: 数码配件.
- Credit purchase: ¥3,299.
- Installment plan: 6 periods plus ¥100 fee, scheduled gross ¥3,399.
- Deterministic allocations: ¥566.51, ¥566.51, ¥566.50, ¥566.50, ¥566.49, ¥566.49.

The iOS UI navigated through 更多 → 信用账期与分期 → 招行信用卡, loaded the plan and detail from the live API, opened the editor, submitted the exact preview request, received HTTP 200, and displayed 确认保存. This run exposed an options-query duplicate-plan regression; the backend was corrected so cycle options may inspect an existing plan while creation and eligibility still reject duplicates. The final review then extended that correction to locked history: an existing plan may load options after its natural cycle closes or receives repayment, while past statement dates are returned as ineligible. PostgreSQL and HTTP regressions cover locked-suffix editing and settlement preview in that state.

Integration coverage also verifies locked-suffix editing, shared-cycle generic partial repayment without false component attribution, early settlement and reversal, future cancellation refunds, terminal aggregation, idempotent replay, and archived history.

The disposable API, database container, simulator data, and test Keychain token were removed after evidence capture.

## Visual evidence

- `screenshots/ios-installment-summary.png` — real-API iOS plan summary and single custom navigation bar.
- `screenshots/ios-installment-detail.png` — detail, progress, next period, and scheduled-gross wording without the former top safe-area artifact.
- `screenshots/ios-installment-edit-preview.png` — server-driven edit preview and confirmation state.
- `screenshots/mac-installments.png` — 940×700 point macOS account cards, installment inspector, period list, and future scheduled debt.

The evidence was reviewed against `design_handoff_fiscal_app`: future installment values are presented as contractual scheduled amounts, not exact repayment balances, and no projected installment is inserted into cash-flow totals.
