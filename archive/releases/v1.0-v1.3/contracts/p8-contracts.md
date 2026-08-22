# Fiscal P8 Contract

Date: 2026-07-16

`PROJECT_PLAN.md` remains authoritative. P8 adds one server-owned AI proposal pipeline for text input. AI is an untrusted parser, never a ledger writer. P9 owns Vision OCR, Shortcuts, Back Tap, notifications, and notification undo.

## Invariants

- The provider receives only the source text, Asia/Shanghai date context, and active account/category candidates needed for matching. It has no database session, tools, balances, transaction history, or write capability.
- Provider output is parsed through a strict schema with extra fields forbidden. Currency is always CNY; money is integer minor units; confidence is integer basis points from 0 through 10,000.
- Only stable IDs already present in the supplied candidate lists may survive normalization. Invented, archived, wrong-kind, or wrong-direction references never reach automatic execution.
- Every confirmed or automatic write calls the existing `TransactionService`; AI never duplicates posting, balance, credit-cycle, category-usage, revision, limit, or chronological validation.
- AI-created ledger rows use the trusted internal source `ai_text`. Public transaction requests cannot choose a source. `ai_text` rows are ordinary user records after creation and remain editable, voidable, and restorable; `system` rows remain protected.
- Provider URL, model, and API key can be configured from Settings on any active authenticated device. The API key is encrypted with AES-GCM before database storage, is never returned to clients or persisted in proposal payloads, and is never included in logs/errors. Environment configuration remains a backward-compatible fallback until an in-app configuration is saved.

## Provider Boundary

`AIProvider` is an async protocol accepting a bounded `AIParseRequest` and returning `AIProviderResult`. P8 provides a disabled adapter and one OpenAI-compatible JSON adapter. Tests inject a deterministic fake provider; no test performs a real model request.

Provider input is limited to 2,000 Unicode characters after rejecting NUL/control characters. HTTP timeout and response-size limits are mandatory. The settings endpoint validates an absolute URL without embedded credentials, queries, or fragments; production configuration requires HTTPS. A disabled or incomplete provider does not block API startup or existing proposal/settings reads.

Stable errors:

- `ai_provider_not_configured` (503)
- `ai_provider_unavailable` (503) for timeout, cancellation-safe upstream failure, 429, or 5xx
- `ai_provider_invalid_response` (422) for malformed/non-JSON/extra-field/unknown-enum output

Upstream response bodies, authorization headers, chain-of-thought, and raw prompts are never surfaced. A failed parse stores only a stable error code and safe short message.

## Proposal Shape And State

`ai_proposals` stores:

- identity and audit: UUID, source (`text` in P8), bounded raw input, SHA-256 content fingerprint, unique create idempotency UUID/request hash, provider/model identifiers;
- normalized optional draft fields: kind, amount minor, occurred-at, title, note, account/category/destination IDs, and repayment credit-cycle ID;
- evidence: per-field confidence basis points, overall confidence basis points, missing fields, deterministic server reason codes, explanation;
- lifecycle: status, optimistic version, optional unique linked transaction ID/version, and timestamps.

The fingerprint is SHA-256 over a versioned, NFKC-normalized source payload. It is indexed but never unique: two real purchases with the same text are valid. Mechanical retry safety comes from the required `Idempotency-Key` plus canonical request hash.

State machine:

```text
processing -> pending | executed (automatic) | failed
failed     -> processing (explicit retry)
pending    -> pending (complete edit) | executed (confirm) | ignored
executed   -> undone
ignored / undone are terminal
```

Every mutation uses a row lock and `expected_version`. Concurrent edit/execute/ignore/retry/undo races produce one winner and stable `409` conflicts. Provider HTTP calls occur outside database/advisory-lock transactions.

Editing is a complete replacement using the existing `TransactionDraft` shape. The wire request is exactly `{draft, expected_version}`; draft nesting is not flattened into the mutation envelope. Repayment drafts may carry `credit_cycle_id`, chosen from real open cycles, so execution can close or reduce the same formal cycle as a manual repayment. A user-edited proposal stays pending and never silently auto-executes. Ignore never creates a transaction. Undo uses the formal transaction void service and never deletes a ledger row; repeated undo returns the same result without a second revision. Later manual restore is normal ledger behavior and does not change the terminal proposal state.

## Deterministic Automatic Execution

The provider's risk label is non-authoritative. The server is the only safety assessor.

Automatic execution requires all of the following:

- user setting `auto_execute_enabled` is true and the provider is configured;
- kind is exactly ordinary `income` or `expense`;
- amount is at most `min(user limit, 100_000 minor units)`; ¥1,000.00 is allowed and ¥1,000.01 is not;
- overall confidence and every required field confidence are at least `max(user threshold, 9_000 bps)`;
- title, amount, occurred-at, account, and direction-compatible category are complete; destination is absent;
- account/category are active and correct for the draft; all formal `TransactionService` validation passes;
- deterministic reason codes contain no blocker.

Transfer, credit purchase, repayment, installment, reimbursement, system kinds, ambiguous/missing IDs, and any provider-invalid value always require review or fail. Requests cannot carry temporary thresholds, risk overrides, provider URLs, or model names. Client settings can only tighten the server policy.

## Behavior Settings

`ai_settings` is a seeded singleton and the VPS database is its truth source:

- `auto_execute_enabled`, default false;
- `auto_execute_limit_minor`, default/max 100,000 and minimum 1;
- `minimum_confidence_bps`, default/minimum 9,000 and maximum 10,000;
- optimistic version and timestamps.

The response also exposes `provider_configured` and `effective_auto_execute`; it never exposes secrets. Update rejects values outside the server-safe range rather than silently accepting a weaker policy.

## API

Every route except health requires the existing device token.

- `GET /api/v1/ai/settings`
- `PUT /api/v1/ai/settings` — complete behavior settings plus `expected_version`
- `POST /api/v1/ai/proposals` — `{source:"text", text}` plus required `Idempotency-Key`; first response 201, exact replay 200
- `GET /api/v1/ai/proposals?status=&cursor=&limit=` — stable newest-first cursor page with authoritative `pending_count`
- `GET /api/v1/ai/proposals/{id}`
- `PUT /api/v1/ai/proposals/{id}` — `{draft: <complete TransactionDraft>, expected_version}`
- `POST /api/v1/ai/proposals/{id}/execute`
- `POST /api/v1/ai/proposals/{id}/ignore`
- `POST /api/v1/ai/proposals/{id}/retry`
- `POST /api/v1/ai/proposals/{id}/undo`

Execute and automatic execution derive a stable transaction idempotency UUID from the proposal UUID. Proposal link and ledger creation commit in one unit of work; retries recover the same transaction and never create a second created revision.

## Database Migration

P8 migration `0007` creates `ai_settings` and `ai_proposals`, indexes pending timeline/fingerprint, expands transaction source to `manual|system|ai_text`, and updates the current transaction-shape/installment validators so normal user kinds accept `manual|ai_text` while server-owned kinds still require `system`.

Downgrade is blocked while an AI proposal or `ai_text` transaction exists. Empty-data downgrade restores the exact P6/P5 constraints.

## Apple Contract

- One shared `AIProposalModel` supplies queue state and authoritative `pendingCount` to iOS overview, iOS More, and macOS sidebar. No badge is hard-coded or inferred from one page of results.
- iOS production overview gains the AI badge; `更多` gains AI Pending and a real Settings destination. iOS proposal/settings screens are compact lists with no charts and no default `Form`/legacy button styling.
- macOS replaces AI/Settings placeholders with a dense queue + inspector and a polished settings column.
- P8 Settings exposes only AI automatic-execution behavior. OCR/Shortcuts toggles remain P9. End-to-end-encryption and logout controls do not exist.
- Execute/undo refresh transactions and reports. An AI transaction appears in the normal ledger and supports the same editor/void flow as a manual transaction.

## Required Verification

- Provider tests cover disabled, timeout/429/5xx, malformed JSON, extra fields, float/overflow money, prompt injection, unknown IDs, response bounds, and secret non-disclosure.
- Policy tests cover ¥999.99/¥1,000/¥1,000.01, 8,999/9,000/9,001 bps, each required-field confidence, active/direction references, user tightening, and forbidden kinds.
- PostgreSQL tests cover parse/edit/execute/ignore/retry/undo, exact ledger effects, ordinary post-AI editing, idempotency, optimistic concurrency, double execution, migration/validator behavior, and no side effects on failure.
- Apple tests cover strict DTOs, stale response rejection, ambiguous-failure idempotency retention, dynamic badges, real settings persistence, execute-to-ledger refresh, and one iOS custom bottom bar.
- Authenticated real-API screenshots cover iOS overview badge, pending list/editor/settings and macOS pending inspector/settings before P8 acceptance.
