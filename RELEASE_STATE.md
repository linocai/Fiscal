# Fiscal release state

This is the short, current release manifest. It reports only evidence already
recorded in current QA results; an unknown field is intentionally not inferred
from source code, a historical document, or an earlier release.

## v1.3.0 (Build 21) release train

| Field | Current evidenced value |
| --- | --- |
| Train | P20 → P21 → P22 complete; P23 locally Automated Verified, production pending |
| Candidate source revision | local P23 candidate `cac6ab2`; deployed production remains `5330b42a0e95ab1150a9c0abf2676a4443333d53` |
| Candidate app version | `1.3.0 (21)` |
| Local Alembic head | `20260811_0023` |
| Deployed source revision | `5330b42a0e95ab1150a9c0abf2676a4443333d53` |
| Deployed Alembic head | `20260811_0022` |
| Authentication mode | generation 2 personal passphrase/access keys only: one credential, three current-generation keys, and no `device_tokens` table |
| macOS / Kurisu builds and connection | signed `1.3.0 (21)` packages installed and launched; both foreground clients stored revision `2` and reached production data-revision plus protected read paths with HTTP 200 |
| Backup / off-host copy / restore / alert | P22 post-deploy dump `fiscal-20260811T123917Z.dump` verified and isolated-restored at `2026-08-11T12:45:10Z`; exact Archive shadow A/B and production receipt QA passed. Alert receiver is **deferred by user**; off-host provider remains an explicit carried risk |
| Previous tagged release | `v1.2.4` at `7c221ecdc10b6b8933b60052240162dafb430153` |
| Rollback boundary | only an application revision at the same Alembic head; otherwise restore a verified backup into an isolated new database before cutover |
| Tag / push | permitted immediately after the P23 automated/production/Mac/Kurisu/final reconciliation gates pass; the user waived the former seven-day observation on 2026-08-11 |

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
