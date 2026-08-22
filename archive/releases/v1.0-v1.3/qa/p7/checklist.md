# Fiscal P7 QA Checklist

Date: 2026-07-15

## Contract

- [x] Spending, actual cash flow, forecast, and debt semantics frozen before code.
- [x] Asia/Shanghai natural-month and future-30-day boundaries frozen.
- [x] No recurring salary/rent prediction and no duplicate installment cash-flow event.
- [x] Production overview fixtures prohibited.
- [x] Overview and every report reuse the same server projection service.
- [x] No schema migration was added; Alembic drift remains clean.

## Backend

- [x] Spending totals, category hierarchy, trends, and drill-down reconcile.
- [x] Merchant refunds and reimbursements re-attribute to original spending date/category.
- [x] Actual cash flow uses cash/debit postings and separates internal transfers.
- [x] Forecast exposes exact due versus expected receipt without creating ledger rows.
- [x] Debt separates current debt, exact cycles, and installment scheduled gross.
- [x] Overview fields exactly equal their report endpoints.
- [x] Cursor, Shanghai boundary, void/restore, uncategorized, and Int64 tests pass.
- [x] Ruff, pyright, 113 PostgreSQL tests, and migration drift pass.

## Apple

- [x] Shared strict DTOs and one remote reporting repository implemented.
- [x] Overview, cash flow, and report models reject stale period responses.
- [x] Production iOS/macOS overview requires live model and never defaults to fixture data.
- [x] iOS preserves exactly one custom bottom bar and root-owned cross-tab navigation.
- [x] iOS cash flow is one dedicated list-only page; Reports contains only spending and debt lists and has no charts or category bars.
- [x] macOS overview, cash-flow, and reports use dense Fiscal-native layouts.
- [x] Spending and cash-flow contribution rows reconcile visibly; debt remains its own exact-cycle lens.
- [x] Initial loading, empty, offline/unauthorized, preserved refresh error, and long content are represented.
- [x] 46 Apple tests, iOS 26 build/UI test, and macOS 26 build/test pass.

## Visual evidence

- [x] iOS live overview.
- [x] iOS list-only future cash flow, spending, and debt; drill-down is covered by the shared implementation, API tests, and macOS render evidence.
- [x] macOS live overview and cash flow at the 940×700 app content baseline.
- [x] macOS spending, cash-flow, debt, and drill-down at the 940×700 app content baseline.
- [x] Every screenshot visibly names the period and reporting lens.
- [ ] User accepts P7 before P8 begins.
