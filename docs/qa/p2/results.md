# Fiscal P2 QA Results

Date: 2026-07-15 (Asia/Shanghai)

## Outcome

P2 account/category master data is implemented on the API, iOS 26, and macOS 26. The iOS shell now has one navigation source: the native `TabView` was removed, and an authenticated XCUITest asserts that the system tab-bar count is zero before navigating through More. P3 transaction/posting persistence was not introduced.

## Backend gates

The final read-only gate used a disposable local PostgreSQL database and removed it afterward. The seeded visual-acceptance database was preserved until screenshots completed.

- `uv lock --check`: pass (41 packages resolved)
- `uv sync --frozen --offline`: pass (40 packages checked)
- `ruff format --check .`: pass (44 files already formatted)
- `ruff check .`: pass
- `pyright`: pass (0 errors, 0 warnings)
- default `pytest`: 29 passed, 4 PostgreSQL tests skipped by design
- real PostgreSQL integration: 4 passed
- empty-database Alembic upgrade P1 → P2: pass
- second upgrade at head: no-op/pass
- `alembic check`: no new upgrade operations
- offline migration SQL generation: pass

The only warning is the known non-failing Starlette `TestClient`/httpx deprecation warning.

## Apple gates

Toolchain: Xcode 26.6, Swift 6.3.3, Swift 6 language mode, iOS/macOS deployment target 26.0.

- generated project with `xcodegen generate`: pass
- generic iOS Simulator build: pass
- macOS Swift Testing suite: 9 tests passed in 2 suites
- authenticated iOS real-API UI suite: 2 tests passed
  - zero native `TabBar` elements
  - More → Accounts reads `招行储蓄卡`
  - More → Categories reads `餐饮` and child `咖啡`
- macOS launch against the same API: Accounts and Categories both rendered the same seeded records
- Release builds without an injected endpoint use the reserved `https://fiscal.invalid` offline target instead of crashing during app initialization

The final UI review also tightened the full-row hit target, compacted the iOS 26 category toolbar, removed iOS-only bottom padding/background from macOS master-data lists, blocked locally invalid hierarchy edits, and kept merge/split sheets open when mutations fail.

## Real integration smoke

The shared API/database was exercised with three account types and a two-level category tree. Verified behaviors include integer-minor-unit validation, device-token rejection, optimistic stale-write conflict, category split, root merge with duplicate-child handling, archive/restore/order/safe-delete rules, and structured request logging without token disclosure.

PostgreSQL 17 container validation remains externally blocked: Docker Desktop is running, but Docker Hub layer downloads stall through the host proxy chain. The complete migration and integration suite passed on local PostgreSQL 14.22; this is a transparent fallback, not a claim that the PG17 container ran.

## Visual evidence

- `screenshots/ios-overview-single-nav.png`
- `screenshots/ios-accounts.png`
- `screenshots/ios-categories.png`
- `screenshots/macos-accounts.png`
- `screenshots/macos-categories.png`

The next action is user visual acceptance. P3 must not begin until that confirmation.
