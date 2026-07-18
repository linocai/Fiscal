# Fiscal P17 / v1.2.1 QA Results

Date: 2026-07-18

Status: implementation and local verification complete; production migration, account rule conversion, package installation, and final smoke pending.

## Delivered

- Credit ledger transactions remain the single accounting truth; credit cash flow is a read-only projection of each cycle's live remaining balance and due date.
- Removed credit-cycle edit/completion actions in both Apple clients and rejected credit projection overrides in the API. Manual cash flow and reimbursement overrides remain editable.
- Added `statement_day_cutoff` and `previous_calendar_month`; existing accounts migrate to the old cutoff rule without name-based changes.
- Added preview/apply schedule conversion that rebases only unsettled cycles, purchases, repayments, installment periods, and plan starts in one transaction. Settled history is preserved and locked installments reject the operation.
- Added atomic installment purchase preview/create with one idempotency key and rollback on either purchase or plan failure.
- Added credit-purchase installment controls to “记一笔”, defaulting to three periods and zero fee, with server-generated statement/due-date preview.
- Added cash-flow request-generation protection and cross-model refresh after ledger/installment mutations.
- Added “查看账期” and “去还款” to credit projections. The detail separates original installment purchases, current-period allocations, ordinary transactions, and repayments.
- Added account UI for selecting the cycle mode and confirming the server schedule-change preview.
- Updated both Apple targets to `1.2.1 (Build 11)`.

## Verification completed

- Ruff format/check: passed.
- Strict Pyright: passed.
- Backend default suite: 136 passed, 98 skipped.
- P17 pure contracts: 4 passed.
- Disposable PostgreSQL P17 domain tests: 2 passed.
- Disposable PostgreSQL P17 migration test: 1 passed.
- Existing P4/P5/P13 plus P17 PostgreSQL regression group: 33 passed.
- macOS Swift suite: 81 tests passed (78 existing + 3 P17 contracts).
- iOS and macOS Debug application builds: passed.
- iOS signed Release: version 1.2.1, build 11, strict signature verification passed.
- macOS Developer ID Release: version 1.2.1, build 11, strict signature verification passed.

## Pending release evidence

- Production verified backup and isolated shadow migration rehearsal.
- Production deploy to Alembic `20260718_0015` and public/local health checks.
- Exact-ID preview and conversion of 花呗/白条 to `previous_calendar_month`.
- Post-deploy credit-cycle/cash-flow reconciliation, including reappearing legacy completed overrides.
- Replace `/Applications/Fiscal.app`, install the signed app on the physical iPhone, launch both, then commit/push tag `v1.2.1`.
