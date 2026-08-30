# Fiscal NB production migration overlay

This directory is the Fiscal-only target overlay for moving production from HZ
`118.178.122.194` to NB `114.66.2.205`. It does not authorize or operate on
Neckline, ICTW, LinoFinance, YiCoffee, static sites, or any other workload on
either shared host.

The root `production/` scripts remain authoritative for Fiscal users, database
roles, releases, backups, restore verification, monitoring, and rollback. The
NB overlay changes only the API edge topology:

- Docker Nginx Proxy Manager remains the sole listener on public 80/443.
- System Nginx remains inactive and disabled.
- PostgreSQL 16 listens only on loopback.
- Fiscal listens on host port 8010 so the `npm_default` bridge can reach it.
- UFW allows TCP 8010 only from `172.18.0.0/16`; public 8010 remains denied.
- The NPM container address must be rechecked before installing the NB API unit.
  The frozen unit trusts the verified address `172.18.0.2` for proxy headers.

## Immutable scope and single-writer rule

Only the live `fiscal` database is restored as production. Historical Fiscal
releases, verified dumps, operation state, and shadow databases may be copied
as cold archives, but shadow databases must never be restored as NB production.

HZ remains the only writer until the final freeze. After NB accepts any write,
DNS alone must not be pointed back to HZ: a rollback first stops NB writes and
restores the newest NB database into the rollback target.

There is no observation period. All database, service, backup/restore, TLS,
public, authentication, macOS, and iOS gates run immediately after cutover. If
they pass, HZ Fiscal-only cleanup begins at once. No gate is removed.

## Preparation order

1. Verify NB host identity, ED25519 fingerprint, Docker bridge, NPM container IP,
   UFW baseline, active workloads, disk, memory, and absence of Fiscal.
2. Install PostgreSQL 16 and the packages required by the root production
   scripts. Do not install or enable system Nginx for this topology.
3. Run the root production host bootstrap, securely transfer the HZ Fiscal
   environment without printing it, and bootstrap only the `fiscal` database.
4. Install the common Fiscal service/timer units, replacing only
   `fiscal-api.service` with `nb/systemd/fiscal-api.service`.
5. Add the UFW bridge-only rule for TCP 8010. Prove the public interface remains
   denied before starting Fiscal.
6. Materialize the committed release with first-start deferred. Restore a
   verified HZ dump into an isolated rehearsal database and validate the
   Alembic head, canonical tables, foreign keys, and orphan postings.
7. Configure `fiscal.linotsai.top` through the NPM management surface. Do not
   edit the NPM database or generated `proxy_host/*.conf` files. Keep public
   readiness blocked while exposing liveness and authenticated API routes.

## Final cutover

1. Record HZ revision/head/service state, then stop only
   `fiscal-api.service` to freeze writes.
2. Create and verify the final custom-format dump and manifest on HZ. Transfer
   them without exposing database contents or credentials.
3. Replace only the NB `fiscal` database, restore as the Fiscal migrator,
   reapply application grants, and verify head `20260823_0036`, integrity,
   foreign keys, canonical tables, and zero orphan postings.
4. Start and enable the NB API and timers. Run local readiness, verified backup,
   isolated restore, disk, NPM/TLS, public liveness, protected-route, and one
   authorized read gate.
5. Change only the `fiscal.linotsai.top` A record to `114.66.2.205`. Verify with
   independent DNS-over-HTTPS and direct SNI/TLS, then test macOS and iOS.
6. If every immediate gate passes, archive recovery evidence and remove only HZ
   Fiscal services/timers, vhost/renewal, OS/DB roles, database, and directories.
   Shared HZ Nginx, PostgreSQL, and all non-Fiscal resources remain untouched.

## NPM values

- Domain: `fiscal.linotsai.top`
- Scheme: `http`
- Forward host: `172.18.0.1`
- Forward port: `8010`
- WebSocket support: off
- Cache assets: off
- Block common exploits: on
- TLS: valid certificate for `fiscal.linotsai.top`, Force SSL, HTTP/2, HSTS

NPM configuration and certificate issuance are operator-surface changes. Back
up current NPM state, validate the generated configuration inside the container,
and regression-check all existing proxy hosts after adding Fiscal.
