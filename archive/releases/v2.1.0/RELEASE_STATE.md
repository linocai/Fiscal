# Fiscal v2.1.0 (39) release state

2026-09-06, Asia/Shanghai. **RELEASED** — the authorized release workflow is complete. The final iOS device installation remains the operator's action.

## Released state

| Field | Result |
| --- | --- |
| Scope | Frontend design and interaction upgrade: icon-derived yellow/deep-teal identity, lightweight amount-first iOS entry, clearer Mac workspace and shared state semantics; both review findings fixed |
| Client baseline | `v2.0.0 (38)`, source `bf5b9c99443a5184a83319b605dd691577d5987f` |
| Source revision | `353c381ff6a2540a048e8c3d3a7d12b57e24e9ad`, pushed to `origin/main` |
| Immutable tag | Annotated `v2.1.0`, pushed; tag object `92fb4838efa42efd5139b6719f7dcea07e58e979`, dereferences to the source revision |
| Backend | Intentionally unchanged: Ningbo `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4`, Alembic `20260831_0038` |
| Builds | Clean tagged App source: generic iOS Simulator Release, Developer-ID-signed universal macOS Release, development-signed arm64 iOS device Release all passed |
| macOS delivery | `/Applications/Fiscal.app` strictly verified, installed and launched as `2.1.0 (39)`; live production workspace loaded successfully |
| iOS delivery | `/Users/linotsai/Downloads/Fiscal-iOS-v2.1.0-build39-development.ipa`; copy hash verified; operator installation pending |
| Platform scope | iOS/macOS 26.0+, iPhone 16 and newer; no new simulator or runtime |

## Verification and production state

- The exported tagged App source matches every entry in `qa/frontend/review-fix-source-manifest.json`. The existing same-source post-fix evidence records 405 passing tests in 39 suites, focused Mac account-menu and iOS note-folding regressions, the existing Mac return/quick-entry regression, and both Debug App builds. These tests were reused, not rerun during release. Earlier visual/UI evidence and limitations remain in [RESULTS.md](qa/frontend/RESULTS.md) and [REVIEW.md](qa/frontend/REVIEW.md).
- Additional release gates passed from the clean tag with canonical committed schemes: all three Release builds, app and extracted ZIP/IPA strict signature checks, architecture checks, provisioning/entitlement checks, and app plus FiscalKit framework dSYM UUID matching. The six pre-existing operator scheme modifications remain untouched and excluded from commits.
- The cumulative `Backend/` delta from the actual deployed revision to the source revision is empty. No new API or migration dependency exists, so no backend deployment, restart, migration or release-only database backup was necessary or performed.
- `/opt/fiscal/current` remains `/opt/fiscal/releases/64cb1aee0190`; release metadata and the live database both report Alembic `20260831_0038`. `fiscal-api.service` is active/running and enabled, with zero restarts and successful main status. All four operational timers are active/enabled; local readiness is healthy.
- Latest operational backup: `/var/lib/fiscal/backups/fiscal-20260905T192856Z.dump`, 415505 bytes; its checksum manifest passed. Restore verification succeeded at `2026-09-05T20:56:58Z`; disk check is healthy at 24% used.
- Public preflight and postflight: liveness 200, readiness deliberately blocked with 403, unauthenticated accounts 401, authenticated operations status 200. Preflight monthly report v2 returned 200. AliDNS and Google DoH resolved the Ningbo IP `114.66.2.205`; strict direct-SNI TLS verification passed with SHA-256 fingerprint `8145ddb1431c4dced5b21b0d1c591721798dec0348251d9c8a3ddeaf69323523`, expiring 2026-10-14 04:56:45 GMT.
- The installed Mac process was confirmed to run `/Applications/Fiscal.app/Contents/MacOS/Fiscal`; live account summary and known-future feed loaded without offline/error state. No production financial writes were performed and no private financial screenshots were archived.

## Signed artifacts

- Both apps report `2.1.0 (39)` and minimum OS 26.0. Source products and extracted delivery archives passed `codesign --verify --deep --strict`; extracted executable hashes match the signed products.
- macOS: `com.linotsai.fiscal.mac`, `arm64 x86_64`, `Developer ID Application: ZheYuan Cai (HX73DFL88G)`, hardened runtime and secure timestamp. Executable SHA-256: `5d3e71d731942d98e820b6a5718bbb304a63af291ce9aed265142e5efb7157e2`.
- iOS: `com.linotsai.fiscal`, `arm64`, `Apple Development: linocai@hotmail.com (J6H3FXT658)`, team `HX73DFL88G`. Existing profile `c2ca777b-b04b-484e-826e-eef28085a121` expires 2027-07-21 and includes three registered devices. Executable SHA-256: `295fab369024c24f797f56dfb57f6b7b7d19c2cb5316c5fecb4807b93d148cb1`.
- macOS app/dSYM UUIDs: x86_64 `71B67D71-ADEE-3888-B1E2-062FB6C100D3`, arm64 `91656EFC-D1E0-3DF1-810C-0BDEAD470D80`. iOS app/dSYM arm64 UUID: `401143B4-0A2F-3CC0-B326-FAB9C929324E`.
- As in the established local release path, Apple notarization, TestFlight and App Store upload were not performed. Gatekeeper reports the expected unnotarized Developer ID state; strict signature verification and local launch passed.

Artifacts: `build/release-v2.1.0-39/artifacts/`.

| File | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v2.1.0-build39.zip` | `78d0021860cf832423d90ed3f97bf4b346a3e2b398170b29b3cbb097be718a44` |
| `Fiscal-macOS-v2.1.0-build39-dSYMs.zip` | `85cacfaf6d1599a04724bd2abf322204af31e3eb26173810f798f079916acb2a` |
| `Fiscal-iOS-v2.1.0-build39-development.ipa` | `5b84707b241970613de90cc1ed2c5e352890e679e4c190d49a75bda661047b38` |
| `Fiscal-iOS-v2.1.0-build39-dSYMs.zip` | `ddb5ed660552382316abd3c959705e39d82bc66ee96acc3cbea60f0ab488c9db` |
| `RELEASE.txt` | `b54c3f44516c5648ab81ddfc856e0ec21d66468e928e994ef72fa4959b891583` |

All five entries in `SHA256SUMS` passed; the Downloads IPA has the identical hash. Durable machine-readable evidence: [verification](qa/release/verification.json), [build results](qa/release/build-state.json), [production checks](qa/release/production-checks.json), [installation](qa/release/installation.json) and [checksums](qa/release/SHA256SUMS). Raw logs remain in `build/release-v2.1.0-39/logs/`.

## Installation, resources and rollback

- Installed and running: `/Applications/Fiscal.app`, `2.1.0 (39)`. Strictly verified immediate fallback: `/Applications/Fiscal-v2.0.0-build38-backup-20260906-130613.app`; old executable SHA-256 `4f2a3f6a14576f521f4de220f81af27d0422340a99b3e1cf96c5774a318e02b2` matches the prior release manifest. No app data was replaced.
- Final iOS installation is handed to the operator. No physical iPhone installation is claimed. There are no remaining agent-side release steps.
- Reused existing Fiscal DerivedData and shared ModuleCache with serial builds and two jobs. No simulator was created or booted for release and no runtime was downloaded. Only this release's temporary source/staging directories were removed, freeing about 354 MB; artifacts/logs retained occupy about 81 MB. Existing Fiscal DerivedData is about 2.5G, shared ModuleCache about 2.4G, free disk about 28 GiB. Older caches, release artifacts and backups remain intact.
- Backend/schema did not change, so v2.0.0 is the immediate client-only fallback. The existing cross-`0038` restriction still applies: no blind Alembic downgrade or DNS-only rollback across that schema boundary. Such a future rollback requires stopping writes, a verified current backup, restoration of the appropriate pre-migration backup to a new target, validation, then switching the application.

Resume from this record, `PROJECT_PLAN.md` and `git status --short`. Preserve the immutable source tag and the operator's six local scheme modifications.
