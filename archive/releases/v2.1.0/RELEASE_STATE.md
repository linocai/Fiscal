# Fiscal v2.1.0 (39) release state

2026-09-06, Asia/Shanghai. **RELEASE_IN_PROGRESS** — user authorized the complete established release workflow. Do not treat local builds as completed delivery.

## Scope and verified baseline

- Client baseline: source `bf5b9c99443a5184a83319b605dd691577d5987f`, tag `v2.0.0`; installed `/Applications/Fiscal.app` is `2.0.0 (38)` and passes strict signature verification.
- Live Ningbo backend: `/opt/fiscal/releases/64cb1aee0190`, full revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4`, metadata and database Alembic `20260831_0038`.
- Cumulative Backend diff from that live revision to the target worktree is empty. No new API, schema or migration dependency was introduced. Keep production backend and database unchanged; no deployment/restart/migration or release-only database backup is required.
- `fiscal-api.service` active/running, enabled, zero restarts and successful main status; all four Fiscal operational timers active/enabled. Local readiness is healthy.
- Latest operational backup `fiscal-20260905T192856Z.dump`, verified, 415505 bytes; restore verification succeeded at `2026-09-05T20:56:58Z`; disk healthy at 24% used.
- Frontend review findings R1/P2 and R2/P3 are fixed. Current source matches `qa/frontend/review-fix-source-manifest.json`; latest 405 tests / 39 suites and focused UI regressions passed, as did both Debug app builds. Prior core UI/visual evidence is retained in `qa/frontend/RESULTS.md` and `REVIEW.md`.
- Six pre-existing local schemes remain protected and must be excluded from commits. All working changes are on `main`.
- Public preflight passed: liveness 200, readiness deliberately blocked with 403, unauthenticated accounts 401; authenticated operations status and current monthly report v2 returned 200. Two independent DNS resolvers confirm the Ningbo IP. Strict TLS fingerprint is unchanged (`8145ddb1431c4dced5b21b0d1c591721798dec0348251d9c8a3ddeaf69323523`), expires 2026-10-14.

## Remaining release steps

1. Verify current backup manifest, public TLS/health/authenticated read-only API paths.
2. Commit intended source/QA/docs on main, push and create immutable `v2.1.0` tag. Preserve protected schemes.
3. Export tagged App source into `build/release-v2.1.0-39/source`; use the existing Fiscal DerivedData/shared ModuleCache, serial builds with 2 jobs. Build generic iOS Simulator Release, Developer-ID-signed universal macOS Release, and development-signed arm64 iOS device Release.
4. Strictly verify app signatures, provisioning, architectures and dSYM UUIDs; package ZIP/IPA, extract and reverify, generate SHA256SUMS and source/tag metadata.
5. Back up installed 2.0.0 (38), replace `/Applications/Fiscal.app`, strictly verify and launch, confirm production data loads. Copy IPA into Downloads for operator installation.
6. Record final checksums, installed version, rollback and delivery paths; update README/PROJECT_PLAN and push delivery record. Clean only this run's disposable source/staging/results; preserve existing caches and older releases.

## Resume and resource notes

Start with this file, PROJECT_PLAN.md and `git status --short`. Release artifacts and raw logs: `build/release-v2.1.0-39/`. Existing DerivedData: `/Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou`; shared cache: sibling `ModuleCache.noindex`. Both started near 2.0G; disk free about 29 GiB. No new simulator or runtime is needed.

Read-only host verification uses the existing `deploy` SSH identity and verified Ningbo known-host entry; no credentials belong in this record. Signing identities are the already established Developer ID Application and Apple Development identities for team HX73DFL88G. Existing iOS profile UUID `c2ca777b-b04b-484e-826e-eef28085a121` expires 2027-07-21.

This established path does not include Apple notarization, TestFlight or App Store upload. Only final iOS installation remains the user's action.
