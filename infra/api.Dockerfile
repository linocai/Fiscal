# syntax=docker/dockerfile:1.7

FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

RUN pip install --no-cache-dir uv

WORKDIR /app

COPY backend/pyproject.toml backend/uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY backend/ ./
RUN uv sync --frozen --no-dev

FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH"

RUN addgroup --system fiscal \
    && adduser --system --ingroup fiscal --home /app fiscal

WORKDIR /app
COPY --from=builder --chown=fiscal:fiscal /app /app

USER fiscal
EXPOSE 8000

CMD ["uvicorn", "fiscal_api.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips=*"]
