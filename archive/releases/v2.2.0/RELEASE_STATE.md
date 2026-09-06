# Fiscal v2.2.0 (40) release state

2026-09-06, Asia/Shanghai. **RELEASED** — the authorized release workflow is complete. Final iOS device installation remains the operator's action.

## Released state

| Field | Result |
| --- | --- |
| Scope | Complete native SwiftUI redesign: deep-teal financial Mac workspace, expandable cash/credit account overview, four iOS destinations with native floating navigation and bottom “记一笔”, shared visual language across specialist pages; R1–R9 and D1 fixed |
| Client baseline | v2.1.0 (39), source `353c381ff6a2540a048e8c3d3a7d12b57e24e9ad` |
| Source revision | `080c6fadbd3062df2887fcb6b69e70e786908f66`, pushed to `origin/main` |
| Immutable tag | Annotated `v2.2.0`, pushed; tag object `afef8e834feb1d8304a10d57acaea813b725bc47`, resolves to the source revision |
| Backend | Unchanged Ningbo revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4`, Alembic `20260831_0038` |
| Release builds | iOS Simulator arm64, Developer-ID-signed universal macOS, development-signed arm64 iOS device all passed from the exported tag |
| macOS delivery | `/Applications/Fiscal.app`, strictly verified, installed and running as 2.2.0 (40); live production workspace loaded |
| iOS delivery | `/Users/linotsai/Downloads/Fiscal-iOS-v2.2.0-build40-development.ipa`; copy hash verified; operator installation pending |
| Platform | iOS/macOS 26.0+, iPhone 16 and newer; no simulator or runtime added |

## Verification and production audit

- All 51 App source/QA files match the post-fix source manifest and the clean exported tag. The six pre-existing operator scheme modifications were preserved byte-for-byte and excluded from both commits and release builds, which use canonical committed schemes.
- Reused verified same-source evidence: 408 FiscalKit tests across 39 suites; 43 distinct cumulative UI passes, including 8 new repair regressions. These were not rerun during release. Original findings, targeted fix verification, screenshot provenance and limitations remain in [FIX_REPORT.md](qa/FIX_REPORT.md), [REVIEW.md](qa/REVIEW.md), [VALIDATION.json](qa/VALIDATION.json) and [UI_COVERAGE.md](qa/UI_COVERAGE.md). All 41 archived screenshot hashes were rechecked.
- Release-specific gates: three Release App builds, production API URL and 26.0 minimum OS, iPhone-only device family, correct bundle IDs and architectures, strict app/framework signatures before and after ZIP/IPA extraction, executable checksum equality, valid provisioning/entitlements, matching app/framework dSYM UUIDs, all five artifact checksums, and Downloads delivery checksum.
- The cumulative `Backend/` delta from the **freshly verified live revision** to the tagged source is empty. No new API/migration dependency exists. No backend deployment, restart, migration or release-only database backup was needed or performed.
- SSH endpoint `deploy@114.66.2.205`: `/opt/fiscal/current` resolves to `/opt/fiscal/releases/64cb1aee0190`; release metadata and live database both report `20260831_0038`. Fiscal API is active/running and enabled, zero restarts, successful main status. All four operational timers are active/enabled. Local readiness is healthy.
- Latest operational backup: `fiscal-20260905T192856Z.dump`, 415505 bytes, 15 hours old at preflight; its SHA-256 manifest passed. Restore verification succeeded at `2026-09-05T20:56:58Z`. Production disk is healthy at 24% used.
- Public preflight and postflight: liveness 200, readiness intentionally blocked with 403, unauthenticated accounts 401, authenticated operations status and monthly report v2 both 200. AliDNS and Google DoH resolve `114.66.2.205`. Direct-SNI TLS verification passed, certificate SHA-256 `8145ddb1431c4dced5b21b0d1c591721798dec0348251d9c8a3ddeaf69323523`, expires 2026-10-14 04:56:45 GMT.
- Installed process was verified to run `/Applications/Fiscal.app/Contents/MacOS/Fiscal`. Actual compact and expanded windows were inspected; account summary, monthly overview, future items and global recent transactions loaded without offline/error state. No production financial writes were performed; no private financial screenshots were archived.

## Signing and artifacts

- macOS: `com.linotsai.fiscal.mac`, arm64 + x86_64, `Developer ID Application: ZheYuan Cai (HX73DFL88G)`, hardened runtime and secure timestamp. Executable SHA-256 `d2a088b134639dbe3039b8a3ad4b22cc1c2b85f2b94abe133ddb5f27cf284648`.
- iOS: `com.linotsai.fiscal`, arm64, `Apple Development: linocai@hotmail.com (J6H3FXT658)`, team `HX73DFL88G`; existing profile `c2ca777b-b04b-484e-826e-eef28085a121` expires 2027-07-21 and includes three registered devices. Executable SHA-256 `d0ba1ece31b81f784586f551e754020a094bdbe8fa623ade1718ee06cd16ace1`.
- The iOS profile's valid wildcard and the app's default keychain group were verified. An initially over-strict packaging assertion was corrected to follow Apple's documented entitlement semantics; source, app entitlements and signing permissions were unchanged. See [gate correction](qa/release/packaging-gate-correction.json).
- App and FiscalKit framework symbol UUIDs match the shipped binaries; exact values are in [verification.json](qa/release/verification.json).
- As in the established local release path, Apple notarization, TestFlight and App Store upload were not performed. Gatekeeper reports the expected unnotarized Developer ID state; strict signatures and the local app launch passed.

Artifacts: `build/release-v2.2.0-40/artifacts/`.

| File | SHA-256 |
| --- | --- |
| `Fiscal-iOS-v2.2.0-build40-dSYMs.zip` | `41c2da4b366b840a2aa0cf9898784df931bebd26aead02d27c451893fe49cd3a` |
| `Fiscal-iOS-v2.2.0-build40-development.ipa` | `5824f857e825fe52423412fae30dcbdb4af30ea1cb3375ba727e16f08a015284` |
| `Fiscal-macOS-v2.2.0-build40-dSYMs.zip` | `7adc15d9d338bd4b44d0309c45bf4625a7f1ce3c771836a3643c88b1c9892f9b` |
| `Fiscal-macOS-v2.2.0-build40.zip` | `0011e7b167dc4d805cf3bbf74b0c7f22e44c7618a49f3c93da0a5d65b054614e` |
| `RELEASE.txt` | `83754c6f61d029b86094503b59b1cc2127da6c12d7c850436eea2303ac454528` |

All five entries passed. Durable evidence: [build results](qa/release/build-state.json), [verification](qa/release/verification.json), [production checks](qa/release/production-checks.json), [installation](qa/release/installation.json), [resources](qa/release/resources.json), [checksums](qa/release/SHA256SUMS). Raw build and verification logs remain in `build/release-v2.2.0-40/logs/`.

## Rollback, resources and handoff

- Immediate strictly verified fallback: `/Applications/Fiscal-v2.1.0-build39-backup-20260906-185242.app`. Old executable SHA-256 `5d3e71d731942d98e820b6a5718bbb304a63af291ce9aed265142e5efb7157e2` matches the v2.1.0 release manifest. App data and credentials were preserved.
- Final physical iOS installation is handed to the operator; no iPhone installation is claimed. There are no remaining agent-side release steps.
- Reused the existing Fiscal DerivedData and shared ModuleCache, serial two-job builds. No new DerivedData directory, simulator boot/create, runtime download or clean build. Final Fiscal cache is 3.11 GiB and shared cache 2.40 GiB; free disk 51.3 GiB. Removed only this release's exported source/staging copies (374 MiB); retained artifacts/logs/scripts occupy 83 MiB. Older artifacts, backups and other caches remain intact.
- Backend/schema unchanged: v2.1.0 is the immediate client-only fallback. Existing cross-0038 restrictions remain: no blind Alembic downgrade or DNS-only rollback across that schema boundary.

Resume from this record, `PROJECT_PLAN.md` and `git status --short`. Preserve the immutable source tag and the operator's six local scheme modifications.
