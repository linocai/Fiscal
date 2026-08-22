# P33 Core — Verified

## Scope

- Future-event timeline: bounded repository merge for the three permitted
  sources (credit cycles, expected/confirmed cash-flow items, submitted
  reimbursement parties), Asia/Shanghai 7/30/60/90-day windows, optional
  account filter, canonical same-day keyset ordering, and revision-bound
  reload conflicts.
- Explicit installment `completed` lifecycle: migration 0031, write-boundary
  refresh after ledger mutations, revision snapshots, API/list compatibility,
  and archive serialization.
- Statement-provider contract: provider-attempt responses explicitly declare
  `execution_scope=request_bound`; cancellation remains a failed attempt, not
  a detached continuation.

## Decisions and invariants

- Future timeline does not call `debt()` or construct a facts snapshot. Each
  source query is window/filter/keyset constrained and `LIMIT limit + 1`; the
  credit query calculates and filters its outstanding amount in SQL so a run
  of already-settled cycles cannot hide a later event. UUID tie-breaking is
  cast to the same text representation used by the opaque cursor, preventing
  PostgreSQL UUID order from diverging from response order.
- Transfers remain excluded from combined-cash future facts. Existing ledger
  writes replace realized future candidates; expected reimbursements remain
  separate inflows and never net against confirmed outflows.
- Cursor decoding validates envelope version, read scope, date/window,
  direction/source compatibility, and UUID key before revision comparison.
  Invalid/tampered cursors are 422; an otherwise valid stale cursor is 409
  `future_events_scope_changed` with `safe_to_reload` and reload path.
- `completed` is stored only when all non-cancelled periods resolve to settled
  credit cycles. Voiding/rebinding a repayment legally reopens it to
  `active`/`partially_cancelled`, increments plan version, and records a
  `reopened` plan revision; cash amounts and periods are not rewritten.
- Second-review P1 correction: reimbursement allocations and non-void receipt
  allocations now aggregate in separate claim/party SQL subqueries before the
  outer keyset query calculates outstanding. This prevents a one-to-many
  receipt join from multiplying an allocation's claimed amount. Both subtotal
  inputs and the difference are checked as Int64; zero or negative results are
  excluded before the event response.
- Third-review P2 correction: a `future_reimbursement_candidates` CTE applies
  claim lifecycle, party window and the canonical global cursor predicate
  before either allocation aggregate starts. Both allocation and non-void
  receipt subqueries join that CTE by `(claim_id, party_id)`; the outer query
  retains positive-outstanding filtering, exact party sort key and
  `LIMIT limit + 1`. Thus a window/cursor exclusion cannot produce a later
  duplicate or skipped candidate while historical allocation tables grow.
  Account-scoped timelines explicitly return no reimbursement candidates
  before aggregate construction because parties have no account identity.

## Verification

- Core lint, formatting and types:
  `uv run ruff check <core files>`; `uv run ruff format --check <core files>`;
  `uv run pyright src` — passed (0 Pyright errors/warnings).
- Focused PostgreSQL regressions:
  `tests/test_p5_postgres.py tests/test_p7_schemas.py
  tests/test_p26_statement_provider_postgres.py` — **27 passed** (one existing
  Starlette TestClient deprecation warning).
- Core/broader PostgreSQL regression set (P5/P7/P17/P22/P26/P31/P33) —
  **123 passed** (one existing Starlette TestClient deprecation warning).
- Migration chain:
  `alembic downgrade 20260814_0030 && alembic upgrade head && alembic current`
  on disposable `fiscal_p33_build` — passed; downgrade traversed
  `0033 → 0032 → 0031 → 0030`, re-upgrade ended at `20260814_0033 (head)`.
- Second-review fresh PostgreSQL regression:
  `tests/test_p7_postgres.py tests/test_p7_api_postgres.py
  tests/test_p7_schemas.py tests/test_p22_archive_revision_postgres.py` —
  **67 passed** on newly created/migrated `fiscal_p33_core_review` (dropped
  after verification; one existing Starlette TestClient deprecation warning).
  The new case uses two receipts against the same allocation, a second
  allocation for that party, a separate party, and a voided receipt; it proves
  page-to-page conservation (5,000 + 4,000 = 9,000), zero-outstanding
  exclusion, the unchanged facts reimbursement total, and a bounded SQL page
  (`LIMIT 2`, no per-row query growth).
- Third-review fresh PostgreSQL regression: the same P7/P22 focused set ran
  **67 passed** on newly created/migrated `fiscal_p33_core_review_3` and again
  after the explicit account-scope guard on `fiscal_p33_core_review_4` (both
  dropped after verification). The reimbursement test now inserts 80 submitted,
  receipt-bearing parties outside the requested window. It confirms the two
  in-window pages still conserve 5,000 + 4,000 = 9,000; facts retains its
  pre-noise 9,000 reimbursement total; and captured SQL declares the candidate
  CTE before the aggregation subqueries and joins it twice, once per aggregate.

## Independent review record

- Round 1 identified the original Core concerns: query-level future-event
  keyset bounds, revision-safe cursors, persisted `completed` lifecycle, and
  strict cursor-key validation. The implementation and focused P5/P7/P17/P22
  regressions above closed those findings.
- Round 2 raised P1: the reimbursement receipt join multiplied allocation
  totals for multiple receipts against one allocation. It was fixed with
  independent allocation/receipt aggregates and the 5,000 + 4,000 conservation
  regression.
- Round 3 raised P2: those correct aggregates still scanned non-candidate
  history. It was fixed with the candidate CTE and the 80 historical
  allocation/receipt noise probe.
- Round 4 Independent Review: **0 findings**. Core is **Verified**.

## Residual integration risk

- The earlier full `pytest -q` and workspace-wide `ruff check src tests` were
  blocked by concurrent credit-schedule edits in `services/credit.py`; Core
  intentionally did not modify that unrelated work. The final P33 integrator
  must rerun those whole-worktree gates once all parallel blocks are settled.
- This verification covers P33 Core only. Credit schedule and reimbursement
  preview/commit blocks retain their own QA records and final integration
  responsibility.
