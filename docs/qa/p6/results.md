# Fiscal P6 QA Results

Date: 2026-07-15 (Asia/Shanghai)

## Outcome

P6 implementation and engineering verification are complete. The phase is waiting for user visual/product acceptance; P7 has not started.

After the first visual review, the macOS claim editor was rejected for falling back to a bare system form. It has been rebuilt as a Fiscal-native workbench with a structured header, designed field containers, party cards, a compact allocation matrix, a live summary rail, inline validation, and a custom sticky action bar. The replacement screenshot below is from the rebuilt SwiftUI view at its real 940×700-point window size.

The accounting boundary is preserved throughout: the party × expense matrix is the expected reimbursement truth; each actual receipt is a server-owned positive cash/debit ledger transaction; reimbursement receipts affect cash flow but never ordinary income.

## Backend gates

- `uv run ruff check .`: passed.
- `uv run pyright`: passed with zero errors.
- Default test suite: 50 passed.
- PostgreSQL 17 full suite: 104 passed, with one upstream Starlette `TestClient` deprecation warning.
- `alembic check`: no schema drift.
- Fresh P1 → P6 migration, empty downgrade/upgrade roundtrip, data-bearing downgrade protection, deferred cross-table validators, and offline SQL are covered.
- Matrix capacity, principal-refund eligibility, P5 refund interaction, receipt allocation conservation, lifecycle versions, idempotency, concurrency, rollback, pagination, and preview/action parity are covered.
- Two independent backend reviews completed with no remaining P0/P1 blocker.

## Apple gates

- Verified with the current Xcode 26.6 / Swift 6.3.3 toolchain and iOS 26/macOS 26 deployment targets.
- macOS shared/test target: 46 tests passed after the editor correction.
- Authenticated real-API iOS P6 UI test: 1 passed in 30.771 seconds.
- iOS simulator build and macOS build: passed.
- Production iOS navigation contains zero native `TabView` tab bars and exactly one custom bottom bar.
- Exact DTO decoding, stale-response guards, paginated receipts, preview request binding, cancellation binding, conflict refresh, archived/voided read-only states, and locked-allocation lower bounds are covered.
- The receipt editor now has an iOS 26 numeric keyboard completion action; visual evidence is captured only after navigation and keyboard animations settle.
- An independent Apple review completed with no remaining P0/P1 blocker.

## Real integration smoke

A disposable PostgreSQL 17 database and authenticated API were used with this scenario:

- Debit account: 招行储蓄卡, opening balance ¥25,000.
- Reimbursable expenses: 上海往返高铁 ¥600, 差旅酒店 ¥800, 客户晚餐 ¥400.
- Claim: 差旅报销单 · 7月, expected reimbursement ¥1,800.
- Parties: 公司财务 ¥1,500 and 客户项目组 ¥300.
- Interleaved receipts: 公司财务 ¥900 and 客户项目组 ¥100, leaving ¥800 outstanding.
- The iOS UI then submitted an actual ¥200 receipt through server preview and commit; the resulting `reimbursement_receipt` transaction appeared in history and did not increase ordinary-income totals.
- API/PostgreSQL coverage additionally executed claim editing, receipt replacement, soft void, restore, stale versions, cancellation/reopen, and allocation-capacity races.

Before the UI mutation, transaction summary remained ordinary income ¥0, expense ¥1,800, net −¥1,800 while reimbursement summary reported expected ¥1,800, received ¥1,000, and outstanding ¥800.

The disposable API, database container, simulator data, and test Keychain token are removed after evidence capture.

## Visual evidence

- `screenshots/ios-reimbursements.png` — real-API iOS summary, filters, claim card, and the single custom bottom bar.
- `screenshots/ios-reimbursement-detail.png` — localized party states, expected/received/outstanding totals, and party × expense matrix.
- `screenshots/ios-reimbursement-receipt-preview.png` — unobscured server preview before committing the real receipt.
- `screenshots/mac-reimbursements.png` — 940×700 point macOS list, modern matrix detail, receipt history, and cash-flow explanation.
- `screenshots/mac-reimbursement-editor.png` — corrected 940×700-point Fiscal-native editor; the former bare fields and default toolbar are gone.

The evidence was reviewed against `design_handoff_fiscal_app`: expected reimbursement, actual receipts, outstanding amounts, and personal burden remain visually distinct; no second iOS navigation bar or obsolete macOS list styling remains.
