# Fiscal release state

This is the short, current release manifest. It reports only evidence already
recorded in current QA results; an unknown field is intentionally not inferred
from source code, a historical document, or an earlier release.

## v1.3.0 (Build 21) release train

| Field | Current evidenced value |
| --- | --- |
| Train | P20 → P23 Automated / Production / Physical Device Verified; final manifest same-head deploy complete |
| Candidate source revision | final manifest committed HEAD, deployed same-head before `v1.3.0`; P23 production evidence began at `be664f84c67d36bcddd3cf1f1430879fbac7fc68` |
| Candidate app version | `1.3.0 (21)` |
| Local Alembic head | `20260811_0023` |
| Deployed source revision | final manifest committed HEAD, same-head deployed before tag |
| Deployed Alembic head | `20260811_0023` |
| Authentication mode | generation 2 personal passphrase/access keys only: one credential, three current-generation keys, and no `device_tokens` table |
| macOS / Kurisu builds and connection | independently built signed `1.3.0 (21)` packages installed and launched; production data-revision and P23 quality/settings/strategy/rules protected reads returned HTTP 200, revision `2` |
| Backup / off-host copy / restore / alert | P23 pre-shadow verified backups, post-deploy `fiscal-20260811T132006Z.dump`, and isolated restore at `2026-08-11T13:21:03Z` passed. Alert receiver is **deferred by user**; off-host provider remains an explicit carried risk |
| Previous tagged release | `v1.2.4` at `7c221ecdc10b6b8933b60052240162dafb430153` |
| Rollback boundary | only an application revision at the same Alembic head; otherwise restore a verified backup into an isolated new database before cutover |
| Tag / push | permitted after final same-head re-anchor and clean; the user waived the former seven-day observation on 2026-08-11 |

## Release state machine

`Implemented → Automated Verified → Production Verified → Physical Device Verified → Released`

Each transition needs dated evidence in the current phase's
`docs/qa/pNN/results.md`. A deployment, build, test run, or historical record
does not substitute for another state. The final `v1.3.0` tag must name the
exact released commit and may be pushed only together with `main` after the
all P23 production, physical-device and final reconciliation evidence is recorded. The former seven-day observation was explicitly waived for this personal-use app.

## Evidence update rules

- Update this file only after a repeatable command, controlled production query,
  or physical-device result is recorded in the relevant QA result.
- Never put passphrases, access keys, webhook URLs, database URLs, dumps, or
  other secrets here.
- Keep historical implementation detail in the phase QA records and Git; this
  file remains a compact recovery entrypoint.
