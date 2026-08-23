# Fiscal v1.5.5 release state

## v1.5.5 (Build 31)

| Field | Prepared state |
| --- | --- |
| Scope | Permanently delete unposted AI input after confirmation; classify AI provider failures without exposing private input or engineering codes |
| Source revision | `a21e17c465b29ce3c1899526c504dcf221185f67` (`feat(ai): delete unposted proposals and explain failures`) |
| Backend | Source and migration `20260823_0036` prepared and fully tested; production service and database remain unchanged |
| App tests | `FiscalKitTests`: 407 passed / 41 suites / 0 failed; focused F3-F model: 31 passed; iOS F3-F UI: 11 passed / 0 failed |
| App builds | Final signed macOS universal Release and iOS arm64 device Release built from the clean source revision |
| Git | Source commit exists locally; release-record commit, immutable `v1.5.5` tag and push are completed as the final preparation step |
| macOS signing | Developer ID Application: ZheYuan Cai (HX73DFL88G); hardened runtime and secure timestamp enabled; no notarization |
| macOS install | Deliberately unchanged: `/Applications/Fiscal.app` remains v1.5.3 (29) |
| iOS delivery | Development-signed arm64 IPA prepared for operator installation; no TestFlight upload or installation |

## Completed fixes

- Pending, failed and ignored AI input that has never produced a transaction or cash-flow item can be deleted through a system confirmation dialog on both macOS and iOS.
- Executed, undone, processing and unknown future states remain protected. The service checks version, status and linked facts under a mutation lock; the database independently rejects direct deletion of protected proposals.
- Deleting an eligible proposal also removes its private source input and quality events. Direct modification or deletion of an individual quality event remains forbidden.
- A delete response with an uncertain outcome never triggers an automatic second DELETE. The client performs a fresh GET and only treats 404 as confirmed deletion.
- Provider failures now distinguish rate limiting, upstream failure, timeout, connection failure, configuration rejection and invalid response. Safe structured logs omit credentials, authorization headers, user text and upstream response bodies.
- iOS now dismisses the keyboard when AI input is submitted so recovery and validation controls remain reachable.

## Verification evidence

- Backend: Ruff format/check passed; Pyright reported 0 errors and 0 warnings; full disposable-PostgreSQL suite passed 393 tests.
- App: focused F3-F model suite passed 31 tests; full shared suite passed 407 tests / 41 suites; iOS F3-F Gallery UI passed all 11 tests, including deletion confirmation/cancellation, user-facing provider failure text, response-unknown recovery and AX5 long content.
- Final `FiscaliOS` generic-simulator Release, `FiscalmacOS` Release, macOS UI `build-for-testing`, signed device builds and `V15GallerySnapshotTool` Release all built successfully.
- macOS F3-F UI automation was attempted three times but the host timed out while enabling automation mode before any business test started. This is not recorded as a pass. The shared macOS UI compiled for testing, and 15 F3-F snapshots supplied light, dark, error and AX5 visual evidence.
- Signed macOS and iOS products passed strict deep signature verification before packaging and after extraction. Extracted executable hashes exactly match their signed source products.
- Both apps report `1.5.5 (31)`, target `https://fiscal.linotsai.top`, and `git diff --check` passed before the source commit.

## Artifacts

Directory: `build/release-v1.5.5-31/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.5.5-build31.zip` | `62a4a9f5c8042b348146293dc1a4cbe4a57b72bc3fb890a4cc2c82781d4fcdb5` |
| `Fiscal-macOS-v1.5.5-build31-dSYM.zip` | `3cca5cf8ea4de3078dcf465a2cd561d648e2f4c3c6470c46afab2b8c05d3ec3d` |
| `Fiscal-iOS-v1.5.5-build31-development.ipa` | `89e585ed6e5ad07626ba7c1c7527ce95bf75fdf8d60730d7d59d57f39cb04081` |
| `Fiscal-iOS-v1.5.5-build31-dSYM.zip` | `5634eeebaf9be39a8d71d2e0bf20bcd62929333bdce5cd19434ae6e1682c6a48` |
| `RELEASE.txt` | `2ca8153346d30fe98569434659be6f8869e7b89f1c98beecdc0be705a7f2e794` |

`SHA256SUMS` covers all five files and passed full verification. The macOS signed-source and extracted executable hash is `54746f33b32903f2779724430b2e1aced15a75da75286ae6ada3dfe8c1d6c9ee`; the corresponding iOS hash is `265576eb71e0a9495090ef5f419ef35e70ec5465cacfe14da33e0c1a8e6ab79c`.

## Deployment handoff and rollback boundary

- Backend deployment is intentionally not run. The prepared entry point is `sudo Backend/ops/production/scripts/deploy.sh --source /path/to/Fiscal`; it must be reviewed in dry-run mode before adding `--apply`.
- Before apply, record the live `/opt/fiscal/current` revision as the application rollback target. The deploy workflow creates and verifies a pre-migration backup before applying `20260823_0036`, then creates a second current-head backup.
- Application rollback may use `rollback.sh` only if the target release has the same Alembic head as the live database. Because v1.5.5 changes schema, a post-migration rollback to the previous application is expected to require deliberate restoration of the verified pre-migration dump into a new database rather than `alembic downgrade`.
- macOS replacement is intentionally not run. The prepared replacement source is the verified app inside `Fiscal-macOS-v1.5.5-build31.zip`; the currently installed v1.5.3 app remains the immediate local fallback until the operator authorizes the swap.

## Deliberately not performed

- No production Backend deployment, database migration, server restart, authenticated production smoke or production data access.
- No replacement or launch of `/Applications/Fiscal.app`.
- No iOS installation, App Store upload or TestFlight upload.
- No Apple notarization.
