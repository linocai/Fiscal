# Fiscal P3 QA Results

Date: 2026-07-15 (Asia/Shanghai)

## Outcome

P3 manual income, expense, and transfer accounting is implemented across the authenticated API, iOS 26, and macOS 26. Transactions generate immutable-position account impacts on the server, support complete replacement, soft void/restore, and derive account balances and summaries from the ledger. P4 credit behavior remains deliberately excluded.

## Backend gates

- `uv lock --check` and frozen offline sync: pass
- Ruff format/check: pass (52 files formatted)
- Pyright: pass (0 errors, 0 warnings)
- default `pytest`: 42 passed, 14 PostgreSQL tests skipped by design
- real PostgreSQL integration: 56 passed, including 14 P2/P3 database tests
- empty-database P1 → P2 → P3 migration, second upgrade, schema drift check, and offline SQL generation: pass

The real integration suite used local PostgreSQL 14.22 because Docker Hub image downloads for the PostgreSQL 17 container still stall through the host proxy chain. No PostgreSQL 17 result is claimed.

## Apple gates

Toolchain: Xcode 26.6, Swift 6.3.3, Swift 6 language mode with complete concurrency checking, iOS/macOS deployment target 26.0.

- `xcodegen generate`: pass
- generic iOS Simulator build: pass
- macOS Swift Testing suite: 16 tests passed
- authenticated iOS real-API XCUITest suite: 3 tests passed
- source audit: zero `TabView`/`.tabItem` references in the live iOS shell

The UI suite verifies zero native tab bars, exactly one custom bottom bar, real seeded transaction data, and the real expense/income/transfer record sheet. Shared-model tests cover cancellation, stale-response suppression, pagination, request construction, idempotency-key reuse, conflict, authorization, and offline presentation.

## Real integration smoke

The API was exercised with cash/debit accounts, income/expense categories, and all three P3 transaction types. A transaction was completely edited from ¥45.80 to ¥52.00, while replaying its original idempotency key returned the immutable original v1 response. The same transaction was voided and restored without duplicate impacts. Derived account balances, P2 usage counts, and the date/category summary were then verified against the postings. Additional real-database tests prove that create, update, void, restore, and opening-balance updates are rolled back before commit when a derived signed-64-bit field would overflow, leaving the previous ledger readable.

## Visual evidence

- `screenshots/ios-transactions.png`
- `screenshots/ios-record.png`
- `screenshots/macos-transactions.png`
- `screenshots/macos-inspector.png`

The final macOS pass fixed the root view's intrinsic-height gap and reserved a stable 256-point Inspector so amounts no longer clip at the 940-point acceptance width. The remaining gate is user acceptance of the daily recording and editing feel; P4 does not begin before that confirmation.
