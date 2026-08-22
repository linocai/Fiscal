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

The UI suite verifies zero native tab bars, exactly one custom bottom bar, real seeded transaction data, and the real expense/income/transfer record sheet. It also performs a real void/restore cycle and asserts both the top search field and the dynamic Undo bar remain geometrically outside the custom bottom bar. Shared-model tests cover cancellation, stale-response suppression, pagination, request construction, idempotency-key reuse, conflict, authorization, and offline presentation.

## Real integration smoke

The API was exercised with cash/debit accounts, income/expense categories, and all three P3 transaction types. A transaction was completely edited from ¥45.80 to ¥52.00, while replaying its original idempotency key returned the immutable original v1 response. The same transaction was voided and restored without duplicate impacts. Derived account balances, P2 usage counts, and the date/category summary were then verified against the postings. Additional real-database tests prove that create, update, void, restore, and opening-balance updates are rolled back before commit when a derived signed-64-bit field would overflow, leaving the previous ledger readable.

## Visual evidence

- `screenshots/ios-transactions.png`
- `screenshots/ios-record.png`
- `screenshots/macos-transactions.png`
- `screenshots/macos-inspector.png`

After the first visual review was rejected, the iOS transaction search was pinned to the top navigation drawer: iOS 26 had automatically placed `.searchable` as a bottom toolbar beneath Fiscal's custom bar. The root shell now uses a single overlaid `glassEffect` capsule on a full-screen background, and UI automation asserts the search field is geometrically above that capsule.

The macOS transaction screen was rebuilt from the high-fidelity reference instead of using the default `Table`, `Picker`, rounded text field, and system gray buttons. It now has reference-style filter chips, semantic columns, 26-point icon rows, an accent selection state, a modern primary record action, and a full-height white 256-point Inspector with structured details and primary/secondary actions. The four screenshots above were replaced after this correction. The remaining gate is renewed user acceptance; P4 does not begin before that confirmation.
