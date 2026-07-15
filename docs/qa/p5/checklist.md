# P5 QA Checklist

## Contract and scope

- [x] P5 contract frozen before implementation.
- [x] Principal consumption remains one canonical credit purchase.
- [x] Fees, settlement, cancellation, and forecast semantics are explicit.
- [x] Plan/month projections are contractual scheduled-gross values; only account debt and cycle paid/remaining are exact after a generic repayment.
- [x] P6 reimbursements and P7 reports/cash flow remain excluded.

## Database and migration

- [x] P5 migration adds plan, period, operation, ledger-link, source/kind checks, indexes, and deferred validators without changing existing P4 direct-cycle data.
- [x] Database guards reject wrong account/kind/source/category, opening or cross-account cycles, duplicate purchase plans, non-contiguous sequences, invalid system posting shapes, and direct SQL allocation drift.
- [x] Deferred validation proves `SUM(non-cancelled principal/fee)` equals canonical purchase/fee after role-discriminated refunds; cancelled audit rows are excluded and early-settled rows remain included.
- [x] Any extant plan/link permanently suppresses the linked purchase/fee/refund direct-cycle placement across active, completed, settled-early, partially-cancelled, and cancelled states.
- [x] Data-bearing P5 downgrade is rejected before destructive work and preserves data; empty P5 → P4 → P5, P1/P4 → P5, repeated upgrade, schema drift, and offline SQL pass.

## Backend allocation and API

- [x] Create accepts only an active manual credit purchase whose natural cycle is open and has no active repayment; archived, voided, wrong-kind, opening-cycle, cross-account, and duplicate-plan inputs fail atomically.
- [x] Cycle options and every preview are read-only: projected cycles may have null IDs and no cycle is materialized until a mutation resolves the submitted statement date under the shared lock.
- [x] Principal and fee split independently in integer fen for 2...60 periods, including ¥3,299 + ¥100 / 6, zero fee, one-fen remainder, cross-month/year schedules, Int64 overflow, and zero-amount-period rejection.
- [x] Fee creation enforces category, aware `fee_occurred_at`, purchase/current-time bounds, negative credit posting, `source=system`, null direct cycle, canonical revision, and ledger-link role `fee`.
- [x] Persisted period responses always carry non-null cycle IDs; preview period IDs remain nullable, and all exact response/request envelopes decode with no undocumented fields.
- [x] `TransactionResponse` always returns the exact nullable outer installment keys; public drafts reject system-only kinds while global history can decode fee/refund/system repayment rows.
- [x] Derived plan status follows terminal/completed priority without mutating plan version when a generic P4 repayment changes only cycle settlement.
- [x] Plan/account/month APIs expose only `scheduled_gross_minor` / `future_scheduled_gross_minor` names; no API field claims a plan-attributed paid or remaining amount.

## Editing, payment, and cancellation

- [x] With no locked period, full replacement updates the linked purchase, fee, allocation, limits, summaries, cycles, usage, revisions, and versions atomically.
- [x] With a locked prefix, account/date/category/principal, total fee, fee category/time, start statement date, and locked period identity/amount/cycles remain unchanged; only title/note and deterministically rebalanced future count may change.
- [x] Generic edit/void/restore rejects every plan-linked purchase and server-owned fee/refund/settlement transaction.
- [x] Early settlement accepts only settled locked cycles plus an unlocked suffix, moves effective allocations to one eligible target cycle, and creates one exact system P4 repayment with payment-account, debt, cycle, operation, revision, and replay result committed atomically.
- [x] Settlement reversal is idempotent, voids only the linked system repayment, restores original effective cycles/lifecycle, and rejects later dependent mutations or repayments.
- [x] Future cancellation creates at most one principal and one fee contra-expense refund with explicit ledger roles, excludes only complete unlocked periods, and keeps locked history unchanged.
- [x] Cancellation replay never duplicates refunds; operation-key reuse with a different request fails, rollback leaves no partial operation, transaction, period, posting, or revision state.

## Reconciliation and concurrency

- [x] Before repayment, canonical account debt equals all cycle remaining and non-cancelled period principal/fee equals linked canonical postings after refunds.
- [x] A shared future cycle containing regular purchases and multiple plans remains correct through a generic partial repayment: account debt and cycle remaining decrease exactly, while every plan/month scheduled-gross value remains unchanged and is never component-attributed.
- [x] Full cycle settlement removes its periods from future scheduled gross and may derive plan `completed`; repayment edit/void/restore recalculates exact account/cycle values without inventing plan allocation.
- [x] Concurrent create/edit/repayment/settlement/reversal/cancellation operations serialize under the shared advisory lock, enforce optimistic versions, and return stable idempotent replays.
- [x] Pagination, archived-history reads, summaries, cycle detail, installment liabilities, and rollback behavior pass against real PostgreSQL.
- [x] Ruff, Pyright, default tests, real PostgreSQL tests, Alembic migration tests, and offline SQL pass.

## Apple

- [x] Shared exact DTOs decode persisted versus preview periods, system ledger kinds, operation results, relation summaries, and nullable projected cycle IDs.
- [x] Repository/model cancellation is isolated from credit and transaction pagination; preview-driven editors never calculate allocation, cycle dates, totals, or liability groups locally.
- [x] iOS credit detail, installment detail/edit, settlement, and cancellation use real API.
- [x] macOS Accounts shows installment teaser, plan/period Inspector, and future debt.
- [x] iOS/macOS label scheduled gross as a contractual future schedule, never as an exact outstanding/paid balance, and do not add installment periods to Cash Flow or Reports.
- [x] Count-based progress, next-period gross amount, terminal states, partial-cycle context, and exact enclosing cycle paid/remaining remain visually distinguishable.
- [x] Loading/error/conflict/locked/archived states work without fixture fallback.
- [x] Settlement/reversal/cancellation confirmations show server preview impact and handle replay, stale version, in-use, and rollback errors without optimistic local mutation.
- [x] iOS remains zero native tab bars and one custom bottom bar.

## Evidence and acceptance

- [x] Real API integration run recorded in `results.md`.
- [x] Evidence includes create/edit, locked suffix, generic partial repayment gross semantics, early settlement/reversal, cancellation refunds, terminal aggregation, idempotent replay, and archived history.
- [x] iOS installment summary/detail/editor evidence captured.
- [x] macOS installment/period/future-debt evidence captured at 940×700.
- [x] Screenshots prove scheduled-gross wording is not presented as exact repayment balance and no installment projection contaminates cash-flow totals.
- [ ] User accepts P5 before P6 begins.
