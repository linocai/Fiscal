# Fiscal P17 / v1.2.1 QA Results

Date: 2026-07-18

Status: released to production; signed v1.2.1 packages installed on macOS and two physical iPhones. macOS and physical-iPhone launch smoke passed.

## Delivered

- Credit ledger transactions remain the single accounting truth; credit cash flow is a read-only projection of each cycle's live remaining balance and due date.
- Removed credit-cycle edit/completion actions in both Apple clients and rejected credit projection overrides in the API. Manual cash flow and reimbursement overrides remain editable.
- Added `statement_day_cutoff` and `previous_calendar_month`; existing accounts migrate to the old cutoff rule without name-based changes.
- Added preview/apply schedule conversion that rebases only unsettled cycles, purchases, repayments, installment periods, and plan starts in one transaction. Settled history is preserved and locked installments reject the operation.
- Added atomic installment purchase preview/create with one idempotency key and rollback on either purchase or plan failure.
- Added credit-purchase installment controls to “记一笔”, defaulting to three periods and zero fee, with server-generated statement/due-date preview.
- Added cash-flow request-generation protection and cross-model refresh after ledger/installment mutations.
- Added “查看账期” and “去还款” to credit projections. The detail separates original installment purchases, current-period allocations, ordinary transactions, and repayments.
- Credit cash flow is grouped by credit account and due date while retaining each underlying cycle as a separately inspectable and repayable part.
- Added account UI for selecting the cycle mode and confirming the server schedule-change preview.
- Updated both Apple targets to `1.2.1 (Build 11)`.

## Verification completed

- Ruff format/check: passed.
- Strict Pyright: passed.
- Backend default suite: 136 passed, 99 skipped.
- P17 pure contracts: 4 passed.
- Disposable PostgreSQL P17 domain tests: 3 passed.
- Disposable PostgreSQL P17 migration test: 1 passed.
- Existing P4/P5/P13 plus P17 PostgreSQL regression group: 34 passed.
- macOS Swift suite: 82 tests passed (78 existing + 4 P17 contracts).
- iOS and macOS Debug application builds: passed.
- iOS signed Release: version 1.2.1, build 11, strict signature verification passed.
- macOS Developer ID Release: version 1.2.1, build 11, strict signature verification passed.

## Production and installation evidence

- Verified production backups completed before migration and deployment. The isolated shadow database restored the production backup at `20260717_0014`, upgraded to `20260718_0015`, preserved all 119 effective ledger transactions, removed all 8 legacy credit-cycle overrides, and was then dropped.
- Production deployed revisions `f9ccb93` and `edbc0c9`; public liveness, local readiness, migration head, and authenticated API smoke checks passed.
- Exact account-ID previews were conflict-free, then 花呗 `373104fd-db95-4ed9-879e-98d8d67df487` and 白条 `1a8b1b8e-8274-4318-9ffe-4bd790c84766` were atomically changed to `previous_calendar_month`. Other credit accounts retained the cutoff mode.
- Production reconciliation reports 119 effective transactions, zero credit-cycle overrides, 8 grouped credit cash-flow rows, and projected credit debt/cash flow both equal to 2,395,640 minor units. 工商3576 due 2026-08-12 is one 194,472-minor-unit row containing two underlying cycle parts.
- `/Applications/Fiscal.app` was replaced with signed `1.2.1 (11)`, with the previous build retained at `/Applications/Fiscal-build10-backup.app`. The app launched against production and visual smoke showed credit due ¥23,956.40, matching the API projection.
- The same signed iOS `1.2.1 (11)` app installed successfully on both paired physical devices, Caeieo and Kurisu. Kurisu launched successfully for physical-device smoke; Caeieo remained installed but locked.
