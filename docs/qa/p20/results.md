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
- Current macOS and Kurisu bundle/version/build plus successful connection.
- Backup age, encrypted off-host copy retention, isolated restore result, and a
  delivered alert from the configured receiver.

These checks require the user's controlled production/device access. No
production mutation, deployment, migration, passphrase action, key use, or
device action was attempted in this audit.

## Current P20 status

- P20-A local/public audit: recorded; controlled production portion is verified
  below. User accepted macOS + Kurisu as the physical-device scope. Both have
  prior production access-key evidence and are now awaiting the user-entered
  post-recovery connection proof.
- P20-B release state source / version: complete locally. `README.md` is an
  entrypoint, `RELEASE_STATE.md` is the compact current manifest, and the
  candidate application version is `1.3.0 (21)`.
- P20-C/E local implementation: stable balance-adjustment category semantics,
  P10 uncategorized trigger repair, atomic account/credit-schedule update, and
  the complete fresh PostgreSQL automated gate are complete.
- P20-C authentication cleanup: forgotten-passphrase recovery is verified and
  invalidated generation-1 access keys. macOS and Kurisu must now reconnect
  with a generation-2 key; the legacy transition remains until old-token
  rejection is also proven.
- P20-D off-host recovery and real alert delivery: local current-head backup
  and isolated restore are verified; off-host storage and a real alert receiver
  remain blocked pending user-selected external service configuration.
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
| Fresh disposable PostgreSQL migration | passed from empty `fiscal_p20_test` through `20260811_0019` |
| P10 uncategorized API + renamed balance-adjustment category reports | 2 passed on fresh PostgreSQL |
| P17 schedule reassignment regression | 1 passed on fresh PostgreSQL |
| Alembic offline SQL | passed through `20260811_0019` |
| macOS FiscalKitTests after contract/UI change | passed: 88 tests in 17 suites |

## P20 automated-gate closure — 2026-08-11 CST

| Gate | Result |
| --- | --- |
| Backend formatting / lint / type check | `ruff format --check .`, `ruff check .`, and `pyright` passed; 0 type errors |
| Default backend suite | 144 passed, 105 PostgreSQL tests skipped; 1 upstream deprecation warning |
| Fresh disposable PostgreSQL suite | newly created `fiscal_p20_test`: **249 passed**, 1 upstream deprecation warning |
| Alembic fresh + round trip | empty `fiscal_p20_migration`: `base→head→base→head→base→head` passed at `20260811_0019` |
| Alembic offline SQL | generated through `20260811_0019`; includes one-time `平账` backfill and final `is_balance_adjustment DEFAULT false` |
| macOS contracts | `FiscalKitTests`: **88 tests in 17 suites passed** |
| iOS compilation | unsigned Release simulator build (`FiscaliOS`, `CODE_SIGNING_ALLOWED=NO`) passed |

The PostgreSQL suite now resets only the explicitly supplied disposable
database to `head` and truncates it before each test. This prevents a guarded
downgrade test from leaking schema/data state into later tests. Its July 2026
installment/reporting fixtures pin the relevant service business clock at the
test boundary, preserving their declared open-cycle semantics without changing
production time behavior. The P20 balance-adjustment field now keeps a server
default of `false`, so historical raw SQL fixtures/imports that omit the new
additive field remain valid.

The Swift gate also found and corrected a pre-existing local compile error in
the schedule-preview request binding. This did not change the account/credit
contract; it restores compilation of the already-reviewed preview path.

## P20 production audit, deployment, and recovery — 2026-08-11 CST

| Fact / gate | Result |
| --- | --- |
| Initial controlled read | HZ SSH reachable; release `39e9cbcf8851…`, Alembic `20260719_0016`, API ready, and all four local operational timers enabled |
| Authentication audit | one credential at generation 1, five current-generation access keys, and three legacy device-token rows; no raw credential or token was read or recorded |
| Exact deployments | `5346716f2c752cc1ccf2123bf842c7c8c3b2ac01` migrated the database through `20260811_0019`; `a41d2991f92e63c3f7b0be3ba9d1fcbdf3e1f277` then deployed the current-head-backup fix |
| Release / schema / smoke | current release and live database both at `a41d2991…` / `20260811_0019`; service active, loopback readiness and public HTTPS liveness passed |
| Pre-migration safety backup | verified custom-format dump created before each deployment; latest current-head dump created at `2026-08-11T07:44:10Z` |
| Ledger invariant after migration | 184 transactions, 201 postings, 0 orphan postings |
| Isolated recovery | newest current-head dump restored into a disposable database; Alembic head, canonical tables, and orphan-posting check passed in 2 seconds at `2026-08-11T07:44:20Z` |
| macOS production authentication | signed `1.3.0 (21)` installed after moving `1.2.4 (20)` to `/Applications/Fiscal-build20-backup.app`; the existing Keychain access key reached production `/api/v1/system/status` with HTTP 200 |
| Kurisu production core flow | signed `1.3.0 (21)` built, code-signature verified, installed and launched on paired Kurisu; production logs recorded access-key `GET /api/v1/system/status` and current-month `GET /api/v1/reports/overview?month=2026-08`, both HTTP 200, at `2026-08-11T15:47:41–42Z` |
| Forgotten-passphrase recovery | after service identity, exact release/head, and readiness checks, a two-prompt hidden local dialog sent a fresh value only to the production recovery CLI standard input. Credential generation changed `1→2`; production then reported one generation-2 key and five prior-generation keys, while readiness remained healthy. The successful recovery value and access keys were neither read nor recorded. |
| Recovery transport safety | a public shell-metacharacter sentinel reached only the remote target process stdin; an isolated PostgreSQL CLI run reproduced `initialize` then `reset-passphrase` as generations `1→2`, and the isolated old-key rejection test passed (1 test). The temporary databases were removed. |
| Post-recovery device invalidation | macOS and newly launched Kurisu each requested production content using their former key; server logs recorded `401` for `GET /api/v1/system/status` and `GET /api/v1/reports/overview?month=2026-08` at `2026-08-11T15:58:59Z`, as required before reauthentication. |

The first post-deployment restore drill intentionally surfaced a release-script
gap: its newest dump was the required *pre*-migration backup at
`20260719_0016`, so matching it directly against the newly deployed
`20260811_0019` correctly failed. An isolated diagnostic restore confirmed the
old dump's head and canonical tables without touching the production database.
Commit `a41d299` retains that recovery dump and creates a new verified
current-head backup after a successful migration; its subsequent isolated drill
passed. Both the failure and the repaired verification are retained as evidence.

An earlier aborted recovery transport attempt incorrectly attached a dialog's
stdin to a remote shell rather than the CLI. The CLI did not run and production
generation did not change; that value was treated as compromised and was not
reused. This record contains no value. The corrected transport was proven with
the sentinel and isolated-CLI checks before the successful recovery above.

### Remaining production and physical-device gates

- Legacy device-token rejection and CLI passphrase-recovery proof are not
  fully claimed: the CLI recovery is now proven, but raw legacy-device-token
  rejection remains unproven. The transition layer is intentionally still
  deployed until that check and post-recovery macOS + Kurisu generation-2
  connection proof are complete.
- User interaction gate: enter the newly recovered passphrase in the cloud
  connection screen on both macOS and Kurisu. The applications are open and
  have already demonstrated the expected 401 for their invalidated old keys;
  no agent may enter or extract the passphrase.
- `FISCAL_ALERT_WEBHOOK_URL` is missing or invalid, and no off-host backup unit
  or provider is configured. Choosing/configuring an alert receiver and an
  encrypted off-host destination requires a user-selected external service and
  credentials; no guess or substitute was made.
