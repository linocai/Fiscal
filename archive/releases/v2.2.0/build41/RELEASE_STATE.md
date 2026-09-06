# Fiscal v2.2.0 build 41 release state

2026-09-06, Asia/Shanghai. **RELEASED** — authorized visual quick fix and delivery completed. Marketing version remains 2.2.0. Final iOS device installation is the operator's action.

## Scope and source

- Overview canvas now fills the entire detail viewport when resizing; the 1380 pt limit only constrains reading content. Mac small text is raised by about 1 pt. Record, analysis and settings actions use consistent capsule styling, icon/height, hover and press feedback. Account accessibility containment preserves child action identifiers.
- Baseline: v2.2.0 (40), source 080c6fadbd3062df2887fcb6b69e70e786908f66. iOS styles, ledger behavior, API and schema unchanged.
- Released source `89cb977e8d28fd8e8a098e5c0efe692893644785`, pushed to main. Independent immutable tag `v2.2.0-build41` pushed, tag object `67b11d5125959da9f3c55bcb9ced135dd98e04e7`. Existing v2.2.0 tag is unchanged.
- All five QA source hashes match the exported tagged App. Release builds use canonical committed schemes; six pre-existing operator scheme changes remain byte-identical and excluded from commits.

## Verification

- Two distinct Mac root UI cases passed: 1000/1280 pt navigation and record open/return, and 2000 pt light/dark continuous background plus analysis/settings actions. Actual right-edge dragging was visually checked. Targeted design/workbench unit tests: 12 in 2 suites passed. The previous full 408-test run is historical, not rerun for this visual-only hotfix. See [QA evidence and test calibration details](qa/README.md).
- All three serial Release builds passed: generic iOS Simulator arm64, universal macOS arm64/x86_64, and arm64 iOS device. Version 2.2.0 (41), minimum OS 26.0, production API URL, device family and architectures verified.
- App/framework signatures were strictly verified before and after package extraction. App/framework dSYM UUIDs match, ZIP/IPA integrity and executable hashes agree, and valid iOS provisioning/entitlements were checked.
- Installed production Mac was launched successfully and visually inspected after replacement: live overview loaded, full-width canvas and updated header actions visible. No production financial writes or private screenshot archival occurred.

## Production

- Fresh preflight and postflight confirm deployed revision 64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4 and current schema 20260831_0038. Cumulative Backend delta from actual live revision to tagged source is empty; no deployment, migration, restart or release-only backup was needed.
- SSH service/timers and local readiness healthy; latest operational backup fiscal-20260905T192856Z.dump checksum passed, restore verification succeeded. Public live 200, protected readiness 403, unauthenticated accounts 401; authenticated operations and monthly report 200. Evidence: [preflight](qa/production-preflight.json), [postflight](qa/release/production-postflight.json).

## Delivery and rollback

- Installed and running: `/Applications/Fiscal.app`, 2.2.0 (41). Mac executable SHA-256 `1213e06659d2ebda29d1115d30574942a93dc2943be9ebefc0b3507939bdbdf9`.
- Immediate verified fallback: `/Applications/Fiscal-v2.2.0-build40-backup-20260906-192234.app`. Build 40 executable hash `d2a088b134639dbe3039b8a3ad4b22cc1c2b85f2b94abe133ddb5f27cf284648` matches its release record. Data and credentials preserved; rollback is client-only.
- Verified iOS delivery: `/Users/linotsai/Downloads/Fiscal-iOS-v2.2.0-build41-development.ipa`; operator performs final device installation.
- Signing: macOS Developer ID with hardened runtime and secure timestamp; iOS Apple Development using the existing registered-device profile. Notarization, TestFlight and App Store upload are outside this established local release path.
- Packages and symbols: `build/release-v2.2.0-41/artifacts/`.

| File | SHA-256 |
| --- | --- |
| `Fiscal-iOS-v2.2.0-build41-dSYMs.zip` | `55a020db1ff426b2f3fad3f01feade8c64341421f81c425024755addedb97f5a` |
| `Fiscal-iOS-v2.2.0-build41-development.ipa` | `10497d82e99ecdfacd822a915e4c801a41de284511f1b53905f03071f625de9a` |
| `Fiscal-macOS-v2.2.0-build41-dSYMs.zip` | `e79423f9a7f96261861df36d33c7d88118228edf08bbc20e05988683109abf42` |
| `Fiscal-macOS-v2.2.0-build41.zip` | `4987e85d0ebcc81d30372af2a278e38541798b9e8301043c7ca138a6ab7d1584` |
| `RELEASE.txt` | `caf01bf3227e9b4d91b309466f4f23d0aea6dfd9fb21f86c628ae62323738d12` |

Exact build, signature, symbol and installation records: [builds](qa/release/build-state.json), [verification](qa/release/verification.json), [installation](qa/release/installation.json), [checksums](qa/release/SHA256SUMS).

## Resource closeout

- Existing DerivedData and shared ModuleCache reused; serial two-job builds, no new simulator/runtime/DerivedData or global clean. Final Fiscal cache 3.11 GiB, shared cache 2.44 GiB, free disk 48.59 GiB.
- Removed only this hotfix's redundant QA diagnostics/exports and tagged-source/staging copies (703.4 MiB). Final passing results, exact logs, six synthetic window screenshots, scripts, signed packages and symbols retained. No prior release artifacts/backups or unrelated caches removed.
- No remaining agent-side release steps. Resume from this record, PROJECT_PLAN.md and git status; preserve both immutable tags and all six operator scheme edits.
