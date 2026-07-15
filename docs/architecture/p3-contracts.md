# Fiscal P3 Unified Ledger Contract

Date: 2026-07-15

This document freezes P3 before implementation. `PROJECT_PLAN.md` remains authoritative. P3 delivers manual income, expense, and transfer transactions on the P2 master data. Credit purchases, repayments, statement cycles, installments, reimbursements, reports, AI/OCR persistence, tags, attachments, and exports remain later phases.

## Ledger truth and money

- `Transaction` stores one business event; `Posting` stores its account impacts. Apple clients submit semantic transaction drafts and never construct postings.
- CNY is the only currency. API money is a positive signed-64-bit integer count of fen; JSON floats, booleans, zero, and out-of-range integers are rejected. A transaction mutation or opening-balance update that would push any derived account balance or summary field outside signed 64-bit range is rejected atomically with `409 derived_amount_out_of_range`; the previous ledger remains readable and unchanged.
- Posting signs express account net-value impact: income `+amount`, expense `-amount`, transfer source `-amount` and destination `+amount`. A transfer's postings sum to zero and it never contributes to income or expense totals.
- Cash/debit current balance is `opening_balance_minor + SUM(active posting amounts)`. Credit current amount owed is `opening_balance_minor - SUM(active posting amounts)`. Balances are queried from the ledger, never cached as mutable truth.
- P3 mutations accept only active cash/debit accounts. Credit account postings and their balance changes are deliberately reserved for P4, while the sign convention already supports that extension.
- `occurred_at` is an aware ISO 8601 instant stored in UTC. Grouping and inclusive business-date filters use `Asia/Shanghai`.

## Transaction shape and invariants

Kinds are `income`, `expense`, and `transfer`.

Stored transaction fields:

- `id`, `kind`, `occurred_at`, trimmed `title` (1–120), optional trimmed `note` (at most 500)
- nullable `category_id`
- `source` fixed to `manual` in P3
- unique `idempotency_key` and canonical `request_hash`
- `version`, `voided_at`, `created_at`, `updated_at`

Stored posting fields:

- `id`, `transaction_id`, `account_id`, `role` (`account`, `source`, `destination`)
- non-zero `amount_minor`, deterministic `position`
- one account and one role may occur only once per transaction

Semantic rules:

- Expense: one active cash/debit `account_id`, one active expense `category_id`, one `account` posting equal to `-amount`.
- Income: one active cash/debit `account_id`, one active income `category_id`, one `account` posting equal to `+amount`.
- Transfer: distinct active cash/debit `account_id` (source) and `destination_account_id`, no category, and exactly two equal/opposite postings.
- PostgreSQL foreign keys protect referenced master data. A deferred database constraint trigger validates the complete posting shape at commit so service bypasses cannot corrupt the ledger.
- Responses reconstruct `amount_minor` and semantic account IDs from postings and include `business_date`, postings, version, and lifecycle timestamps.

The create payload is exact and forbids extra fields:

```json
{
  "kind": "expense",
  "amount_minor": 1280,
  "occurred_at": "2026-07-15T12:00:00Z",
  "title": "午餐",
  "note": null,
  "account_id": "00000000-0000-0000-0000-000000000000",
  "destination_account_id": null,
  "category_id": "00000000-0000-0000-0000-000000000000"
}
```

`account_id` is the affected account for income/expense and the source account for a transfer. `destination_account_id` is present only for transfers. `category_id` is required only for income/expense. `source` is server-owned and is never accepted from Apple. Blank notes normalize to `null`. Active root and child categories are both valid.

## Complete editing, void, restore, and audit

- Update is a full semantic replacement with `expected_version`; it may change kind, amount, accounts, category, time, title, and note atomically. The service validates the new shape, replaces postings, increments the version, and all derived balances immediately reflect the new impacts.
- A transaction that already references an archived account/category may retain that exact reference during an edit. A newly selected or changed reference must be active. Voided transactions cannot be edited until restored.
- Delete is represented by `POST /transactions/{id}/void`, not hard deletion. It sets `voided_at`, increments the version, preserves postings and references, and immediately removes the postings from balances and lists by default.
- `POST /transactions/{id}/restore` with the current expected version clears `voided_at`. Restore requires the original references to still exist and the stored transaction/posting shape to remain valid, but permits those references to be archived. Restore is not time-limited; the UI may expose a short-lived immediate Undo affordance without weakening server recoverability.
- `transaction_revisions` stores the canonical result snapshot for `created`, `updated`, `voided`, and `restored`, unique by transaction/version. This is internal correctness tracking, not a user-facing version-history product.
- Active + current-version void and voided + current-version restore increment the version once. Repeating void on an already voided transaction, or restore on an already active transaction, returns the current object without a new version/revision. An old expected version always returns `resource_version_conflict`.

## Idempotency and concurrency

- `POST /transactions` requires an `Idempotency-Key` UUID header. The server canonicalizes the semantic request and hashes it.
- Repeating the same key with the same request returns the immutable created-revision v1 response with `201`, even if the live transaction was later edited or voided, without changing postings, balances, versions, revisions, or usage counts. Keys do not expire in P3. Reusing the key with different content returns `409 idempotency_key_reused`.
- Apple retains a create key across ambiguous transport failures and generates a new key only after a terminal response or an intentional fresh draft.
- Every P2/P3 mutation uses the same PostgreSQL transaction-scoped advisory lock. Transaction rows additionally use optimistic versions and row locks. Unique constraints remain the final race defense.

## Master-data integration

- `usage_count` counts canonical transaction references, including voided transactions, because their foreign keys and restore capability remain live. Complete edits update counts by old/new reference-set delta.
- Used accounts cannot change kind. Used categories cannot change direction. Deletes remain forbidden while usage is non-zero, with foreign-key failures mapped to the existing stable domain errors.
- Category merge reassigns transaction references in the same shared lock/transaction before archiving the source. Root merges also map references from an archived same-name source child to the matching target child; moved children retain their IDs. Usage counts are recomputed or adjusted transactionally.
- Account responses add required `current_balance_minor`, derived from active postings. P2 opening balances remain unchanged.

## API

All routes are under `/api/v1`, device-token protected, and use the existing error envelope.

- `GET /transactions?cursor=&limit=50&kind=&account_id=&category_id=&date_from=&date_to=&query=&include_voided=false`
- `POST /transactions` with required `Idempotency-Key` → `201` on first creation, `200` replay is acceptable if the same canonical object is returned
- `GET /transactions/{id}`
- `PUT /transactions/{id}` with a complete draft plus `expected_version`
- `POST /transactions/{id}/void` with `{ "expected_version": integer }`
- `POST /transactions/{id}/restore` with `{ "expected_version": integer }`
- `GET /transactions/summary?date_from=&date_to=`

List order is `occurred_at DESC, id DESC`. The response is `{ "items": [...], "next_cursor": string | null }`; cursor contents are opaque and pagination must not duplicate rows while the underlying dataset is unchanged. Filters combine with AND. `account_id` matches any posting, `category_id` matches the transaction, date bounds are inclusive Shanghai business dates, and case-insensitive query searches title and note.

Summary returns active income, active expense, `net_minor = income_minor - expense_minor`, and `by_category` amounts for an inclusive Shanghai business-date range. Transfers and voided transactions are excluded; merged references use their current target category.

Stable P3 errors:

- `transaction_not_found`, `transaction_voided`
- `invalid_transaction_configuration`, `transfer_same_account`
- `account_archived`, `category_archived`, `category_direction_mismatch`
- `idempotency_key_reused`, `resource_version_conflict`
- Existing account/category not-found, in-use, validation, authentication, and request-ID behavior remains unchanged.

## Apple client and UX

- Shared DTOs are `Codable`, `Sendable`, and integer-money only. Repositories are actors; page/editor models are `@MainActor @Observable` and use Swift concurrency cancellation correctly.
- iOS keeps the existing explicit content switch and one custom glass bottom bar. No `TabView`, native tab bar, or second navigation layer is introduced. The center FAB opens a native record sheet with only expense/income/transfer.
- iOS transactions show search, filter chips, Shanghai-day groups, pull-to-refresh, empty/no-result/error states, editing, void confirmation, immediate Undo, and explicit optimistic-conflict recovery.
- macOS shows a dense selectable transaction table with filters/search and an approximately 256-point right Inspector. The Inspector displays semantic fields and read-only “账户影响” rows such as `招行储蓄卡 −¥12.80`, never accounting jargon, and provides edit/void actions; `Command-N` opens creation.
- Both editors hide category for transfers, require the correct category for income/expense, prevent same-account transfers, preserve the idempotency key while retrying, and never fall back to preview fixtures.
- If existing data loaded successfully, a later refresh error preserves it and shows a non-destructive banner. Cancelled tasks return to a retryable state rather than being reported as offline.

## Completion evidence

- Empty PostgreSQL migration, harmless second upgrade, model-drift check, offline SQL, formatting, lint, typing, unit tests, and real PostgreSQL integration all pass.
- Tests cover strict money, aware dates, all three shapes, balance and category-summary derivation, full edits, repeat-safe void/restore, immutable-v1 idempotent replay/conflict/concurrency, stale versions, filters/cursors, archived references, P2 safe delete and category merge reassignment, and direct-SQL trigger rejection.
- iOS and macOS create, list, search/filter, edit, void, and restore against the real API. iOS automated evidence asserts zero native tab bars and exactly one custom bottom bar.
- Visual evidence covers iPhone list/record/edit/error states and macOS 940×700 table/Inspector/editor without clipping.
