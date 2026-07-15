# Fiscal P5 Installment Contract

Date: 2026-07-15

This document freezes P5 before implementation. `PROJECT_PLAN.md` remains authoritative. P5 adds installment scheduling to an existing canonical credit purchase without creating a second purchase or balance truth. Reimbursements, formal reports, recurring bills, automatic bank execution, AI/OCR persistence, and multi-currency remain later phases.

## Canonical money truth

- An installment plan belongs to exactly one active manual `credit_purchase`; `purchase_transaction_id` is unique. The purchase's existing credit posting remains the sole principal debt and contributes to consumption once on the purchase date.
- A known fixed installment fee is confirmed once at plan creation by one server-owned `installment_fee` ledger transaction with one negative credit posting and an expense category. It contributes a separate finance-fee expense once and immediately occupies credit limit/debt.
- `InstallmentPeriod` rows only allocate already-posted principal and fee to statement cycles. They never create principal postings, never contribute again to consumption, and cannot be edited independently of the plan command.
- While any plan/link exists, regardless of lifecycle or derived status, cycle aggregation permanently ignores direct placement of its linked purchase/fee/refund transactions and uses non-cancelled period allocations plus canonical repayments. A terminal plan never falls back to the purchase's original P4 cycle. Non-installment P4 transactions keep their existing direct-cycle behavior.
- `SUM(non-cancelled period.principal_minor) = canonical purchase principal after canonical principal refunds`; `SUM(non-cancelled period.fee_minor) = canonical fee after canonical fee refunds`. Early-settled periods remain non-cancelled and stay in these sums; cancelled audit rows are excluded. Every sum and split uses checked signed-64-bit integer fen.
- Account debt is canonical postings only: opening debt + purchases + installment fees - refunds - repayments. Only account debt and cycle-level remaining amounts reconcile after repayments. Because a generic P4 repayment belongs to a whole cycle and never claims a principal/fee/plan component, plan and monthly installment projections are gross contractual schedule values, not payment-attributed balances, and must never be added to debt.
- `scheduled_gross_minor` is the sum of every non-cancelled period's principal plus fee, without deducting generic repayments. `future_scheduled_gross_minor` is the same gross sum for non-cancelled, non-`settled_early` periods whose effective cycles are not fully settled and whose statement dates are today or later. A partial cycle repayment does not reduce or split these plan-level values; only the enclosing cycle exposes exact paid/remaining amounts. `next_period` is the earliest period included in that future gross set.

## Fee and reporting policy

- The reference ¥3,299 purchase with six ¥566.50 periods is represented as ¥3,299 principal plus ¥100 fixed fee, total financed ¥3,399.
- A non-zero fee requires an active expense `fee_category_id`; Apple defaults it to the purchase category but the user may change it. Zero fee requires no fee category and creates no fee transaction.
- Principal consumption and finance-fee expense are traceable separately. Plan/period rows add no expense. A canonical installment refund is contra-expense and reduces both debt and the original principal or fee category total.
- Future installment periods are debt forecast only. P5 does not add them to actual or forecast cash-flow totals and does not assume an autopay account. Only real P4 repayment postings are cash outflow.

## Plan and period identity

Stored `InstallmentPlan` fields:

- `id`, unique `purchase_transaction_id`, `credit_account_id`
- nullable `fee_transaction_id`, `fee_category_id`
- requested `installment_count` in `2...60`, `start_cycle_id`
- stored lifecycle `active`, `settled_early`, `partially_cancelled`, or `cancelled`
- optional settlement/cancellation operation metadata
- create idempotency key/hash, `version`, `created_at`, `updated_at`

Principal and fee totals are derived from canonical linked ledger transactions, not independently editable stored totals. Response `status` is pure and uses this priority: `cancelled`, `settled_early`, `completed`, `partially_cancelled`, `active`. `completed` means every non-cancelled period's effective cycle is settled; generic P4 repayments may change this derived status without mutating plan lifecycle or version. Thus a partially cancelled plan whose remaining periods later settle returns `completed` while retaining stored lifecycle/audit metadata.

Stored `InstallmentPeriod` fields:

- `id`, `plan_id`, contiguous `sequence` starting at one
- `scheduled_cycle_id` and `effective_cycle_id`; both reference normal cycles on the same credit account
- `principal_minor`, `fee_minor`, `cancelled_at`, `settled_early_at`, `version`, timestamps

`due_date` is the effective cycle's due date and is never duplicated. `(plan_id, sequence)` is unique. The scheduled cycles are consecutive; the opening cycle is never eligible. Multiple plans may share a statement cycle.

Stored `InstallmentOperation` fields provide ownership and idempotency for multi-transaction commands: `id`, `plan_id`, kind (`settle_early`, `reverse_settlement`, `cancel_future`), idempotency key/hash, target statement date/payment account/occurred time when applicable, lifecycle timestamps, and canonical result snapshot.

`InstallmentLedgerLink` associates each canonical transaction with a plan, optional operation, and one exact role: `purchase`, `fee`, `principal_refund`, `fee_refund`, or `settlement_repayment`. This role is the principal/fee discriminator; category equality is never used to guess refund identity.

## Deterministic allocation

- The start cycle must be the purchase's natural normal cycle or a later normal cycle on the same account. Initial deferral is allowed; after the start, exactly one period occupies each consecutive normal cycle with no skipped month.
- Principal and fee are split independently using integer quotient/remainder. For total `T` and `N` periods, `q = T / N`, `r = T % N`; the first `r` periods receive `q + 1`, and the rest receive `q`.
- P5 supports equal deterministic schedules only. Custom unequal amounts are out of scope. Clients never calculate periods, remainder, dates, or cycle IDs.
- Creating a plan materializes required future normal cycles under the shared mutation lock. It is allowed only when the source purchase's natural direct cycle is still open (`statement_date >= Shanghai today`) and has no active repayment, so P5 never rewrites already billed history. It is also rejected for archived/voided/wrong-kind references or an existing plan.
- The fee transaction uses explicit `fee_occurred_at`, required exactly when fee is positive. It must be aware, not before the purchase occurrence, and not after the server's current instant. Historical import never silently uses server-now or the purchase time.
- Any allocation that would produce a period with `principal_minor + fee_minor == 0` is rejected as `invalid_installment_schedule`.

## Occurred, locked, and status

- P5 follows P4 day semantics: `statement_date == Shanghai today` is still open. A period is locked when its cycle statement date is before today or its cycle has any active repayment.
- Locked period identity, sequence, scheduled/effective cycle, principal, and fee are immutable. This conservative rule never claims which component a generic cycle repayment paid.
- Period status is derived: `cancelled`, `settled_early`, `scheduled`, `billed`, `partial`, `cycle_settled`, or `overdue`. Payment labels never claim term-level allocation beyond what the cycle proves.
- Plan response derives locked/future counts, principal, fee, total financed, gross schedule projections, next period, and status. It never invents a plan/component allocation for a generic repayment. Archived account/plan history remains directly readable.

## Complete editing and bypass protection

- Plan update is a full semantic replacement with `expected_version`; a read-only preview endpoint returns old/new future-period and affected-cycle impact before mutation.
- With no locked periods, update may replace purchase amount/date/account/category/title/note, fee/category, count, and start cycle atomically. Canonical purchase/fee postings, period allocation, credit limit, summaries, cycles, usage, revisions, and versions all update together.
- With a locked prefix, purchase account/date/category/principal, total fee, `fee_category_id`, `fee_occurred_at`, and `start_statement_date` are frozen and replacement values must exactly equal current canonical values. Title/note and future count are the only editable fields. The future suffix may change count while locked period IDs/amounts/cycles and aggregate history remain unchanged. The server subtracts locked principal/fee from canonical totals, then applies quotient/remainder independently across `new_count - locked_count`; equal allocation applies to the editable suffix, never retroactively to locked history. If remaining allocation is positive, new count must exceed locked count. If all periods are locked, count must equal locked count and only title/note changes are allowed.
- Direct generic edit/void/restore of the linked purchase or any server-owned installment fee/refund/settlement transaction returns `installment_plan_in_use`. Coupled changes are available only through installment commands.
- All mutations use the P2–P4 advisory transaction lock, optimistic versions, stable idempotency, canonical revisions, int64 guards, cycle non-overpayment, account/cycle chronological-prefix validation, and debt-admission limit rules.

## Early settlement

- “提前结清” is a real atomic payment, not merely a due-date move. It requires `expected_version`, active cash/debit payment account, target normal cycle on the same card, aware occurrence time, and an operation `Idempotency-Key`.
- It is allowed only when every locked period cycle is already settled and every remaining period is unlocked. The server first points all remaining periods' `effective_cycle_id` to the target open/current-or-later cycle, retaining scheduled cycles for history.
- The same transaction creates one canonical P4 repayment for the exact remaining principal plus retained fee, links it to the plan, and marks those periods/plan `settled_early`. All original fixed fees are retained; no fee waiver is implied.
- Payment-account balance, credit debt, target-cycle due/remaining, plan state, revisions, and idempotency commit atomically. A retry returns the original immutable operation result and never double-pays.
- Early settlement is reversible through a dedicated idempotent `reverse-settlement` command, never generic transaction void. Reversal atomically voids the linked system repayment and restores original effective cycles/lifecycle only while no later plan mutation or active repayment in the target cycle depends on the settlement and all P4 invariants still hold. Otherwise it returns `installment_settlement_in_use`.

## Cancelling future periods

- “取消未来期次” means a real merchant/bank cancellation and refund, not merely stopping the schedule. It requires explicit destructive confirmation, `expected_version`, aware occurrence time, and an operation `Idempotency-Key`.
- Only unlocked future periods are cancelled. Their full principal and fee are waived and represented by server-owned canonical `installment_refund` contra-expense transaction(s) with positive credit postings and original principal/fee categories.
- Cancelled allocations disappear from cycle due. Refund postings reduce account debt and expense totals exactly once. Locked periods and their cycles are unchanged.
- If all periods are cancelled the plan is `cancelled`; otherwise it is `partially_cancelled`. Cancellation cannot be restored in P5; a mistaken real-world refund is corrected by recording a new purchase/plan, preserving audit history.
- Cancelling the installment arrangement while the debt remains is not a cancellation; use early settlement instead. Partial merchant refunds that do not align to complete future periods are out of P5 scope.

## Ledger transaction kinds and database defense

- Public manual kinds remain income, expense, transfer, credit purchase, and repayment. P5 adds response-visible server-only `installment_fee` and `installment_refund`; the public transaction draft rejects both.
- `installment_fee` is `source=system`, has one negative credit-account posting, an expense category, `credit_cycle_id=null`, and a required plan ledger link with role `fee`.
- `installment_refund` is `source=system`, has one positive credit-account posting, the original expense category, `credit_cycle_id=null`, and a required operation link whose role is exactly `principal_refund` or `fee_refund`. Cancellation creates at most one of each role and links the refunded period IDs through the operation snapshot.
- Early settlement creates a normal `repayment` with `source=system`, P4 source/destination postings, required target `credit_cycle_id`, and operation link role `settlement_repayment`. Generic transaction mutation rejects every system transaction and every plan-linked purchase.
- Fee/refund direct cycle IDs remain null because periods are the due-cycle allocation truth. They appear in the global transaction timeline and plan relation, not as fake direct cycle transactions. Cycle detail explains their amounts through related periods.
- Transaction source expands to `manual|system`. System kinds can only be created by `InstallmentService` and remain revisioned canonical ledger events.
- Deferred database validation enforces plan purchase/account ownership, allowed transaction kind/source, normal-cycle ownership, contiguous sequences, scheduled-cycle continuity, effective-cycle ownership, unique purchase/plan, and exact active period sums against linked canonical postings/refunds.
- Account kind, archived references, category direction, transaction posting shape, cycle/account integrity, and P4 chronological constraints remain database/service protected.

## API

All routes are device-token protected under `/api/v1` and use exact fields and the existing error envelope.

- `GET /installment-plans?account_id=&status=&cursor=&limit=20`
- `POST /installment-plans` + `Idempotency-Key`
- `GET /installment-plans/{id}`
- `POST /installment-plans/{id}/preview` with a complete replacement
- `PUT /installment-plans/{id}` with the same replacement and `expected_version`
- `POST /installment-plans/{id}/settlement-preview`
- `POST /installment-plans/{id}/settle-early` + `Idempotency-Key`
- `POST /installment-plans/{id}/reverse-settlement-preview`
- `POST /installment-plans/{id}/reverse-settlement` + `Idempotency-Key`
- `POST /installment-plans/{id}/cancel-preview`
- `POST /installment-plans/{id}/cancel-future` + `Idempotency-Key`
- `GET /transactions/{id}/installment-eligibility`
- `GET /installment-cycle-options?purchase_transaction_id=&months=60`
- `GET /installment-liabilities?account_id=`
- `GET /credit-accounts/{id}` adds `active_installment_count`, `future_scheduled_gross_minor`, and `next_installment`
- `GET /credit-cycles/{id}` adds installment principal/fee totals and related period summaries
- `TransactionResponse` adds the exact outer keys `installment_plan_id: UUID|null` and `installment_relation: InstallmentRelation|null`; cycle transaction lists remain real ledger events only.

Cycle options are read-only calendar projections with a `statement_date`; an optional `cycle_id` is returned only when that cycle already exists. Preview never writes or materializes cycles. Create/update/settlement requests submit `start_statement_date` or `target_statement_date`; the server resolves/materializes the cycle under the mutation lock, so clients never fabricate IDs.

### Exact enums and response envelopes

- `InstallmentPlanStatus`: `active`, `completed`, `settled_early`, `partially_cancelled`, `cancelled`.
- `InstallmentPeriodStatus`: `scheduled`, `billed`, `partial`, `cycle_settled`, `overdue`, `cancelled`, `settled_early`.
- `InstallmentLedgerRole`: `purchase`, `fee`, `principal_refund`, `fee_refund`, `settlement_repayment`.
- `InstallmentOperationKind`: `settle_early`, `reverse_settlement`, `cancel_future`.

`InstallmentPeriodResponse` exact fields are:

`id`, `plan_id`, `sequence`, `scheduled_cycle_id`, `effective_cycle_id`, `scheduled_statement_date`, `effective_statement_date`, `due_date`, `principal_minor`, `fee_minor`, `amount_due_minor`, `locked`, `status`, `cycle_status`, `cancelled_at`, `settled_early_at`, `version`, `created_at`, `updated_at`.

For persisted periods, both cycle IDs are non-null. Read-only previews use a separate `InstallmentPeriodPreview` with exact fields:

`sequence`, nullable `scheduled_cycle_id`, nullable `effective_cycle_id`, `scheduled_statement_date`, `effective_statement_date`, `due_date`, `principal_minor`, `fee_minor`, `amount_due_minor`, `locked`, `status`.

`InstallmentPlanResponse` exact fields are:

`id`, `purchase_transaction_id`, nullable `fee_transaction_id`, `credit_account_id`, nullable `fee_category_id`, nullable aware `fee_occurred_at`, `title`, `status`, `principal_minor`, `fee_minor`, `total_financed_minor`, `installment_count`, `start_statement_date`, `locked_count`, `future_count`, `cancelled_count`, `cycle_settled_count`, `scheduled_gross_minor`, `future_scheduled_gross_minor`, nullable `next_period`, `periods` (all periods, at most 60), `version`, `created_at`, `updated_at`. Detail embeds all periods; there is no separate period pagination endpoint in P5. The fee metadata is returned so a client can round-trip a complete replacement without guessing canonical values.

`InstallmentPlanPreview` exact fields are:

nullable `id`, `purchase_transaction_id`, nullable `fee_transaction_id`, `credit_account_id`, nullable `fee_category_id`, nullable aware `fee_occurred_at`, `title`, `status`, `principal_minor`, `fee_minor`, `total_financed_minor`, `installment_count`, `start_statement_date`, `locked_count`, `future_count`, `cancelled_count`, `cycle_settled_count`, `scheduled_gross_minor`, `future_scheduled_gross_minor`, nullable `next_period`, and `periods: [InstallmentPeriodPreview]`.

Plan list returns `{ "items": [InstallmentPlanResponse], "next_cursor": string|null }`. `InstallmentTeaser` fields are `plan_id`, `title`, `status`, `installment_count`, `future_count`, `future_scheduled_gross_minor`, and nullable `next_period`. `InstallmentRelation` fields are `plan_id`, `role`, `plan_title`, and `plan_status`.

`CreditAccountSummary` adds `active_installment_count: int`, `future_scheduled_gross_minor: int64`, and `next_installment: InstallmentTeaser|null`. `CreditCycleResponse` adds gross allocation fields `installment_principal_minor`, `installment_fee_minor`, and `installment_periods: [InstallmentPeriodResponse]` for periods whose effective cycle is this cycle; its existing cycle paid/remaining fields remain the only exact repayment balance.

### Exact mutation and preview shapes

Create request exact fields are:

`purchase_transaction_id`, `installment_count`, `total_fee_minor`, nullable `fee_category_id`, nullable aware `fee_occurred_at`, and `start_statement_date`. Create returns `InstallmentPlanResponse`.

Replacement request exact fields are:

`expected_version`, nested `purchase` with `amount_minor`, aware `occurred_at`, `title`, nullable `note`, `account_id`, and `category_id`; plus `installment_count`, `total_fee_minor`, nullable `fee_category_id`, nullable aware `fee_occurred_at`, and `start_statement_date`. Preview and PUT use the same exact replacement.

Plan preview returns `current_plan: InstallmentPlanResponse`, `proposed_plan: InstallmentPlanPreview`, `locked_periods: [InstallmentPeriodResponse]`, `future_periods: [InstallmentPeriodPreview]`, `affected_cycles`, and `warnings`. Each affected cycle has `statement_date`, nullable existing `cycle_id`, `before_due_minor`, `after_due_minor`, and `delta_minor`. Warnings are stable code/message pairs. Proposed cycles may have null IDs because preview is read-only.

Eligibility response fields are `purchase_transaction_id`, `eligible`, nullable `reason_code`, `credit_account_id`, `principal_minor`, `natural_statement_date`, and `start_options: [InstallmentCycleOption]`. A cycle option has nullable `cycle_id`, `statement_date`, `due_date`, `existing`, and `eligible`.

Settlement preview/action request fields are `expected_version`, `payment_account_id`, `target_statement_date`, and aware `occurred_at`. Preview returns `amount_minor`, `current_plan`, `proposed_plan`, `affected_cycles`, `payment_balance_before_minor`, `payment_balance_after_minor`, `debt_before_minor`, `debt_after_minor`, and `warnings`. Action result returns `operation_id`, `plan`, `repayment_transaction`, and `replayed`.

Reverse-settlement preview/action request fields are `expected_version` and aware `occurred_at`. Preview exact fields are `eligible`, `repayment_transaction`, `restored_periods: [InstallmentPeriodPreview]`, `affected_cycles`, `payment_balance_before_minor`, `payment_balance_after_minor`, `debt_before_minor`, `debt_after_minor`, and `warnings`. Action result returns `operation_id`, `plan`, `voided_repayment_transaction`, and `replayed`.

Cancellation preview/action request fields are `expected_version` and aware `occurred_at`. Preview exact fields are `principal_refund_minor`, `fee_refund_minor`, `cancelled_periods: [InstallmentPeriodPreview]`, `current_plan: InstallmentPlanResponse`, `proposed_plan: InstallmentPlanPreview`, `affected_cycles`, `debt_before_minor`, `debt_after_minor`, `expense_before_minor`, `expense_after_minor`, and `warnings`. Action result returns `operation_id`, `plan`, `refund_transactions`, and `replayed`.

Future-liability response fields are `account_id`, `total_future_scheduled_gross_minor`, and `groups`. Each group has `month` (`YYYY-MM`), `principal_scheduled_gross_minor`, `fee_scheduled_gross_minor`, `total_scheduled_gross_minor`, `period_count`, and `plans: [InstallmentTeaser]`. Groups include full eligible period amounts after excluding fully settled cycles; they do not deduct or attribute a partial generic cycle repayment. This is the only monthly gross-schedule grouping truth; Apple does not sum periods locally or label it as an exact repayment balance.

Stable errors add:

- `installment_plan_not_found`, `installment_plan_in_use`, `purchase_not_eligible`
- `installment_cycle_account_mismatch`, `installment_opening_cycle_forbidden`
- `installment_period_locked`, `installment_locked_allocation_exceeded`
- `invalid_installment_schedule`, `installment_limit_exceeded`
- `installment_settlement_not_ready`, `installment_already_settled`, `installment_already_cancelled`
- `installment_settlement_in_use`, `installment_operation_conflict`

## Apple client and visual contract

- Shared installment DTOs/repository actors and a separate `@MainActor @Observable InstallmentModel` prevent credit/transaction pagination cancellation from contaminating plan state.
- Installment creation starts from an eligible credit-purchase detail; “记一笔” does not add an installment transaction type. Apple never chains a purchase POST and plan POST as fake atomic creation.
- iOS renames the More destination to “信用账期与分期”. The credit account detail inserts the reference-style installment card between current cycle and history, showing count-based progress, per-period/next gross amount, financed total, and future scheduled gross amount. It must not call that gross projection an exact paid/outstanding balance. Plan detail lists all periods with principal, fee, due cycle/date, and protected states. Edit uses server preview; settlement and cancellation show explicit impact confirmation.
- macOS keeps P5 inside Accounts. Credit cards show the amber installment teaser. The 256-point Inspector exposes plans/periods, while editing uses a sheet. A compact “未来负债” section groups server-projected periods by month; P5 does not populate Cash Flow or Reports with locally calculated values.
- Both platforms cover loading, empty, offline, unauthorized, conflict, locked history, settled, partial cancellation, archived history, long content, and retry without Preview fallback. iOS retains zero `TabView` references and exactly one custom bottom bar.

## Migration and completion evidence

- P5 migration adds plan/period/link/revision tables, source/system-kind checks, allocation-aware cycle queries, and deferred validators without changing P4 direct-cycle data.
- A data-bearing P5 downgrade is transactionally rejected before destructive work; empty P5 → P4 → P5 remains supported.
- Tests cover ¥3,299 + ¥100 / 6 deterministic allocation, zero fee, one-fen remainder, Int64 overflow, cross-month/year cycles, wrong/opening/archived cycles, idempotency, concurrency, locked suffix edits, bypass rejection, early settlement atomic payment, cancellation refunds, summaries, cycle/account reconciliation, direct-SQL rejection, migration round trips, and real HTTP smoke.
- iOS/macOS builds and shared tests pass. Real-API UI evidence covers plan detail/edit/settlement or cancellation, iOS single navigation, and macOS 940×700 reference-aligned installment/future-liability layout.
- User acceptance of P5 installment history, editing, settlement, cancellation, and future debt is required before P6 begins.
