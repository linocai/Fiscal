# Fiscal API

FastAPI/PostgreSQL backend for the private Fiscal app.

## Local development

Requires Python 3.12+, `uv`, and PostgreSQL.

```sh
cp .env.example .env
uv sync
uv run alembic upgrade head
uv run uvicorn fiscal_api.main:app --reload
```

The service listens on port 8000 by default. Its P1 endpoints are:

- `GET /api/v1/health/live`
- `GET /api/v1/health/ready`
- `GET /api/v1/system/status` with `Authorization: Bearer <access-key>`

P2 adds access-key-protected account and category master-data routes under
`/api/v1/accounts` and `/api/v1/categories`, including archive/restore, safe delete,
ordering, category merge, and category split. Mutable single-resource requests use an
`expected_version` for optimistic concurrency. Monetary fields are signed integer CNY minor
units.

P3 adds the access-key-protected unified ledger at `/api/v1/transactions`. Clients submit
semantic income, expense, or transfer drafts with a UUID `Idempotency-Key`; the server owns
postings, derives balances and Shanghai business dates, supports complete replacement plus
void/restore, and exposes an income/expense category summary.

P4 adds `credit_purchase` and `repayment` to that same ledger plus protected
`/api/v1/credit-accounts` and `/api/v1/credit-cycles` projections. Statement cycles, debt,
available/over-limit credit, repayment progress, and status are server-derived. Positive opening
debt requires explicit as-of and due dates rather than a fabricated deadline; installments remain
P5.

P20 finalizes personal passphrase authentication. The server stores only the passphrase slow-hash
and HMAC-SHA256 access-key digests; a passphrase change increments the credential generation and
invalidates every older key. The historic device-token bridge has been permanently removed by an
irreversible migration. Protected `/api/v1/system/operations-status` exposes schema, backup,
restore and disk facts without claiming end-to-end encryption.

Run quality checks with:

```sh
uv run ruff check .
uv run pyright
uv run pytest
```

All timestamps crossing the API boundary are UTC. Business-day calculations use
`Asia/Shanghai`. All monetary values are CNY decimal strings and binary floating-point amounts
are rejected.
