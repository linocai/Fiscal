# Fiscal P6 Multi-party Reimbursement Contract

Date: 2026-07-15 (Asia/Shanghai)

This document freezes P6 before implementation. `PROJECT_PLAN.md` remains authoritative. P6 adds multi-expense, multi-party reimbursement claims and real partial receipts to the unified ledger. Formal charts remain P7; attachments, approval workflows, AI/OCR persistence, multi-currency, and global payer master data remain out of scope.

## Canonical truth

- A claim never copies account balances, expense dates, or categories. Original `expense` and `credit_purchase` transactions remain the consumption truth.
- A reimbursement receipt is a real server-owned ledger transaction. It increases one cash/debit account but is not ordinary income and never reduces credit-card debt automatically.
- The reimbursement amount truth is a matrix row: one party × one original expense allocation. Separate expense totals and party totals without a matrix are forbidden because they cannot explain partial receipts by original expense.
- All CNY values are positive signed-64-bit integer fen. Floats, booleans, zero, and overflow are rejected atomically.

## Stored objects

- `ReimbursementClaim`: title, optional note, workflow/lifecycle timestamps, idempotency identity, version, timestamps.
- `ReimbursementParty`: claim-local name, expected receipt date, optional note, stable position.
- `ReimbursementAllocation`: stable party × expense row, amount and position.
- `ReimbursementReceipt`: claim, party, canonical receipt transaction, version, lifecycle timestamps.
- `ReimbursementReceiptAllocation`: persisted allocation of one receipt into the selected party's matrix rows.
- `ReimbursementClaimRevision`, `ReimbursementReceiptRevision`, and `ReimbursementOperation`: immutable result snapshots and replay identity required for correctness, not a user-facing history product.

Parties are claim-local business subjects, not global contacts. Attachments and upload APIs are explicitly excluded from P6.

## Conservation

For every active claim:

```text
claim.total_claimed_minor = SUM(all matrix allocation amounts)
party.claimed_minor = SUM(that party's matrix allocation amounts)
party.received_minor = SUM(active receipt allocations for that party)
allocation.received_minor = SUM(active receipt allocations for that row)
0 <= allocation.received_minor <= allocation.amount_minor
0 <= party.received_minor <= party.claimed_minor
claim.received_minor = SUM(active receipt amounts) <= claim.total_claimed_minor
```

For every active receipt, its persisted receipt allocations sum exactly to its canonical transaction amount. Receipt creation/edit deterministically consumes the selected party's remaining matrix rows in stable `(position, id)` order and persists the result; it never rewrites other receipts.

Across all claims, effective allocations for one original expense cannot exceed one shared reimbursable-capacity function:

```text
plain expense capacity = active transaction amount
installment purchase capacity = purchase amount - SUM(active principal-refund ledger links)
```

- live claim: full allocation amount is effective;
- cancelled outstanding: only actually received allocation remains effective;
- voided draft: zero is effective.

This permits released, never-received capacity to be claimed again without erasing real historical receipts.

## Eligible expenses and cross-module rules

- Eligible: active `expense` and active `credit_purchase`.
- Ineligible: income, transfer, repayment, installment fee/refund, reimbursement receipt, or any voided transaction.
- Partial allocation and allocation across multiple claims are allowed, subject to the global cap.
- An installment-linked credit purchase may be reimbursed, but installment fees never may.
- P5 plan replacement that reduces principal and P5 future cancellation/refund must call the same reimbursable-capacity check and fail with `reimbursement_claim_in_use` if net principal would fall below effective reimbursement allocation. Fee refunds never enter capacity. PostgreSQL uses the identical formula and protects direct SQL.
- A generic source-expense edit may change presentation/account/category/date fields while remaining eligible and sufficiently funded. Changing kind, reducing amount below effective allocation, or voiding an in-use expense is rejected.
- Credit-purchase reimbursement receipts enter cash/debit; the credit liability remains until a normal credit repayment occurs.

`TransactionResponse` returns an exact `reimbursement_relations` array because one expense may participate in multiple claims. Each relation identifies role (`expense` or `receipt`), claim, optional party/receipt, claim title/status, allocated, received, and outstanding fen.

## Receipt ledger shape

Add server-only `reimbursement_receipt`:

- `source=system`;
- exactly one positive `account` posting;
- active cash/debit account for creation or edit;
- null category and credit cycle;
- exactly one reimbursement receipt link;
- rejected by public `TransactionDraft`;
- generic transaction update/void/restore rejected with `reimbursement_receipt_in_use`.

It affects account balance and actual cash flow on `received_at`, but is excluded from ordinary income, expense, category totals, and credit debt. Receipt creation, replacement, void, and restore are reimbursement-only mutations.

## Derived status and lifecycle

Claim status is derived, never freely written. Void is checked first, then cancellation, then submitted/receipt proportions. A cancelled claim always requires `received_minor < total_claimed_minor`:

- `draft`: not submitted, no active receipts;
- `pending`: submitted, received zero, not cancelled;
- `partial_received`: zero < received < claimed, not cancelled;
- `received`: received equals claimed;
- `cancelled`: outstanding cancelled and received zero;
- `partially_received_cancelled`: outstanding cancelled after a partial receipt.

Transitions:

- create → `draft`;
- submit: draft → pending;
- retract submission: pending → draft only with zero active receipts;
- receipt from draft atomically sets `submitted_at`;
- cancel outstanding: pending/partial → cancelled/partially-received-cancelled;
- reopen reclaims released capacity and fails if another claim now uses it;
- increasing a fully received claim can derive partial again.
- cancelled, voided, or archived claims reject new receipts; archived claims reject every receipt mutation until unarchived.
- cancelled claims must reopen before adding a receipt, increasing a receipt, or restoring one that would make the claim fully received. Reducing or voiding an existing historical receipt remains permitted correction.

Party status is derived from its claimed/received values and claim cancellation state.

## Claim editing, void, and archive

- Claim editing is preview-driven full replacement with `expected_version`.
- Existing party/allocation rows carry stable IDs. A matrix row covered by an active receipt locks its party, expense identity, and received lower bound; its amount may not fall below received. Voided receipt allocations do not lock the current matrix and their immutable revision snapshot preserves the old distribution.
- A party with receipts cannot be removed. Unreceived amounts may move between eligible rows and parties while all conservation rules remain true.
- Cancelled claims must reopen before matrix amounts change; title, note, party name/note/expected date may still be corrected.
- Only a draft for which no receipt row has ever existed may be voided and later restored after revalidation; no physical delete. Historical voided receipts still block claim void.
- Only received/cancelled/partially-received-cancelled claims may archive. Archive is read-only visibility, not financial mutation, and can be undone.
- Every structural or lifecycle mutation increments claim version and stores a canonical result snapshot.

## Receipt editing and lifecycle

Receipt create request contains `expected_claim_version`, party, amount, aware received time not later than server now, destination cash/debit account, title, and optional note. Create requires an `Idempotency-Key` UUID.

Complete replacement contains both claim and receipt expected versions and may change party, amount, account, received time, title, and note. The service excludes this receipt's prior allocations, validates target capacity, deterministically reallocates it, updates the canonical transaction/posting, increments both versions, and commits atomically.

Specialized void soft-voids the canonical transaction and keeps its posting, receipt row, revisions, and immutable prior allocation snapshot; the posting and receipt allocations simply leave active aggregates. The claim may then edit its current matrix. Specialized restore clears transaction void state and deterministically reallocates the original receipt amount against the current matrix; it does not require obsolete matrix-row IDs to return. Restore fails if current capacity, account reference, cancellation state, or Int64 constraints do not hold. An archived original cash/debit account may retain its exact reference. Repeat void/restore is idempotent at the current version.

`ReimbursementReceipt` does not duplicate amount, account, received time, title, or note. Those values are derived from its canonical transaction/posting, and API `received_at` equals transaction `occurred_at`.

Receipt replacement, void, and restore also increment the canonical transaction version and write its normal `updated`, `voided`, or `restored` transaction revision. Transaction, claim, and receipt versions, posting state, receipt allocations, and all nested replay snapshots commit in one transaction; embedded `TransactionResponse` always carries the resulting transaction version.

## Reporting semantics

All consumption projections stay anchored to original expense Shanghai business date, category, and account:

```text
gross expense = canonical source expense amount
reimbursable capacity = gross for plain expense, or gross minus active principal refunds for installment purchase
merchant principal refund = gross expense - reimbursable capacity
expected reimbursement = live allocation amount, or received amount after outstanding cancellation
received reimbursement = active receipt allocations
personal expected expense = gross expense - merchant principal refund - expected reimbursement
personal realized expense = gross expense - merchant principal refund - received reimbursement
```

Summary and expense drill-down expose `merchant_principal_refund_minor` explicitly so gross consumption, merchant refunds, reimbursement, and personal responsibility reconcile visibly.

Expected receipts never create future ledger or cash-flow transactions. Actual `reimbursement_receipt` is an independent cash-flow inflow on its own receipt date. P6 provides trusted totals and drill-down inputs only; P7 owns formal charts.

## API

All routes are authenticated under `/api/v1` and use exact request/response fields.

- `GET/POST /reimbursement-claims`
- `GET/PUT /reimbursement-claims/{id}`
- `POST /reimbursement-claims/{id}/preview`
- `POST /reimbursement-claims/{id}/submit`
- `POST /reimbursement-claims/{id}/retract-submission`
- `POST /reimbursement-claims/{id}/cancel-preview`
- `POST /reimbursement-claims/{id}/cancel-outstanding`
- `POST /reimbursement-claims/{id}/reopen`
- `POST /reimbursement-claims/{id}/void|restore|archive|unarchive`
- `GET/POST /reimbursement-claims/{id}/receipts`
- `POST /reimbursement-claims/{id}/receipt-preview`
- `GET/PUT /reimbursement-receipts/{id}`
- `POST /reimbursement-receipts/{id}/preview|void|restore`
- `GET /transactions/{id}/reimbursement-eligibility`
- `GET /reimbursement-expense-options`
- `GET /reimbursements/summary?date_from=&date_to=`

Exact optimistic payloads:

- claim lifecycle, cancel preview/action: `{ "expected_version": int }`;
- receipt create: `expected_claim_version` inside the exact receipt draft;
- receipt void/restore: `{ "expected_claim_version": int, "expected_receipt_version": int }`;
- receipt replacement carries both expected versions plus the complete receipt draft.

Claim list order is `(created_at DESC, id DESC)`; receipt list is `(received_at DESC, id DESC)`. Cursors are opaque and stable. Filters combine in SQL, not after pagination.

Claim create/replacement sends ordered parties containing ordered allocations. Claim responses return server-derived total/received/outstanding counts, party/expense teasers, matrix rows, `receipt_count`, an optional latest-receipt teaser, versions, and lifecycle timestamps. Unbounded complete receipt history comes only from its stable paginated endpoint. Apple never derives conservation, status, or receipt allocation locally.

## Idempotency and concurrency

- Claim create and receipt create require UUID idempotency keys.
- Same key + same canonical request returns the immutable first result without duplicate rows, postings, allocations, revisions, or version changes.
- Same key + different request returns `idempotency_key_reused`; receipt replay is bound to its claim and party.
- All P6 mutations use the existing transaction-scoped advisory lock plus relevant row locks and optimistic versions.
- Receipt mutations increment both receipt and claim versions.
- PostgreSQL deferred validators lock the claim row before aggregate checks to prevent concurrent write skew.

## Database defense and downgrade

The migration adds claims, parties, matrix allocations, receipts, receipt allocations, revisions, operations, indexes, exact checks, and deferred constraint triggers. Database validation covers matrix ownership, stable positions, positive amounts, transaction/link shape, receipt allocation conservation, party/row overpayment, global expense over-allocation, source-expense mutation, and unlinked system receipts.

A data-bearing P6 → P5 downgrade is rejected before destructive work. Empty P6 → P5 → P6, fresh P1/P5 → P6, repeat upgrade, model drift, and offline SQL must pass. Downgrade restores the exact P5 transaction-kind and shape constraints.

## Stable errors

- `reimbursement_claim_not_found`, `reimbursement_receipt_not_found`
- `reimbursement_claim_in_use`, `reimbursement_receipt_in_use`
- `reimbursement_expense_not_eligible`, `reimbursement_expense_overallocated`
- `reimbursement_amount_mismatch`, `reimbursement_party_not_found`
- `reimbursement_party_in_use`, `reimbursement_allocation_locked`
- `reimbursement_receipt_exceeds_outstanding`
- `reimbursement_invalid_status_transition`
- `reimbursement_claim_cancelled`, `reimbursement_claim_archived`
- `reimbursement_operation_conflict`
- existing version, idempotency, authentication, validation, and Int64 errors remain stable.

## Apple UX contract

- iOS keeps the explicit root content switch, zero native tab bars, and one custom bottom bar. More → Reimbursements opens one navigation stack; detail does not nest another stack. Screens retain bottom safe-area clearance and the shared background to prevent duplicate navigation or top artifacts.
- iOS provides claim overview/list, detail, party/expense/receipt drill-down, full edit, and preview-driven quick receipt. Receipt confirmation displays server-calculated before/after values.
- macOS replaces the P6 placeholder with a modern dense claim list, detail/matrix view, receipt history, and a wide full-replacement editor. It does not add another sidebar or squeeze matrix editing into the old narrow inspector.
- Both platforms distinguish loading, empty, unauthorized, offline, stale refresh, conflict, archived, locked, and terminal states without fixture fallback.
- Wording explicitly says receipts are real cash inflows but not ordinary income; expected and realized personal expense remain distinct.

## Completion evidence

- PostgreSQL tests cover all four matrix shapes, multiple/interleaved receipts, one-fen and Int64 edges, status transitions, full edits, receipt replacement/void/restore, idempotency, concurrency, source-transaction/P5 refund guards, direct SQL, pagination, summary semantics, and migration roundtrips.
- Real API smoke uses at least three expenses, two parties, and multiple partial receipts; account balance rises by actual receipts while ordinary income does not.
- Shared Apple tests cover exact DTOs, request snapshots, stale generation, preview invalidation, refresh propagation, and conflicts.
- Authenticated iOS UI evidence asserts zero native tab bars and one custom bottom bar, then performs real receipt preview/commit.
- Visual evidence includes iOS list/detail/receipt preview and macOS claim matrix/editor at 940×700 points.
