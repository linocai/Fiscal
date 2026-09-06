# Fiscal v2.2.0 build 41

2026-09-06, Asia/Shanghai. **In progress** — authorized visual quick fix and delivery; marketing version remains 2.2.0.

- Baseline: source 080c6fadbd3062df2887fcb6b69e70e786908f66, immutable tag v2.2.0, installed Mac 2.2.0 (40). Old Mac executable matches release checksum.
- Fixes: full-width overview canvas during window resizing, Mac small text raised by about 1 pt, consistent capsule header actions for record/analysis/settings. iOS styles and ledger behavior unchanged.
- Fresh production preflight passed: deployed 64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4, schema 20260831_0038, service/timers, readiness, backup checksum and restore status healthy. Cumulative Backend delta empty; no deployment or migration required.
- Tests: two distinct Mac root UI cases passed (1000/1280 pt navigation and record; 2000 pt light/dark background plus analysis/settings actions). Targeted design/workbench units: 12 in 2 suites passed. Actual window-edge resize visually passed. Detailed evidence: [qa/README.md](qa/README.md).
- Next: commit/push main with independent tag v2.2.0-build41, build/sign both apps, verify/extract packages, back up build 40 and install/launch build 41, hand the verified IPA to the operator.
- Six pre-existing scheme edits are backed up and restored byte-for-byte. Reuse existing DerivedData/ModuleCache; no simulator/runtime added. Raw evidence stays in build/release-v2.2.0-41.
