# P33 Credit Schedule Change — Build Evidence

Date: 2026-08-14 (Asia/Shanghai)
Scope: P33 credit-account billing-cycle / due-date preview → commit contract only.

## Delivered contract

- `POST /credit-accounts/{id}/schedule-change-preview` creates a 30-minute operational token. It reports changed open cycles, old/new due dates, remaining amounts, cycle/account expected versions, warnings and permitted next actions.
- `POST /credit-accounts/{id}/schedule-change` requires the exact preview token/input plus `Idempotency-Key`. It acquires the shared mutation lock, re-reads the complete affected dependency set, returns a stable 409 with no write if stale, and commits account/cycle/transaction/installment changes plus the replay receipt atomically.
- A successful formal commit advances `data_revision` exactly once and returns it in the receipt. Same key/same request replays the receipt; same key/different request returns `idempotency_key_reused`.
- A used credit account can no longer change billing fields through the generic account PATCH path. It returns `credit_schedule_preview_required` with the preview/commit routes.
- Preview/operation records are excluded from Archive. They are operational controls, never portable financial facts.

## Automated verification

| Command | Result |
| --- | --- |
| `uv run ruff check …P33 credit files…` | passed |
| `uv run ruff format --check …P33 credit files…` | passed |
| `uv run pyright` | `0 errors, 0 warnings` |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p33_credit_20260814 uv run pytest -q tests/test_p33_credit_schedule_postgres.py tests/test_p4_postgres.py tests/test_p17_postgres.py tests/test_p21_api_postgres.py tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py` | `36 passed`; only upstream TestClient deprecation warning |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p33_credit_20260814 uv run alembic downgrade 20260814_0031 && … upgrade head` then the same targeted pytest | 0032 and 0033 downgrade/re-upgrade passed; `36 passed` |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p33_credit_20260814 uv run pytest -q` | credit tests passed, but whole suite has one reproducible external P30C failure: an account POST returns 201 then its immediate expense POST receives `account_not_found` in `test_p30c_uncategorized_candidate_and_draft_diagnostics`; three initially cached security nodes pass in isolation |

The fresh-PostgreSQL P33 test covers preview no-revision behavior, Archive exclusion, atomic commit, response-unknown replay, idempotency collision, stale zero-write behavior, generic-PATCH bypass rejection, two independent preview snapshots, settled/repayment history, Asia/Shanghai short-month and cross-year calendar edges.

## Second independent-review repairs

- A due-day-only commit now updates the existing open cycle's visible dates and monotonic `updated_at` in the same transaction, while retaining its immutable cycle version. The regression asserts preview → commit → GET cycle and a single correct future event.
- `ReconciliationCheckpoint` is now a first-class schedule-preview dependency and a reference that preserves an old historical cycle. A checkpoint created after preview invalidates commit with stable `credit_schedule_preview_stale` and zero formal writes; an existing checkpoint prevents deletion without leaving a future-event ghost.
- Commit receipts freeze the old schedule before mutation, so both first response and idempotent replay have accurate old/new billing fields.
- The P4 regression now asserts the preview-required generic PATCH rejection for used credit accounts, then proves the supported preview → commit migration path.

## Cross-workstream status

The combined P22 Archive PostgreSQL suite now passes (`10 passed` inside the 36-test matrix); the earlier reimbursement Archive exclusion issue is resolved in its owning workstream. This credit QA record remains limited to the credit/account contract.

## Third independent-review repairs

- Preview and commit now share a per-source remap plan. Credit purchases are grouped by their actual Asia/Shanghai business date under the proposed schedule, so the accepted preview, receipt and materialized cycle/future event use the same target dates.
- A source cycle that splits across target cycles may move independent purchases separately. If it also contains a repayment, installment reference or other source that cannot be allocated uniquely, preview returns stable `credit_schedule_ambiguous_remap`; commit rejects it before revision or formal writes.
- `ReconciliationService.create()` acquires the same transaction-scoped advisory lock before validating its cycle target. The dual-session regression covers the two valid serial outcomes: checkpoint first makes schedule commit stale; schedule first removes the old unreferenced cycle and checkpoint creation receives stable not-found, never an FK 500 or partial schedule write.
- Regressions cover both cutoff directions, multiple purchases, repayment ambiguity, checkpoint concurrency, and short-month/cross-year date calculations.

## Fourth independent-review repairs

- A checkpoint on a source cycle that would split across multiple targets is now an explicit `credit_schedule_ambiguous_remap` blocker, like repayments and installment obligations. Preview remains operational; commit returns 409 before any revision or formal write.
- The cycle-reference audit found all model-level `ON DELETE RESTRICT` FKs into `credit_cycles`: transactions, installment plans/periods, reconciliation checkpoints, `AIProposal.credit_cycle_id`, and `StatementImportRow.credit_cycle_id_candidate`. The latter two are operational/candidate references: schedule changes preserve the old cycle and never silently rewrite them. Both are also part of the preview dependency snapshot, so newly created or changed references invalidate a pending preview with stable zero-write stale behavior.
- Fresh PostgreSQL validation after 0031 → head migration: P8, P24, P26–P28, P22 and P33 matrix `58 passed` (only upstream TestClient deprecation warning). Ruff, format and Pyright (`0 errors`) pass.

## Fifth independent-review repairs

- All schedule-preview dependency queries now have explicit stable ordering: transactions by parent cycle/business timestamp/id; installment periods by scheduled/effective cycle, plan, sequence and id; plans by start cycle, creation time and id. Checkpoints, AI proposals and statement-import candidates were already explicitly ordered. The regression creates multiple purchases, plans and periods in reverse source order, then preview/commits through separate request sessions without a false stale conflict; actual dependency changes remain stale.
- `StatementImportRow.credit_cycle_id_candidate` is now covered by a direct constructed-row regression: an existing candidate preserves the old cycle without an FK failure or future-event ghost, while a candidate created after preview produces stable `credit_schedule_preview_stale` and zero formal writes.
- Fresh PostgreSQL P24/P33/P22 matrix: `29 passed` (only upstream TestClient/Pydantic deprecation warnings). Ruff, format and Pyright (`0 errors`) pass.

## Independent-review closure — Verified

| Round | Finding / resolution |
| --- | --- |
| 1 | Established the preview-token + idempotent atomic-commit baseline: used account PATCH is rejected, preview is operational-only, commit is replayable and formal revision advances once. |
| 2 | Fixed same-period due-day updates, checkpoint FK preservation/staleness, receipt old-value capture, and the obsolete P4 direct-PATCH expectation. |
| 3 | Unified per-source remap planning between preview and commit; defined split conservation blocking; serialized checkpoint creation with the shared mutation lock. |
| 4 | Made split cycles with checkpoints explicitly ambiguous; audited and protected AI-proposal and statement-import candidate RESTRICT references. |
| 5 | Stabilized every dependency-query order and completed direct statement-import candidate preserve/stale coverage. |

Final independent review: **0 findings — Verified**. The reviewer confirmed the five remediation rounds remain coherent with the credit schedule preview → commit contract.

## Residual risk

- The credit/account scope has no known unresolved correctness finding. The retained conservative policy intentionally blocks split remaps that contain a repayment, installment obligation or checkpoint rather than inventing an allocation.
- The full Backend suite still has the separately reported P30C account visibility failure (`account_not_found` immediately after a 201 account create). It is outside this credit implementation and did not affect the credit targeted/migration matrices.
