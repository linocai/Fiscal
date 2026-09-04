# Fiscal v2.0.0 release state

## v2.0.0 (Build 38) — current client release

| Field | Released state |
| --- | --- |
| Scope | V2 product and frontend upgrade for iPhone and macOS: the daily experience is reduced to current financial position, recent changes, known future events and contextual action; duplicate entry points and the module-hall structure are removed while credit, installments, reimbursements, cash flow, reporting, review/import and governance remain reachable from their financial context |
| Source revision | `bf5b9c99443a5184a83319b605dd691577d5987f` (`feat: release Fiscal v2.0.0`) |
| Git | Source revision pushed to `origin/main`; immutable annotated tag `v2.0.0` pushed, tag object `644dbc9ccebead2f243e19134adf7f218ae02242`, and dereferences to the source revision |
| Backend | Ningbo production intentionally remains at revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4`; Alembic remains `20260831_0038` |
| App tests | `FiscalKitTests`: 405 passed / 0 failed in 39 suites; `V15RootSmokeiOS`: 7 passed / 0 failed; `V15RootSmokemacOS`: 4 passed / 0 failed; iOS generic Simulator Release and macOS Release builds passed |
| Visual acceptance | iPhone 13 at 390×844 was inspected in light, dark, AX5 and long-money states; macOS was inspected at standard 1400×850, minimum 1000×760 and offline 1100×760 window sizes |
| App builds | Developer-ID-signed macOS universal Release and development-signed iOS arm64 device Release built from the clean tagged source revision |
| macOS install | `/Applications/Fiscal.app` replaced, strictly verified and launched as `2.0.0 (38)`; the live V2 workspace loaded Ningbo production data |
| iOS delivery | Development-signed arm64 IPA copied to `/Users/linotsai/Downloads/Fiscal-iOS-v2.0.0-build38-development.ipa` for operator installation |

### Production verification

- The cumulative delta from the actual Ningbo production revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4` to the v2.0.0 source revision contains no `Backend/` change. No server deployment, database migration, service restart or release-only backup was necessary or performed.
- `/opt/fiscal/current` remains `/opt/fiscal/releases/64cb1aee0190`; release metadata and the live database both report Alembic `20260831_0038` and the schema is current.
- `fiscal-api.service` is active/enabled with zero restarts and successful main status. `fiscal-backup.timer`, `fiscal-restore-verify.timer`, `fiscal-health-check.timer` and `fiscal-disk-check.timer` are active/enabled.
- The latest operational backup is `/var/lib/fiscal/backups/fiscal-20260903T193310Z.dump`; its manifest verified `OK`, and the latest-backup record reports 415050 bytes. The latest restore verification is successful, and the latest disk check is healthy at 24% used.
- Local readiness returned 200; public liveness returned 200; public readiness remained deliberately blocked with 403; an unauthenticated protected request returned 401. AliDNS and Google DoH both resolved `fiscal.linotsai.top` to `114.66.2.205`.
- The public certificate retains SHA-256 fingerprint `81:45:DD:B1:43:1C:4D:CE:D5:B2:1B:0D:1C:59:17:21:79:8D:EC:03:48:25:1D:9C:8A:3D:DE:AF:69:32:35:23` and expires 2026-10-14. Authenticated operations status and monthly report v2 returned 200; a nonexistent action receipt returned the expected 404 without performing a write.

### Final Apple gates

- The clean detached release source passed 405/405 `FiscalKitTests` in 39 suites, the generic iOS Simulator Release build and the macOS Release build.
- The full iOS Root Smoke suite passed 7/7 on `Fiscal-B7-iPhone13` (390×844, iOS 26.5). It covered formal cold launch, live local read routes, transport failure and offline recovery, compact root navigation, ledger scope/time navigation, governance paths, light/dark/AX5 rendering and long-money bounds.
- The full macOS Root Smoke suite passed 4/4. It covered formal cold launch, live local read routes, transport failure and offline recovery, the three V2 financial spaces, contextual domain entry points and return behavior.
- Manual visual review separately inspected the iPhone light, dark, AX5 and long-money attachments; macOS dark-mode V2 at 1400×850 and 1000×760; and the complete offline/read-only presentation at 1100×760. Key amounts, titles, navigation, creation actions, event rows, inspector and offline status remained visible and readable.
- Root Smoke used an isolated PostgreSQL database migrated to `20260831_0038`. The local API was stopped, the disposable database and custom smoke Keychain state were removed, and no test data reached production.
- Six pre-existing local Xcode scheme modifications were excluded from the source commit and remain untouched in the operator worktree.

### Signed applications and artifacts

- Source products and extracted delivery packages passed `codesign --verify --deep --strict`; ZIP/IPA integrity checks passed, and extracted executable hashes exactly match the signed products. Both apps report `2.0.0 (38)`.
- macOS uses `Developer ID Application: ZheYuan Cai (HX73DFL88G)`, hardened runtime and a secure timestamp. It is universal `x86_64 arm64`; executable SHA-256 is `4f2a3f6a14576f521f4de220f81af27d0422340a99b3e1cf96c5774a318e02b2`.
- iOS uses `Apple Development: linocai@hotmail.com (J6H3FXT658)`, is `arm64`, and uses profile `c2ca777b-b04b-484e-826e-eef28085a121`, valid through 2027-07-21. Its executable SHA-256 is `4fa88bafb90316253630f3efdf2e126b32e78eae8cbc2643b68ab1c88a209315`.
- macOS app/dSYM UUIDs match for `x86_64` (`65950FD7-3EAC-3C0D-99CE-3B250ECDFF9D`) and `arm64` (`BFF13550-3230-3E4B-A020-32654C68CF4D`). iOS app/dSYM UUIDs match for `arm64` (`953A3B7F-0694-3460-8470-E6B708A8D0C6`).
- Apple notarization, TestFlight and App Store upload were not performed; Gatekeeper therefore reports the expected unnotarized Developer ID state.

Directory: `build/release-v2.0.0-38/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v2.0.0-build38.zip` | `f12f46233e400cb67679cdbea37dfff7d4542572ae27b3cc9690e041f61ef978` |
| `Fiscal-macOS-v2.0.0-build38-dSYMs.zip` | `c916bbfb1a348b4bda56f0a589e4627d2df0f46aa7f158bbfd9deb5cc39868f7` |
| `Fiscal-iOS-v2.0.0-build38-development.ipa` | `78af06a322d16614eb2ced27750745b490037b61f80f83388706ff261c2d3b25` |
| `Fiscal-iOS-v2.0.0-build38-dSYMs.zip` | `ec1175b07cf74e62cb313ab1b0857c839cc1183ac7ad7fb62ba28e9d4b51d5cc` |
| `RELEASE.txt` | `19df45e1f3edf7410d2586454f3f55bbde00472865ab30b60c3c1838e7ff6169` |

`SHA256SUMS` covers all five files and passed full verification. The copy in Downloads has the same IPA hash. Retained release artifacts and logs occupy about 44 MiB; regenerable build intermediates were removed after packaging.

### Installation and rollback boundary

- Current macOS app: `/Applications/Fiscal.app`, `2.0.0 (38)`, strictly verified and running. Immediate application fallback: `/Applications/Fiscal-v1.9.0-build37-backup-20260904-223520.app`, preserving `1.9.0 (37)` with executable SHA-256 `01bb65a5d26db6cb6c486132b7626a659f2540d1145f20cb9ec586ca491099f7`.
- iOS installation remains the operator's action. No iOS device installation is claimed.
- This release does not change the backend or schema, so v1.9.0 is the immediate client-only fallback.
- The existing cross-`0038` rollback restriction remains: never run a blind Alembic downgrade or DNS-only rollback. If a future rollback crosses the schema boundary, first stop writes, create and verify a current backup, restore the correct pre-migration backup into a new target, validate it and only then switch the application.
