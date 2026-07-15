# P6 QA Checklist

## Contract and ledger

- [x] P6 contract frozen before implementation.
- [x] Party × expense matrix is the reimbursement amount truth.
- [x] Receipts are server-owned ledger transactions, not ordinary income.
- [x] Attachments, approval ceremony, formal P7 charts, and global payer master data remain excluded.
- [x] Matrix, party, receipt, source-expense, and account balances conserve under create/edit/void/restore.
- [x] Expected versus received reimbursement stays anchored to original expense; actual cash flow stays anchored to receipt time.

## Database and backend

- [x] P6 migration, deferred validators, direct-SQL defenses, downgrade guard, empty roundtrip, model drift, and offline SQL pass.
- [x] Expense/credit-purchase eligibility, partial/cross-claim capacity, P5 refund guard, and generic mutation protection pass.
- [x] Draft/pending/partial/received/cancelled states and submit/retract/cancel/reopen/void/restore/archive transitions pass.
- [x] Claim preview/replacement preserves received lower bounds and stable row identity.
- [x] Receipt preview/create/replacement/void/restore deterministically persists matrix allocations and updates both versions.
- [x] Create idempotency, operation replay, stale versions, concurrent capacity races, rollback, and stable pagination pass.
- [x] Reimbursement summary returns exact gross/expected/received/personal/outstanding semantics without ordinary-income contamination.
- [x] Ruff, Pyright, default tests, PostgreSQL 17 full suite, Alembic, and offline SQL pass.

## Apple

- [x] Exact DTO/repository/model layer supports claims, matrix rows, receipts, previews, pagination, and conflicts.
- [x] iOS More → Reimbursements provides list, detail, full edit, and quick partial receipt with one navigation stack.
- [x] macOS replaces the placeholder with modern claim cards, matrix detail, receipt history, and wide full editor.
- [x] Both platforms use real API and distinguish loading/error/conflict/archived/locked/terminal states.
- [x] Preview input changes invalidate confirmation; successful receipt refreshes claim, transactions, and account balances.
- [x] iOS remains zero native tab bars and one custom bottom bar.

## Evidence and acceptance

- [x] Real API run covers three expenses, two parties, interleaved partial receipts, edit/void/restore, and income isolation.
- [x] iOS list/detail/receipt-preview screenshots captured.
- [x] macOS matrix/editor screenshots captured at 940×700 points.
- [x] Screenshots match `design_handoff_fiscal_app` and clearly separate expected, received, and outstanding amounts.
- [ ] User accepts P6 before P7 begins.
