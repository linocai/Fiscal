# Fiscal P10 Contracts

Date: 2026-07-16

Status: implemented; frozen contract retained for acceptance

## Scope

P10 turns the existing vertical slices into a finished daily-use product. It may improve navigation, editing, search, accessibility, responsive layout and local read performance, but it must not change the accounting semantics frozen in P3–P9 or absorb P11 production-security work.

## Uncategorized inbox and batch classification

- An inbox item is a non-voided ledger transaction whose `category_id` is null and whose kind is `expense`, `income`, or `credit_purchase`.
- System ledger rows, transfers, repayments, installment relations, reimbursement receipts and voided rows are never batch-classifiable.
- The transaction list API gains an explicit classification filter (`all`, `categorized`, `uncategorized`); null is never overloaded onto the existing `category_id` query.
- Batch classification accepts 1–100 distinct `{transaction_id, expected_version}` items plus one active leaf category.
- The server locks every target in deterministic ID order, validates the complete set, and commits atomically. Any missing, changed, ineligible, voided, related, wrong-direction or archived target rejects the whole operation.
- Each changed transaction gets a normal `updated` revision and increments its version exactly once. Category usage counts and all reports remain derived from the canonical ledger.

## Search and advanced filters

- P10 global search is ledger-global, not a speculative cross-module search engine: it searches transaction title, note, account and category across the whole ledger and routes to the existing transaction inspector/editor.
- Advanced transaction filters are kind, account, category, classification, source, date range and voided state. Multiple filters combine with AND.
- Every cursor is bound to a stable fingerprint of its filters. Reusing a cursor under another filter set returns a stable client error rather than silently skipping or duplicating rows.
- Search is debounced; a changed query cancels prior work. Pagination rejects duplicate concurrent loads and removes duplicate IDs defensively.

## Recording preferences

- Default account, default type (`expense` or `income`) and “stay after save” are non-sensitive device-local preferences. They use `UserDefaults`/`AppStorage`, not the VPS database.
- A stored default account is applied only when it still exists, is active and is valid for the selected type. Invalid defaults are ignored and cleared without inventing another account.
- Preferences affect new manual entries only. Editing an existing transaction never applies defaults and always closes after a successful save.
- “Stay after save” resets the editor to a clean draft, preserves the chosen type/default account, and rotates the idempotency key before another submission.

## UI and accessibility

- iOS keeps exactly one custom bottom bar and list-first, chart-free information architecture. The root owns the bottom safe-area inset; child screens do not guess around the bar with new magic padding.
- Default `Form` is not the P10 visual language. High-use editors use Fiscal cards, explicit sections, a visible primary action and server-backed impact confirmation where derived financial effects can change.
- macOS keeps a dense table plus Inspector, adds multi-selection/batch classification, keyboard shortcuts and adaptive inspector width without turning into enlarged iOS cards.
- Dynamic Type, VoiceOver and Reduce Motion are product behavior, not screenshot-only variants. Decorative symbols are hidden from accessibility, selectable navigation exposes selected state, and motion is removed when requested.
- P10 adopts a semantic light/dark palette across shared surfaces. No view may force light mode after the palette lands; both platforms require light and dark evidence.

## Cache and offline boundary

- VPS data remains the truth. P10 permits a short in-memory cache only for read-only GET responses, with a maximum 30-second TTL and explicit mutation invalidation.
- Concurrent identical GETs are coalesced. Cancellation of one observer must not publish stale data over a newer query.
- No offline financial mutation queue or silent local draft submission is introduced. A valid live short-cache response remains read-only; after expiry, already-loaded screen data may stay visible beside an explicit refresh error, but stale cache is never presented as current. Settings reports the actual age of cached responses while they exist.
- “Clear local cache” clears only the in-memory response cache and reports the actual result; it does not delete Keychain credentials or server data.

## Export decision gate

- P10 implements only UTF-8 CSV transaction export because it is the smallest useful, inspectable portability surface.
- JSON export is deferred: it would become a backup/restore contract and belongs with P11/P12 recovery and migration work.
- PDF export is deferred: statement layout, pagination and accounting-period semantics require a separate product contract.
- CSV uses the active advanced filters, exports canonical server values, escapes spreadsheet formulas, includes an explicit schema/version header, and never writes secrets.

## P11 boundaries

- No logout, fake end-to-end encryption, fake backup state, token rotation or production VPS administration is added in P10.
- Settings may explain that device-key lifecycle and backup arrive in P11, but must not expose controls that pretend those operations already work.
