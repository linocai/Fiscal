# Fiscal P4 Credit Cycles and Repayments Contract

Date: 2026-07-15

This document freezes P4 before implementation. `PROJECT_PLAN.md` remains authoritative. P4 extends the unified ledger with credit-card purchases, statement cycles, and repayments. Installments, reimbursements, formal reports, AI/OCR persistence, and multi-currency remain later phases.

## One ledger and money truth

- Credit purchases and repayments are ordinary `Transaction` business events with server-generated `Posting` rows. A cycle groups those events; it never stores an independently editable balance.
- Transaction kinds expand to `income`, `expense`, `transfer`, `credit_purchase`, and `repayment`.
- A credit purchase has one credit-account posting of `-amount`; because credit debt is `opening_balance_minor - SUM(active postings)`, the positive amount owed increases.
- A repayment has a payment-account posting of `-amount` and a credit-account posting of `+amount`. It reduces cash and debt, sums to zero, and never contributes to income or expense.
- Credit purchases contribute to expense/category summaries using their occurrence date. Repayments do not contribute to consumption or income/expense summaries; later cash-flow reporting will include their payment-account outflow.
- `Account.current_balance_minor` remains a positive amount owed for credit accounts. `available_credit_minor = max(credit_limit_minor - current_balance_minor, 0)` and `over_limit_minor = max(current_balance_minor - credit_limit_minor, 0)`.
- New/increased/restored credit purchases are rejected when they would exceed the current limit. Historical correction, lowering a limit, or voiding a repayment may expose a real over-limit state; those operations remain possible, return `over_limit_minor`, and block further debt-increasing purchases until debt is back within limit. A mutation that would make credit debt negative is always rejected atomically.
- CNY integer-fen, signed-64-bit overflow protection, Shanghai business dates, idempotency, optimistic versions, revisions, soft void/restore, shared advisory locking, and archived-reference retention continue from P3.

## Cycle calendar

- `statement_day` and `due_day` remain restricted to 1...28, so all generated dates exist in every month.
- A purchase belongs to the cycle whose `period_end` is the first occurrence of `statement_day` on or after its Shanghai business date. `period_start` is the day after the preceding statement date. Both bounds are inclusive.
- `statement_date` equals `period_end`. `due_date` is the first occurrence of `due_day` strictly after `statement_date`: in the same month when `due_day > statement_day`, otherwise in the following month.
- Example: statement day 10 and due day 22 gives cycle `2026-06-11...2026-07-10`, statement date `2026-07-10`, due date `2026-07-22`.
- The server creates a deterministic cycle row on demand, unique by `(account_id, period_start, period_end)`. Clients never invent cycle dates or IDs.
- A credit account may change statement/due day only before its first normal cycle or credit transaction exists. After that point P4 returns `credit_schedule_in_use`; effective-dated schedule transitions are deferred rather than creating overlapping or gapped cycles. Existing cycles retain their calendar snapshot.
- Cycle resolution first reuses the existing normal cycle containing the business date. Otherwise it generates the unique adjacent cycle from the frozen account schedule. Normal cycles for an account may neither overlap nor leave gaps; the special opening marker is excluded from this containment rule.

## Opening debt

- `Account.opening_balance_minor` remains the sole opening-debt amount truth, but amount alone cannot truthfully reveal whether imported debt is billed, unbilled, or overdue. P4 therefore adds optional credit-only `opening_balance_as_of_date` and `opening_due_date`.
- A positive credit opening debt requires both dates for newly created or edited accounts. The as-of date must not be after the server's current Shanghai date, and `opening_due_date` must be on or after the as-of date. Zero opening debt requires both fields to be null.
- Existing pre-P4 credit accounts with positive opening debt migrate with null dates and return `opening_configuration_required = true`; the UI asks the user to confirm the two dates instead of inventing them. Normal credit purchases may still be recorded, but repayment and overdue claims for the unresolved opening component are disabled until configured.
- Configuration creates one special immutable-identity opening cycle marker with `period_start = period_end = statement_date = opening_balance_as_of_date`, the explicit due date, and `is_opening_cycle = true`. Its display label is “期初欠款”, not a fabricated normal statement period. Its derived amount reads the account opening debt; no second amount is stored.
- Credit transactions may not predate a configured opening as-of date. If opening debt is unresolved, normal cycles remain exact and repayable, but the unknown opening component itself has no due/status and cannot be targeted.
- The opening-cycle ID stays stable when its dates or amount are corrected through account configuration; only this operation may update its calendar snapshot. Changing opening debt to zero removes an unreferenced marker. A marker with any canonical repayment reference cannot be removed or reduced below its repaid amount and returns `credit_cycle_overpaid` atomically.

## Cycle derivation and status

Stored cycle fields are identity/calendar metadata only: `id`, `account_id`, `period_start`, `period_end`, `statement_date`, `due_date`, `is_opening_cycle`, `created_at`, and `updated_at`.

Every response derives:

- `purchase_minor`: active credit purchases assigned to the cycle.
- `opening_minor`: the account opening debt only for the opening cycle, otherwise zero.
- `amount_due_minor = opening_minor + purchase_minor`.
- `repaid_minor`: active repayments explicitly assigned to the cycle.
- `remaining_minor = amount_due_minor - repaid_minor`, always non-negative.

When opening configuration is complete, `current_debt_minor = SUM(all cycle remaining_minor)`. While a positive opening debt is unresolved, `current_debt_minor = opening_balance_minor + SUM(normal cycle remaining_minor)`; `next_due_cycle` and `has_overdue_cycle` make no claim about that unresolved component. In both cases, the sum of active repayment transaction amounts equals the sum of cycle `repaid_minor`, and every repayment appears in exactly one cycle.

Status is a pure function of the injected/server Shanghai current date, evaluated in this priority order:

- `settled`: remaining is zero, including a zero-activity cycle.
- `overdue`: due date has passed and remaining is positive, regardless of partial payment.
- `open`: statement date is today or later and remaining is positive; early repayments are allowed.
- `partial`: statement has passed, some positive repayment exists, and remaining is positive.
- `unpaid`: statement has passed, no repayment exists, remaining is positive, and due date has not passed.

The API also returns `is_overdue` explicitly. Status is derived at read time, not persisted as mutable truth.

## Transaction shapes

The unified create/update payload adds nullable `credit_cycle_id` and keeps exact-field validation.

- `credit_purchase`: positive amount, aware occurrence instant, title/note, active credit `account_id`, active expense `category_id`, no destination, and no client-supplied cycle. The server assigns and returns `credit_cycle_id`.
- `repayment`: positive amount, aware occurrence instant, title/note, active cash/debit payment `account_id`, credit `destination_account_id`, required `credit_cycle_id`, and no category. The target cycle must belong to the destination credit account.
- Existing income/expense/transfer shapes require `credit_cycle_id = null` and keep their P3 account rules.
- One repayment targets exactly one cycle. P4 performs no automatic cross-cycle allocation. The user can create separate repayments for multiple cycles.
- Repayment amount may equal or be below the cycle's remaining amount. Overpayment and credit balances are out of P4 scope and return `repayment_exceeds_cycle_remaining`.
- For each credit account and for each individual target cycle, active credit events are ordered by `occurred_at`; events sharing an instant are netted as a group. Opening debt becomes available to the opening cycle at its as-of date. Account-wide and cycle-local cumulative purchases/opening minus assigned repayments must remain non-negative at every prefix, so a repayment cannot be backdated before the liability in its target cycle even when another cycle still has debt.
- A credit purchase automatically moving cycles during edit is included in the update response. Before a date/account edit, Apple shows a generic server-recalculation impact confirmation using the known old cycle; after save it displays the exact server-assigned new cycle. Clients never reproduce the calendar algorithm.

## Editing, void, restore, and safety

- Credit purchases and repayments use the existing complete replacement, revision, void, restore, idempotency, and version mechanisms.
- Before commit, the server derives every affected old/new cycle and credit account. No mutation may leave a cycle overpaid, make any account-wide or cycle-local chronological debt prefix negative, or put a signed-64-bit derived value out of range. Only debt-admission mutations—credit-purchase create, increase, move to the target card, or restore—enforce `debt_after <= credit_limit_minor`; historical corrections may expose `over_limit_minor` as defined above.
- Editing or voiding a purchase from a partially paid/settled cycle is allowed only if its new derived amount remains at least the active repayments. Otherwise return `credit_cycle_overpaid`.
- Editing, voiding, or restoring a repayment immediately recalculates payment-account balance, credit debt, cycle paid/remaining amount, and status.
- Restore permits the transaction's original archived references, as in P3, but still enforces chronological non-negative debt, cycle ownership, and non-overpayment invariants. Restoring a credit purchase is a debt-admission operation and also enforces the current limit; restoring a repayment is not.
- Used credit accounts cannot change kind. Existing cycle calendar snapshots survive account archive and configuration changes.

## API

All routes are device-token protected under `/api/v1` and use the existing error envelope.

- Existing `/transactions` list/create/get/update/void/restore endpoints accept and return the two new kinds and `credit_cycle_id`.
- Existing list `kind` filter accepts the new kinds; account filter continues to match any posting.
- Existing transaction summary counts `credit_purchase` as expense and excludes `repayment`.
- `GET /credit-accounts` returns active credit-account summaries.
- `GET /credit-accounts/{account_id}` returns one summary and its actionable/latest cycle; archived accounts remain directly readable for historical traceability.
- `GET /credit-accounts/{account_id}/cycles?cursor=&limit=20` returns cycles ordered by `period_end DESC, id DESC`.
- `GET /credit-cycles/{cycle_id}` returns the cycle summary.
- `GET /credit-cycles/{cycle_id}/transactions?cursor=&limit=50` returns its credit purchases and repayments, newest first.

Credit-account summary fields include account identity/configuration, `current_debt_minor`, `available_credit_minor`, `over_limit_minor`, `opening_configuration_required`, `current_cycle`, `next_due_cycle`, and `has_overdue_cycle`. `current_cycle` is the normal cycle containing today, materialized on demand. `next_due_cycle` is the remaining cycle with the earliest due date, with overdue cycles naturally first; the opening marker participates only after configuration. Cycle responses include all calendar, derived amount, status, and version/lifecycle fields needed by Apple; clients never calculate totals from paginated rows.

Stable P4 errors add:

- `credit_account_not_found`, `credit_cycle_not_found`
- `credit_cycle_account_mismatch`, `credit_cycle_overpaid`
- `credit_limit_exceeded`, `repayment_exceeds_cycle_remaining`, `credit_opening_configuration_required`, `credit_schedule_in_use`
- Existing validation, archived reference, conflict, authentication, and derived-range errors remain stable.

## Apple client and UX

- Shared `Codable & Sendable` DTOs, repository actors, `@MainActor @Observable` models, generation cancellation, non-destructive refresh banners, idempotency retry, and conflict recovery follow P3 patterns.
- The global record editor adds “信用消费” and “还款”. Credit purchase shows credit account and expense category. Repayment shows payment account, credit account, and one target cycle.
- iOS adds “信用账期” under More: credit-account summary, cycle detail, consumption/repayment rows, history, status, full-payment action, and partial-payment sheet. It keeps zero `TabView` references and exactly one custom bottom bar.
- macOS keeps credit inside Accounts rather than adding a second navigation concept. Its account cards show debt, limit usage, current due, due date, and statement date; selecting a credit account exposes approximately 256-point cycle/detail management and repayment actions.
- Both platforms expose open, unpaid, partial, settled, overdue, empty, loading, offline, unauthorized, conflict, overpayment, and archived-history states. No Preview fixture may replace failed real data.
- P5 installment content is absent or explicitly unavailable; P4 must not display fabricated installment data.

## Completion evidence

- Migration from P1→P4, harmless second upgrade, schema drift, offline SQL, formatting, lint, typing, default tests, and real PostgreSQL tests pass.
- Tests cover calendar boundaries, due-date rollover, opening debt, signs, expense-summary inclusion, repayment exclusion, partial/full repayment, early repayment, overpayment, credit limit, idempotency, stale versions, date/account edits across cycles, void/restore, archived references, cycle pagination, and mutation rollback.
- Real API smoke proves account debt, cycle amounts/status, P3 summary, and payment-account balance remain consistent through create/edit/void/restore.
- iOS/macOS build and shared tests pass. Real-API UI evidence covers iOS credit navigation/repayment and macOS account/cycle management at 940×700 without clipping.
- User acceptance of credit-account, cycle, purchase, and repayment behavior is required before P5 begins.
