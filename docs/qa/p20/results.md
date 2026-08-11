# P20 · v1.3.0 (Build 21) QA / release evidence

This is the current evidence record for P20. It deliberately separates locally
reproducible facts from production and physical-device evidence. A historical
QA result is not production state.

## P20-A · fact audit — 2026-08-11 CST

### Locally reproducible release facts

| Fact | Evidence | Result |
| --- | --- | --- |
| Local source revision | `git rev-parse HEAD` | `d3ea2256d1361c2d2c44c93de35ea7649fae715f` (`docs: plan v1.3.0 trust roadmap`) |
| Remote relation | `git branch -vv` | `main` is one commit ahead of `origin/main`; no push is permitted during this release train |
| Last release tag | `git rev-parse v1.2.4^{commit}` | `7c221ecdc10b6b8933b60052240162dafb430153`; it does not point at current HEAD |
| Candidate app version before P20-B | `apple/project.yml` | `1.2.4 (20)` |
| Current local Alembic head | `backend/alembic/versions/20260719_0016_access_credential.py` | `20260719_0016` |
| Authentication source shape | `AccessService`, `DeviceTokenService`, migration `20260719_0016` | passphrase/access-key model exists; the legacy `device_tokens` model and transition verifier still exist |

### Historical evidence that cannot be promoted to current production fact

`docs/qa/p19/results.md` records a 2026-07-19 transition deployment at
`20260719_0016` with `access_credential=0`, then requires a user to set the
passphrase and migrate both iPhones. Later Build 18–20 commit notes state that
the passphrase was set and old authentication closed, but do not provide a
current production revision, database query, installed bundle inventory, or
repeatable device evidence. The records conflict, so P20 treats the live
authentication state as **unverified**.

P11 records a successful local backup/restore drill and timers, but explicitly
leaves encrypted off-host recovery and an actual alert receiver as open gates.
Those remain **unverified** until a controlled production check and isolated
restore have current evidence.

P18/P19 record PostgreSQL full-suite failures (13, then 11) as historical
baseline debt. P20 must measure the fresh current head and remove every
failure; prior exclusions are not a release waiver.

### Public, unauthenticated probe

At 2026-08-11 CST, from this build host:

| Request | Result | Interpretation |
| --- | --- | --- |
| `GET https://fiscal.linotsai.top/api/v1/auth/status` | `401` | protected route is reachable; it does not reveal authentication mode |
| `GET https://fiscal.linotsai.top/api/v1/accounts` | `401` | protected API is reachable; no account data was requested or obtained |
| `GET https://fiscal.linotsai.top/live` | `404` | this historical liveness path is not an asserted current contract |

### Production / device evidence still required (do not infer)

- Exact deployed Git revision and Alembic head.
- Whether `access_credential` exists, its generation and active access-key
  count; legacy token rejection only after the credential is confirmed.
- Current macOS and both iPhone bundle/version/build plus successful connection.
- Backup age, encrypted off-host copy retention, isolated restore result, and a
  delivered alert from the configured receiver.

These checks require the user's controlled production/device access. No
production mutation, deployment, migration, passphrase action, key use, or
device action was attempted in this audit.

## Current P20 status

- P20-A local/public audit: recorded; controlled production and device portion pending.
- P20-B release state source / version: complete locally. `README.md` is an
  entrypoint, `RELEASE_STATE.md` is the compact current manifest, and the
  candidate application version is `1.3.0 (21)`.
- P20-C/E local implementation: stable balance-adjustment category semantics,
  P10 uncategorized trigger repair, and atomic account/credit-schedule update
  are implemented; full fresh PostgreSQL gate remains open.
- P20-C authentication cleanup: blocked at its explicit production/device gate;
  no legacy token table or transition code has been removed.
- P20-D off-host recovery and real alert delivery: blocked pending user-selected
  receiver/storage and controlled production operation.
- Final release status: not releasable; no tag and no push.

## P20-B local verification — 2026-08-11 CST

| Gate | Result |
| --- | --- |
| `cd apple && xcodegen generate` | passed; generated project carries `MARKETING_VERSION=1.3.0`, `CURRENT_PROJECT_VERSION=21` |
| `xcodebuild -project apple/Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests` | passed: 88 tests in 17 suites |

## P20-C/E local verification — 2026-08-11 CST

| Gate | Result |
| --- | --- |
| Backend Ruff + Pyright | passed: formatting clean, lint clean, 0 type errors |
| Default backend suite | 144 passed, 105 PostgreSQL tests skipped; 1 upstream deprecation warning |
| Fresh disposable PostgreSQL migration | passed from empty `fiscal_p20_test` through `20260811_0018` |
| P10 uncategorized API + renamed balance-adjustment category reports | 2 passed on fresh PostgreSQL |
| P17 schedule reassignment regression | 1 passed on fresh PostgreSQL |
| Alembic offline SQL | passed through `20260811_0018` |
| macOS FiscalKitTests after contract/UI change | passed: 88 tests in 17 suites |

The attempted full PostgreSQL suite is still red and is not a release waiver.
It exposed two independent historical defects: P10's later trigger rewrites
reinstated a category requirement (repaired in `20260811_0018`), and many
legacy tests encode July 2026 as a still-open period even though the current
clock is August 2026. The shared migration suite also lacks robust isolation
after guarded downgrade tests. P20 cannot be marked Automated Verified until
these remaining test-baseline issues are resolved and rerun from a fresh DB.
