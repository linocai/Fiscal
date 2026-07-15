# Fiscal P7 Reporting and Cash-Flow Contract

Date: 2026-07-15

This document freezes P7 before implementation. `PROJECT_PLAN.md` remains authoritative. P7 replaces the P1 presentation fixtures with one derived reporting service shared by overview, spending, cash-flow, debt, and drill-down surfaces. It adds no mutable reporting truth and no recurring-bill model.

## Three lenses, one ledger

- **Spending** answers what was consumed and what portion remains personal responsibility. It includes plain expenses, credit purchases, and installment fees once; repayments and transfers never count again.
- **Cash flow** answers what actually entered or left cash/debit accounts. It includes real income, cash/debit expenses, repayment outflow, and active reimbursement receipts; it excludes credit purchases, installment scheduling, credit-only refunds, opening balances, and expected reimbursements.
- **Debt** answers what is currently owed and when exact cycle balances are due. Current credit debt comes only from canonical postings. Future installment scheduled gross is a separate contractual breakdown and is never added to current debt or presented as payment-attributed remaining debt.
- All amounts are checked signed-64-bit integer fen. Currency is CNY. Every response declares `timezone = "Asia/Shanghai"`, its inclusive local date range, and an `as_of` instant or date.
- Reports are pure projections. They store no aggregate rows, cached balances, forecast transactions, or chart series. P7 requires no database migration.

## Shanghai date boundaries

- A natural month is `[first local day 00:00, first local day of next month 00:00)` in `Asia/Shanghai`, converted to UTC for queries.
- Explicit report ranges use inclusive Shanghai business dates and the same half-open UTC conversion.
- Daily and monthly trend buckets are returned continuously, including zero buckets, in ascending order.
- Future 30 days means Shanghai calendar dates `[today, today + 30 days)`. Events due today are included; the thirtieth following date is excluded.
- Default `today`, current month, and `as_of` are server-derived. Tests inject explicit dates; Apple never guesses server boundaries.

## Spending projection

- Gross consumption is the canonical amount of active `expense`, `credit_purchase`, and `installment_fee` transactions attributed to the source transaction's Shanghai business date.
- Active `installment_refund` principal and fee links are contra-expense. They reduce the original purchase or fee category and original business-date bucket, not income, cash flow, or an unrelated refund-month category.
- Reimbursement allocation is anchored to the original reimbursable expense date and category. Live expected allocation reduces `personal_expected_minor`; active received allocation reduces `personal_realized_minor`. The receipt transaction separately contributes cash inflow on its own receipt date and never ordinary income.
- A cancelled claim retains received allocation as the effective expected amount and releases only outstanding allocation, matching P6.
- Spending returns `gross_consumption_minor`, `merchant_refund_minor`, `net_consumption_minor`, `expected_reimbursement_minor`, `received_reimbursement_minor`, `personal_expected_minor`, and `personal_realized_minor`. These fields must reconcile visibly.
- Category rows include stable root and optional child identity, current names/colors/icons, gross, merchant refund, net consumption, expected/received reimbursement, and personal expected/realized amounts. Root totals equal their child plus direct-root rows.
- Missing-category transactions remain in every total and trend. They appear in an explicit `uncategorized` bucket with count/amount; coverage is never improved by silently excluding money.

## Actual cash-flow projection

- Only active postings to `cash` or `debit` accounts qualify. Positive postings are inflow; negative postings are outflow.
- Internal `transfer` is excluded from global inflow, outflow, and net so moving personal money cannot inflate activity. Per-account rows may expose its source outflow and destination inflow only with `internal_transfer = true`; account rows reconcile to global totals through separate external and internal-transfer fields.
- `repayment` and installment settlement contribute only their real cash/debit payment posting as outflow. Credit purchases and installment fees contribute no cash flow until paid.
- Active `reimbursement_receipt` contributes real inflow. It is excluded from ordinary income and spending.
- Opening balances affect account value and debt only; they never appear in period cash flow.
- Cash-flow returns actual inflow, outflow, net, continuous daily trend, account analysis, and drill-down line items with the exact qualifying posting sign.

## Future events

- Forecast events are projections, never ledger transactions. Every event has a stable source ID, `date`, direction, amount, `basis`, and certainty label.
- An exact live credit-cycle `remaining_minor` with a due date inside the window is an `exact_due` outflow. Unresolved credit opening configuration does not create a due event.
- A live submitted reimbursement party with positive outstanding amount and an explicit expected date is an `expected_receipt` inflow labelled “预计”. It does not change actual cash-flow totals and does not create a transaction.
- Future installment period scheduled gross is shown under debt only. It is already represented by its effective credit cycle and must not become a second cash-flow event or assume an autopay account.
- P7 does not infer salary, rent, or other recurrence from historical transactions. No schedule model means no fabricated event.
- Forecast totals separately expose exact due outflow and expected receipt inflow. The UI must keep the “forecast” label visible and explain the sources.

## Debt projection

- `current_credit_debt_minor` equals the sum of current positive debt for credit accounts, checked for overflow.
- Account rows expose credit limit, current debt, available credit, overdue state, next exact due cycle, and unresolved-opening status.
- Cycle rows expose amount due, repaid, remaining, due date, status, and overdue state. Settled cycles remain available to period drill-down but do not inflate current due totals.
- Installment rows/groups expose future scheduled principal, fee, total gross, month, period count, and plans using P5 terminology. They are not added to current debt and are not reduced by generic repayment guesses.

## Overview and drill-down

- `GET /api/v1/reports/overview?month=YYYY-MM` returns the trusted month summary, account value summary, current debt, reimbursement outstanding, uncategorized coverage, up to five recent canonical transactions, and the nearest forecast events.
- `GET /api/v1/reports/spending?date_from=&date_to=` returns the spending projection, category hierarchy, and daily/monthly trend.
- `GET /api/v1/reports/cash-flow?date_from=&date_to=&forecast_days=30&today=` returns actual cash flow, account analysis, actual trend, and future events.
- `GET /api/v1/reports/debt?as_of=` returns current credit debt, exact cycle due rows, and future installment scheduled-gross groups.
- `GET /api/v1/reports/drill-down?lens=spending|cash_flow&date_from=&date_to=&category_id=&account_id=&cursor=&limit=` returns stable signed report line items and an opaque cursor. Filters combine with AND and retain the selected lens semantics.
- Apple may use the dedicated report endpoints only. It must not recompute totals from separately paginated screen data.

## Apple experience

- P1 `OverviewFixture` remains preview-only. Production iOS/macOS roots inject one `ReportsModel` backed by the real API; offline state never displays sample money as if it were the user's ledger.
- iOS provides a trusted overview, a dedicated list-only cash-flow tab, and spend/debt report destinations under More. Cash flow must not be duplicated inside Reports, and iOS reporting uses scannable amount/category/account/detail lists without charts.
- macOS provides the formal overview, two-column cash-flow screen, and dense segmented spending/cash-flow/debt report screen with period controls and drill-down inspector/list.
- Charts are a macOS-only analysis surface and use native SwiftUI Charts at the macOS 26 baseline. iOS stays list-only. No third-party UI library is introduced.
- Empty, loading, stale-preserved refresh error, offline, long category names, negative contra-expense, and Int64 failure states are independently verified. Main screens and every period selector/drill-down state receive visual review; default forms/toolbars are not final UI.

## Completion gates

- Unit and PostgreSQL tests cover all lens exclusions, refund re-attribution, reimbursement expected/received timing, cash/debit posting signs, internal transfers, repayment, opening balances, credit cycle due events, installment non-duplication, uncategorized coverage, Shanghai month edges, leap day/year, future-window edges, pagination, and Int64 overflow.
- Overview values equal the corresponding report-service fields for the same range/as-of inputs.
- Backend formatting, lint, strict typing, default tests, full PostgreSQL tests, migration drift, Apple tests, iOS build, and macOS build pass.
- Authenticated real-API screenshots cover iOS overview/cash flow/spending/debt/drill-down and macOS overview/cash flow/all three report segments at 940×700 points before P7 acceptance.
