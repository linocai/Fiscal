# Fiscal P10 QA Results

Date: 2026-07-16

Status: engineering complete; awaiting user visual acceptance. P11 has not started.

## Delivered

- Server-backed uncategorized inbox, advanced ledger filters, filter-bound cursors, and atomic versioned batch classification.
- Filtered UTF-8 CSV export using canonical values, exact CNY minor units, formula escaping, and a 10,000-row safety limit.
- A coalescing in-memory GET cache with a maximum 30-second TTL, mutation invalidation, real cache status, and no offline mutation queue.
- Device-local default account/type and stay-after-save preferences that affect new manual entries without contaminating edits.
- One iOS custom bottom bar, chart-free list hierarchy, modern card-based editors, complete More/Settings, and adaptive accessibility-size rows/navigation.
- A dense macOS transaction Table + Inspector with advanced filters, multi-selection, atomic batch classification, and keyboard shortcuts.
- Semantic light/dark surfaces across shared screens; no forced light appearance or legacy default `Form` remains.

## Automated verification

- Ruff format/check: passed.
- Pyright: 0 errors.
- Empty-database Alembic upgrade and schema drift check: passed against real PostgreSQL.
- Full backend suite: 174 passed, with 1 upstream Starlette/httpx deprecation warning.
- Generic iOS 26 simulator build: passed.
- macOS 26 Swift test/build: 64 tests across 10 suites passed.
- Snapshot tool build and authenticated PostgreSQL-backed macOS rendering: passed.
- Authenticated iOS 26.5 UI flows passed for the modern editor, Settings/cache/real CSV boundary, and uncategorized advanced-filter/batch entry.
- Dark appearance plus accessibility-extra-large iOS ledger regression: 1 passed, 0 failed; the single bottom safe area and readable adaptive rows were visually checked.

The PostgreSQL verification used the available local PostgreSQL 14.22 runtime; the application contract remains PostgreSQL 17 and migration SQL contains no version-specific fallback.

## Visual evidence

### iOS

- `screenshots/ios-p10-modern-transaction-editor.png`
- `screenshots/ios-p10-settings-data-boundaries.png`
- `screenshots/ios-p10-advanced-filters.png`
- `screenshots/ios-p10-batch-classification-entry.png`
- `screenshots/ios-p10-dark-large-text-transactions.png`

### macOS

- `screenshots/macos-p10-transactions-workbench.png`
- `screenshots/macos-p10-transactions-compact.png`
- `screenshots/macos-p10-transactions-dark.png`
- `screenshots/macos-p10-settings.png`
- `screenshots/macos-p10-settings-dark.png`

The evidence uses production views connected to an authenticated local PostgreSQL-backed API. During real-API QA, uncategorized creation exposed an overly strict service guard; the guard was corrected and a create-then-list PostgreSQL API regression now protects that path.

## Remaining acceptance gates

- [ ] User visually accepts P10 before P11 begins.
- [ ] P9 Siri, Back Tap, Photos/latest-screenshot authorization, notifications, and notification Undo are verified on a physical iPhone before release.
