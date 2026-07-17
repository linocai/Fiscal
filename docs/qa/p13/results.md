# Fiscal P13 QA Results

Date: 2026-07-17

Status: engineering, production migration, data recovery, and Build 7 installation complete; iPhone launch acceptance awaits an unlocked device.

## Delivered

- Restored the product boundary: cash flow represents future items awaiting settlement, while the ledger contains only events that actually occurred.
- Added manual inflow, outflow, and transfer items with expected, confirmed, settled, and cancelled states; only confirmed items can settle.
- Added single and monthly plans, required monthly end dates, occurrence/this-and-future edits, optimistic version checks, idempotency keys, and transactional settlement.
- Settlement preserves expected values, accepts actual amount/date/account/category, and creates exactly one formal ledger transaction.
- Credit cycles and reimbursement receipts remain authoritative system sources; installment liabilities are not duplicated.
- Added transaction void/restore synchronization, AI proposal target separation, active/history APIs, and month filtering only in history.
- Replaced both Apple cash-flow screens with the future-item workflow, restored account future-cash-flow sections, and labeled overview values as future 30-day cash flow.

## Automated verification

- Ruff check and format: passed.
- Strict Pyright: passed.
- Backend suite without database integration: 132 passed, 93 skipped.
- P13 and P8 PostgreSQL integration: 14 passed.
- Alembic fresh upgrade through `20260717_0013`, downgrade to `0012`, and re-upgrade: passed.
- Signed macOS and iOS Release builds: passed; both report version 1.1.0, build 7, and pass strict code-signature verification.

## Production and recovery verification

- Created and verified pre-migration backups of both Fiscal and LinoFinance databases.
- Restored a production snapshot to an isolated shadow database, then completed dry-run, first apply, idempotent second apply, and reconciliation.
- Production recovery selected exactly 7 manual items: 6 monthly salary occurrences in one series and 1 one-off September rent item.
- Recovered total: 3,630,000 minor units. Exactly 17 legacy credit-repayment plans were excluded.
- Running the recovery twice still produced 7 items. Formal ledger transaction count remained 117 before and after recovery.
- Authenticated production API smoke returned 16 active items: 7 restored manual items and 9 live system items.
- Production 30-day summary for 2026-07-17 through 2026-08-15 returned inflow 500,000, outflow 1,807,186, and net -1,307,186 minor units.
- The disposable shadow database and temporary deployment source trees were removed after reconciliation; all three verified pre/deploy backups remain intact.

## Apple package acceptance

- macOS Build 7 is installed at `/Applications/Fiscal.app`, launches successfully, and displays all pending items with overdue-first ordering, future 30-day totals, a separate history action, and no month selector on the main cash-flow page.
- The previous macOS Build 6 remains recoverable at `/Applications/Fiscal-build6-backup.app`.
- iOS Build 7 is installed on the physical iPhone as `com.linotsai.fiscal`.
- The iPhone rejected only the remote launch request because the device was locked; installation and signing succeeded. Final interactive iPhone acceptance remains a user/device-unlock gate.
