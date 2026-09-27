# Fiscal NB backend production release — V2.4.0 Build 50 → Build 51

Date: 2026-09-27. Scope: NB Fiscal only. Production business records were not written; Build 50 applied schema migration `20260922_0041 → 20260926_0042`, and Build 51 kept head `20260926_0042`. The old 0041 backup and Build 50 release remain available for recovery. Migration 0042 has no downgrade; do not reconnect an 0041 backend to the 0042 database.

## Frozen sources and validation

| Build | Immutable commit | Git tag | Server release | Source verification | Local isolated PostgreSQL | Server non-DB gate |
| --- | --- | --- | --- | --- | --- | --- |
| 50 | `0bd45b25d1ef0f41af9dfe40a225d477022b4da6` | `v2.4.0-build50` | `/opt/fiscal/releases/0bd45b25d1ef` | 294 tracked Backend files match frozen Git tree | 438 passed | Ruff, format, Pyright; 167 passed, 271 skipped |
| 51 | `b006ed906fb150a996499bdcbecd82063ee71723` | `v2.4.0-build51` | `/opt/fiscal/releases/b006ed906fb1` | 295 tracked Backend files match frozen Git tree | 441 passed, 0 failed/skipped | Ruff, format, Pyright; 169 passed, 272 skipped |

The server skips database tests by design. Both builds passed standard `deploy.sh` dry-run before apply. Build 50's 0041 read-only `v240_preflight` returned eligible: 16 statement-import tables empty, no multi-party claims; 7 claims retained. There was no bypass of a preflight refusal. API and all four Fiscal timers were stopped before each apply, and restored to active/enabled afterward; no Fiscal database connections or listener remained during the stopped intervals.

## Backups and recovery proof

Each named release backup is a hardlink to a verified dump; no duplicate full database copy was made for the release directory. For each file, SHA-256 verification, `pg_restore --list`, and restore into a disposable isolated database succeeded. The disposable databases were deleted. Deploy-generated pre backups are also retained in the standard backup directory.

| Build | Phase | Protected backup path | SHA-256 | Bytes |
| --- | --- | --- | --- | ---: |
| 50 | 0041 pre | `/var/lib/fiscal/backups/releases/v2.4.0-build50/pre/fiscal-20260927T040009Z.dump` | `df7a500218ba23df8c0cccb0ce98a83e18545555e0428bf28791ae8ebd7b7371` | 460628 |
| 50 | 0042 post | `/var/lib/fiscal/backups/releases/v2.4.0-build50/post/fiscal-20260927T040148Z.dump` | `62b90f2574f7e068c55d350c4b2c54dcaa731aa495752daa486a0abb29fcf0c0` | 382906 |
| 51 | 0042 pre | `/var/lib/fiscal/backups/releases/v2.4.0-build51/pre/fiscal-20260927T042216Z.dump` | `8b0c5e52e334d9ec4c529340379bc28541ff9ae677bf3a8e8065a78ea2e78c27` | 382908 |
| 51 | 0042 post | `/var/lib/fiscal/backups/releases/v2.4.0-build51/post/fiscal-20260927T042332Z.dump` | `b540700ac7a61ecfc4cc22b4514f33fdf2b36963f3353f012c778e06fda5b285` | 382908 |

Standard deploy backups: Build 50 pre `fiscal-20260927T040146Z.dump`, post `fiscal-20260927T040148Z.dump`; Build 51 pre `fiscal-20260927T042331Z.dump`, post `fiscal-20260927T042332Z.dump`. Latest backup and restore verification both point to the Build 51 post dump; latest restore verification was at `2026-09-27T04:24:08Z`. All four protected release dump hashes were rechecked at final handoff.

## Financial integrity and production behavior

Build 50's immediately pre/post migration stable-field fingerprints were identical for transactions (271), postings (300), claims (7), claim allocations (7), receipts (6), and receipt allocations (6). Build 51's immediately pre/post release full-row count/hash fingerprints were identical for all 16 financial/history tables: accounts, cash-flow items, categories, credit cycles, installment plans, postings, claim allocations/revisions/claims/operations/previews, receipt allocations/revisions/receipts, transactions/revisions. Database `data_revision` remained 102. The examples are count plus 32-character MD5 digest, not SHA-256: transactions `271|5792d77ed693df20815cd804de909d57`, postings `300|ae689d427b0a91efce7b9df8e94c675a`. No real finance data was inserted or modified.

Build 50 initially passed deploy health checks, but an additional authorized current-month report read returned HTTP 500. Production traceback located old immutable reimbursement revision JSON with a nested receipt transaction relation in the legacy `party_id`/`party_name` shape. Six claim and six receipt revisions had that shape. Build 51 added read-only compatibility adaptation across historical report, CSV, receipt, transaction and reimbursement replay paths; it does not rewrite stored revisions or relax the current strict response contract. Synthetic model and isolated PostgreSQL report/CSV/archive restore regressions passed. The independent Build 51 review reported no findings.

After Build 51 apply, public authenticated read-only checks returned HTTP 200 and valid payloads for live, system/operations status, accounts, transactions, reimbursement claims, facts, future events, current and historical monthly reports, annual report, and current-month CSV with `as-of-v1` semantics. Unauthorized accounts returned HTTP 401. The current-month report that failed on Build 50 now passed. The independent client postflight also passed current/history/yearly reports and monthly/yearly CSV. Final production release is `b006ed906fb150a996499bdcbecd82063ee71723`, Alembic head `20260926_0042`; retired `statement_imports` and `reimbursement_parties` tables are absent. Fiscal API and all four timers are active/enabled; health check passed.

## Resource cleanup

Only task-owned transfer/source material was removed. Remote staging paths `/home/deploy/fiscal-v240-build50-0bd45b25` and `/home/deploy/fiscal-v240-build51-b006ed90` had 279,351,296 and 4,059,136 allocated bytes before removal. They were verified as unused; a first unprivileged removal left 692,224 bytes of root-owned Python cache, then exact-path privileged cleanup removed that residue. Both paths and temporary `.deploy-*` releases are absent. Remote free space increased from 47,358,537,728 to 47,641,931,776 bytes during cleanup (283,394,048 bytes); a final later check showed 47,641,915,392 bytes available, root disk 23% used. The current and rollback releases plus protected backups remain.

Local transfer bundles `/tmp/fiscal-v240-build50-0bd45b25.bundle` and `/tmp/fiscal-v240-build51-b006ed90.bundle` were verified by exact path/hash, checked unused, then removed. Their allocated sizes totaled 137,306,112 bytes. Local free space changed from 57,775,280,128 to 57,870,630,912 bytes (APFS accounting differs from allocated file size). No disposable restore or isolated test database remains. The unrelated zero-byte App runtime export directory was left to the main release owner.
