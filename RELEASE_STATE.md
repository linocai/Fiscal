# Fiscal release state

This is the short, current release manifest. It reports only evidence already
recorded in current QA results; an unknown field is intentionally not inferred
from source code, a historical document, or an earlier release.

## v1.4.0 (Build 23) release train

| Field | Current evidenced value |
| --- | --- |
| Train | P24 → P29 Automated / Production / synthetic Physical Device Verified; final manifest same-head deploy complete |
| Candidate source revision | final manifest committed HEAD; product verification began at `ad956cda9e66692733a005d00983c4fd4a6ffc28` |
| Candidate app version | `1.4.0 (23)` |
| Local Alembic head | `20260813_0029` |
| Deployed source revision | final manifest committed HEAD, deployed same-head before `v1.4.0` tag |
| Deployed Alembic head | `20260813_0029` |
| Authentication mode | generation 2 personal passphrase/access keys only: one credential, three current-generation keys, and no `device_tokens` table |
| macOS / Kurisu builds and connection | independently built signed `1.4.0 (23)` packages passed strict signature verification and were installed/launched; macOS displayed the production overview/ledger and Kurisu persisted production data revision `2` after launch |
| Backup / off-host copy / restore / alert | pre-shadow `fiscal-20260813T041555Z.dump` verified; fresh `0023→0029` shadow and encrypted Archive empty-target roundtrip conserved ledger/balance/credit fingerprints; post-deploy `fiscal-20260813T043124Z.dump` isolated restore passed in 2 seconds with zero residue. Alert receiver is **deferred by user**; off-host provider remains an explicit carried risk |
| Previous tagged release | `v1.3.0` at `a18b54f2f18ef8ad1216ad50f1a582d6ab559e3d` |
| Rollback boundary | only an application revision at the same Alembic head; otherwise restore a verified backup into an isolated new database before cutover |
| Tag / push | user authorized the complete production release chain on 2026-08-13; annotated `v1.4.0` names this final manifest commit and is pushed together with `main` only after same-head production re-anchor |

## Release state machine

`Implemented → Automated Verified → Production Verified → Physical Device Verified → Released`

Each transition needs dated evidence in the current phase's
`docs/qa/pNN/results.md`. A deployment, build, test run, or historical record
does not substitute for another state. The final `v1.4.0` tag must name the
exact released evidence commit and may be pushed only together with `main` after
P29 production, signed-device and final reconciliation evidence is recorded.
Real bank-format compatibility and a real external statement Provider remain
explicitly unverified; the production release must not claim otherwise.

## Evidence update rules

- Update this file only after a repeatable command, controlled production query,
  or physical-device result is recorded in the relevant QA result.
- Never put passphrases, access keys, webhook URLs, database URLs, dumps, or
  other secrets here.
- Keep historical implementation detail in the phase QA records and Git; this
  file remains a compact recovery entrypoint.
