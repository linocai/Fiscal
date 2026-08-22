# P33-B · Reimbursement preview-token binding

Date: 2026-08-14 (Asia/Shanghai)
Status: Verified — third independent review returned 0 findings.

Changed files:

- `Backend/src/fiscal_api/services/reimbursements.py`
- `Backend/tests/test_p6_postgres.py`
- `archive/releases/v1.5.0/qa/p33/p33-reimbursement-results.md`

## Delivered contract

- Only the four pre-existing financial preview paths are token-bound: claim replacement, cancellation of outstanding amount, receipt creation, and receipt replacement.
- Each preview persists a 30-minute server-side session containing its operation kind, exact input digest, full claim/receipt/allocation dependency snapshot and pre-mutation versions. It emits no formal revision and is excluded from Archive.
- A formal HTTP commit now requires the matching token and `Idempotency-Key`. Under the global mutation lock it rechecks exact input, claim/receipt/allocation dependencies and normal domain validation; a token is single-use except for replay of the same idempotency receipt.
- Receipt previews expose before/after claim amounts and status plus the actual allocation matrix used by the later commit. All values remain minor-unit integers.
- Each previewed receipt-allocation row receives a planned UUID stored inside the server-side preview session. Commit uses those exact IDs, and an idempotency replay returns the same receipt/matrix identity; no preview response advertises a randomly generated ID.
- Formal `reimbursement_operations` remain archivable, but their short-lived `preview_id` is deliberately exported as `null`; this preserves recoverable receipts without restoring a spent token.

## Independent review chain

| Round | Findings | Resolution |
| --- | --- | --- |
| 1 | P2 × 2 | Shared claim-matrix validation now gives preview and commit identical rejection semantics; receipt allocation IDs are planned, persisted in the preview session, and reused by commit/replay. |
| 2 | P2 × 1 | Preview sessions now snapshot their validated external source/account dependencies and reject changes as `reimbursement_preview_stale` before token consumption. |
| 3 | 0 | Independent review found no remaining issue. P33-B is verified. |

## Verification

Temporary fresh PostgreSQL database, created solely for this check and removed after it:

```text
FISCAL_DATABASE_URL=postgresql+asyncpg://linotsai@localhost:5432/<temporary-db> \
FISCAL_TEST_DATABASE_URL=... uv run alembic upgrade head
uv run alembic downgrade 20260814_0032
uv run alembic upgrade head
uv run pytest -q tests/test_p6_postgres.py tests/test_p6_api_postgres.py \
  tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py \
  tests/test_p31_api_postgres.py
# 38 passed, 1 upstream TestClient deprecation warning
```

```text
cd Backend
uv run ruff check src/fiscal_api/api/p6_schemas.py src/fiscal_api/api/routes/reimbursements.py src/fiscal_api/services/reimbursements.py src/fiscal_api/db/models/reimbursement.py src/fiscal_api/db/models/__init__.py src/fiscal_api/services/archive.py alembic/versions/20260814_0033_p33_reimbursement_preview_sessions.py tests/test_p6_postgres.py tests/test_p6_api_postgres.py tests/test_p22_archive_revision_postgres.py
uv run ruff format --check src/fiscal_api/api/p6_schemas.py src/fiscal_api/api/routes/reimbursements.py src/fiscal_api/services/reimbursements.py src/fiscal_api/db/models/reimbursement.py src/fiscal_api/db/models/__init__.py src/fiscal_api/services/archive.py alembic/versions/20260814_0033_p33_reimbursement_preview_sessions.py tests/test_p6_postgres.py tests/test_p6_api_postgres.py tests/test_p22_archive_revision_postgres.py
uv run pyright src/fiscal_api/api/p6_schemas.py src/fiscal_api/api/routes/reimbursements.py src/fiscal_api/services/reimbursements.py src/fiscal_api/db/models/reimbursement.py src/fiscal_api/services/archive.py
# all passed; 0 pyright errors/warnings
```

Targeted coverage includes normal preview→commit, response-unknown replay, changed payload, cross-operation token, consumed token, expired token, two concurrent preview sessions, receipt allocation order, all relevant claim lifecycle transitions, Archive omission and fresh restore.

## Integration-test migration

- The P30-C replacement-claim duplicate-transaction check now calls the formal preview endpoint. It asserts the stable `reimbursement_duplicate_transaction` structured field path, no preview token, unchanged claim version/total, and unchanged global data revision. This is a test-contract migration only; no runtime code changed. Existing P6 coverage remains the successful legal preview→commit evidence.
- Fresh PostgreSQL verification of P6, P30-C, and the revision route matrix passed: 31 tests, with one upstream `TestClient` deprecation warning.

## First-round remediation (P2 × 2)

- Claim replacement preview and commit now use equivalent matrix rules, including lifecycle, cancellation identity, received allocation and existing-receipt party-removal constraints; preview cannot succeed where the matching commit would return a locked or cancelled error.
- Receipt previews no longer expose throwaway allocation row IDs: planned IDs are bound to the token session and used unchanged for commit and idempotency replay.

## Second-round remediation (P2 × 2)

- Claim replacement preview and commit now share a side-effect-free matrix validator. It covers archived/voided claims, cancelled matrix identity, received-allocation identity/minimum/removal locks, and parties referenced by any existing receipt. Invalid preview and direct commit return the same stable code and leave the claim byte-for-byte unchanged.
- Receipt preview planned allocation IDs are persisted in the preview payload and are used by create/replace commit. Tests assert preview→commit identity equality, idempotent replay equality, stale/expired rejection, and Archive's deliberate omission of the operational session.

Second-round fresh-PG verification:

```text
uv run ruff check <P33 reimbursement files>
uv run ruff format --check <P33 reimbursement files>
uv run pyright <P33 reimbursement files>
# all passed; 0 pyright errors/warnings

FISCAL_DATABASE_URL=postgresql+asyncpg://linotsai@localhost:5432/<temporary-db> \
FISCAL_TEST_DATABASE_URL=... uv run alembic downgrade 20260814_0032
FISCAL_DATABASE_URL=... uv run alembic upgrade head
FISCAL_DATABASE_URL=... FISCAL_TEST_DATABASE_URL=... uv run pytest -q \
  tests/test_p6_postgres.py tests/test_p6_api_postgres.py \
  tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py \
  tests/test_p31_api_postgres.py
# 39 passed, 1 upstream TestClient deprecation warning
```

The randomly named verification database was dropped after the checks; no existing Fiscal database was used.

## Third-round remediation (P2 × 1)

- Claim-replacement previews now persist only the external facts they actually validate: every source transaction's kind/void state, postings, derived reimbursable capacity and allocation held by other claims. Consumption recomputes the same per-source snapshot, so an outside claim's allocation/release or a source-capacity change becomes `reimbursement_preview_stale` without using the token.
- Receipt create/replace previews persist the destination account's ID, kind, archive state and resource version. Any account mutation after preview returns the same stale code before token consumption or formal receipt creation.
- These checks are narrow rather than global-revision based: an unrelated account write leaves a claim preview usable. Idempotency replay remains first, so response-unknown retries return the existing receipt even after its one-time preview session is consumed.

Third-round fresh-PG verification:

```text
cd Backend
uv run ruff check src tests
uv run ruff format --check src tests
# All checks passed; 194 files already formatted

uv run pyright src/fiscal_api/services/reimbursements.py
# 0 errors, 0 warnings

FISCAL_DATABASE_URL=postgresql+asyncpg://linotsai@localhost:5432/<temporary-db> \
FISCAL_TEST_DATABASE_URL=... uv run alembic downgrade 20260814_0032
FISCAL_DATABASE_URL=... uv run alembic upgrade head
FISCAL_DATABASE_URL=... FISCAL_TEST_DATABASE_URL=... uv run pytest -q \
  tests/test_p6_postgres.py tests/test_p6_api_postgres.py \
  tests/test_p22_archive_revision_postgres.py tests/test_p22_revision_route_matrix.py \
  tests/test_p31_api_postgres.py
# 40 passed, 1 upstream TestClient deprecation warning
```

## Compatibility / residual risk

- This intentionally changes the four HTTP mutation payloads to require `preview_token` and (where previously missing) `Idempotency-Key`; F3 must adopt this contract before the V15 reimbursement UI is enabled.
- Direct service calls without a token remain available only for established internal migration/test paths; no HTTP route bypasses the required token schema.
- Migration `20260814_0033` follows the concurrently owned credit migration `20260814_0032`; both were included in the fresh upgrade/downgrade verification.
- Preview sessions are intentionally short-lived operational state and excluded from Archive; formal operation receipts and revisions remain recoverable, while archived operations retain no usable preview token.
