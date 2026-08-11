# Fiscal release state

This is the short, current release manifest. It reports only evidence already
recorded in current QA results; an unknown field is intentionally not inferred
from source code, a historical document, or an earlier release.

## v1.3.0 (Build 21) release train

| Field | Current evidenced value |
| --- | --- |
| Train | P20 → P21 → P22 → P23 |
| Candidate source revision | local committed and deployed `81d5881ba99c4694b480f1bfb20a41dbedd8faf7` |
| Candidate app version | `1.3.0 (21)` |
| Local Alembic head | `20260811_0020` |
| Deployed source revision | `81d5881ba99c4694b480f1bfb20a41dbedd8faf7` |
| Deployed Alembic head | `20260811_0020` |
| Authentication mode | generation 2 personal passphrase/access keys only: one credential, three current-generation keys, and no `device_tokens` table |
| macOS / Kurisu builds and connection | both signed `1.3.0 (21)` packages installed and launched; each reached production status and current-month overview with HTTP 200 using generation-2 access keys |
| Backup / off-host copy / restore / alert | post-migration local backup and isolated restore verified at `2026-08-11T08:27:25Z`; alert receiver is **deferred by user** and does not block P21; off-host backup provider remains unconfigured as an explicit carried risk |
| Previous tagged release | `v1.2.4` at `7c221ecdc10b6b8933b60052240162dafb430153` |
| Rollback boundary | only an application revision at the same Alembic head; otherwise restore a verified backup into an isolated new database before cutover |
| Tag / push | prohibited until every P20–P23 gate and the seven-day stability observation close |

## Release state machine

`Implemented → Automated Verified → Production Verified → Physical Device Verified → Released → Observed Stable`

Each transition needs dated evidence in the current phase's
`docs/qa/pNN/results.md`. A deployment, build, test run, or historical record
does not substitute for another state. The final `v1.3.0` tag must name the
exact released commit and may be pushed only together with `main` after the
release is Observed Stable.

## Evidence update rules

- Update this file only after a repeatable command, controlled production query,
  or physical-device result is recorded in the relevant QA result.
- Never put passphrases, access keys, webhook URLs, database URLs, dumps, or
  other secrets here.
- Keep historical implementation detail in the phase QA records and Git; this
  file remains a compact recovery entrypoint.
