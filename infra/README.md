# Fiscal infrastructure

This directory contains the local PostgreSQL service, the P1 Docker/Caddy staging stack, and the P11 native-production assets. The staging stack remains intentionally separate from production.

For the HZ Ubuntu 24.04 / PostgreSQL 16 / Nginx topology, hardened systemd services, release deployment, backup/restore drills and monitoring timers, see [`production/README.md`](production/README.md). Those assets never connect to or mutate the server by themselves, and the old Docker/Caddy stack must not be presented as the production deployment.

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

Do not automatically downgrade the database schema. Schema rollback can destroy data and must follow the migration-specific instructions. The Docker/Caddy path remains staging-only; P11 production backup/restore and recovery gates are defined by the native HZ workflow linked above.
