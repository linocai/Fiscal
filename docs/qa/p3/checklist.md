# P3 QA Checklist

## Contract and scope

- [x] P3 contract frozen before implementation.
- [x] Scope limited to manual income, expense, and transfer; P4+ concepts excluded.
- [x] iOS/macOS 26 minimum and latest stable Swift toolchain retained.

## Backend

- [x] Transaction, posting, revision models and migration implemented.
- [x] Deferred PostgreSQL posting-shape constraint verified.
- [x] Create/get/list/filter/cursor/update/void/restore routes authenticated.
- [x] Idempotency replay and conflicting reuse verified, including concurrency.
- [x] Balances remain correct after create, complete edit, void, and restore.
- [x] Date-range/category summaries exclude transfers and voided transactions.
- [x] P2 usage counts, safe delete, used-kind/direction freeze, and category merge reassignment verified.
- [x] Ruff, Pyright, default tests, real PostgreSQL tests, Alembic checks, and offline SQL pass.

## Apple shared layer

- [x] Integer-money DTOs, actor repository, observable list/editor models implemented.
- [x] Cancellation, stale-response, idempotency retry, conflict, unauthorized, and offline states verified.
- [x] No live transaction screen uses preview fixtures.

## iOS

- [x] Center FAB opens the real P3 record sheet.
- [x] Expense, income, and transfer create/edit flows use the real API.
- [x] Search, filters, Shanghai-day grouping, empty/no-result/error states work.
- [x] Void confirmation and real server restore/Undo work.
- [x] Zero native tab bars and exactly one custom bottom bar remain.

## macOS

- [x] Selectable dense table, filters/search, and 256pt Inspector work.
- [x] Inspector exposes edit and void while postings remain read-only.
- [x] Create/edit/void/restore use the real API.
- [x] 940×700 layout has no clipping or horizontal overflow.

## Evidence and acceptance

- [x] Real API integration run recorded in `results.md`.
- [ ] iOS edit and error/conflict screenshots captured (list and record are captured).
- [ ] macOS editor screenshot captured (table and Inspector are captured).
- [ ] User accepts P3 daily recording and editing feel before P4 begins.
