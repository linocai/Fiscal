# Fiscal API

P1 backend foundation for the private Fiscal app. It intentionally contains no ledger business
tables yet.

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
- `GET /api/v1/system/status` with `Authorization: Bearer <device-token>`

Run quality checks with:

```sh
uv run ruff check .
uv run pyright
uv run pytest
```

All timestamps crossing the API boundary are UTC. Business-day calculations use
`Asia/Shanghai`. All monetary values are CNY decimal strings and binary floating-point amounts
are rejected.
