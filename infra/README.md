# Fiscal infrastructure (P1)

This directory contains the local PostgreSQL service and the minimal VPS staging stack. It intentionally does not provide production backups, restore automation, rate limiting, monitoring, or device-token lifecycle management; those belong to P11 or its decision gates.

## Local database

Requirements: Docker Engine with Compose v2.

```sh
docker compose -f infra/compose.local.yml up -d
docker compose -f infra/compose.local.yml ps
```

The defaults expose PostgreSQL on `127.0.0.1:5432` through Docker's published port and are for local development only. Override `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, or `POSTGRES_PASSWORD` in the shell when needed. Stop the service with:

```sh
docker compose -f infra/compose.local.yml down
```

Do not add `--volumes` unless the local database is deliberately being discarded.

## Staging VPS

Prerequisites:

- A Linux VPS with Docker Engine and Compose v2.
- DNS for the staging hostname pointing to the VPS.
- Inbound TCP 80/443 and UDP 443 allowed. PostgreSQL must not be exposed publicly.

Create the untracked environment file and replace every placeholder with a real value:

```sh
cp infra/staging.env.example infra/staging.env
chmod 600 infra/staging.env
```

Generate secrets locally, for example with `openssl rand -hex 32`; do not paste them into tracked files. Then validate and deploy from the repository root:

```sh
docker compose --env-file infra/staging.env -f infra/compose.staging.yml config --quiet
docker compose --env-file infra/staging.env -f infra/compose.staging.yml build api
docker compose --env-file infra/staging.env -f infra/compose.staging.yml run --rm api alembic upgrade head
docker compose --env-file infra/staging.env -f infra/compose.staging.yml up -d
docker compose --env-file infra/staging.env -f infra/compose.staging.yml ps
```

Caddy obtains and renews HTTPS certificates after DNS and ports are correct. Only Caddy publishes host ports; the API and PostgreSQL stay on the private Compose network.

Verify the public liveness endpoint and the protected status endpoint using the paths documented by the backend:

```sh
curl --fail --show-error https://fiscal-staging.example.com/api/v1/health/live
curl --fail --show-error \
  -H 'Authorization: Bearer YOUR_DEVICE_TOKEN' \
  https://fiscal-staging.example.com/api/v1/system/status
```

## Application rollback

P1 builds the API image on the VPS and labels it with `FISCAL_IMAGE_TAG`. Before an update, retain the prior Git revision and image tag. If the new API fails its health check:

1. Set `FISCAL_IMAGE_TAG` in `infra/staging.env` to a new rollback tag.
2. Check out the last known-good Git revision.
3. Rebuild `api`, run `docker compose ... up -d`, and confirm `ps` plus the public liveness endpoint.

Do not automatically downgrade the database schema. Schema rollback can destroy data and must follow the migration-specific instructions. P1 has no production backup/restore promise; that capability is delivered and exercised in P11 before production use.
