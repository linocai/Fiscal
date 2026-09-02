# Fiscal v1.8.0 release state

## v1.8.0 (Build 36) — current client release

| Field | Released state |
| --- | --- |
| Scope | Complete macOS frontend upgrade across the workspace shell, ledger/account balance board, future cash flow, credit/installment/reimbursement flows, reports and drill-downs, AI/PDF review, system/data, settings and master data; unified responsive layout, controls, state semantics and accessibility while preserving iOS behavior and backend contracts |
| Source revision | `da8cecafe8ccef12961ec57d65ed1972f0576fd0` (`feat: release Fiscal v1.8.0`) |
| Git | Source revision pushed to `origin/main`; immutable annotated tag `v1.8.0` pushed, tag object `079d0c4d95860043e498c58fbcebb3070428d177`, and dereferences to the source revision |
| Backend | Ningbo production intentionally remains at revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4`; Alembic remains `20260831_0038` |
| App tests | `FiscalKitTests`: 399 passed / 0 failed in 39 suites; `V15GallerymacOSUITests`: 35 passed / 0 failed; targeted shared tests: 67/67; targeted macOS unknown-result UI tests: 3/3; macOS Release and iOS generic Simulator Release builds passed |
| App builds | Signed macOS universal Release and iOS arm64 device Release built from the clean immutable tag |
| macOS install | `/Applications/Fiscal.app` replaced, strictly verified and launched as `1.8.0 (36)`; the live workspace loaded production data and displayed the account balance board |
| iOS delivery | Development-signed arm64 IPA copied to `/Users/linotsai/Downloads/Fiscal-iOS-v1.8.0-build36-development.ipa` for operator installation |

### Production verification

- The cumulative delta from the actual Ningbo production revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4` to the v1.8.0 source revision contains no `Backend/` change. No server deployment, database migration, restart or release-only backup was necessary or performed.
- `/opt/fiscal/current` remains `/opt/fiscal/releases/64cb1aee0190`; the live operations endpoint reports release revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4`, live database and release Alembic `20260831_0038`, and schema state `current`.
- `fiscal-api.service` is active/enabled with zero restarts and successful main status. `fiscal-backup.timer`, `fiscal-restore-verify.timer`, `fiscal-health-check.timer` and `fiscal-disk-check.timer` are all active/enabled.
- Local readiness returned 200; public liveness returned 200; public readiness remained deliberately blocked with 403; an unauthenticated protected request returned 401. Independent AliDNS resolution returned `114.66.2.205`, direct-SNI liveness returned 200, and the TLS fingerprint remained the recorded Ningbo certificate.
- Authenticated operations status and monthly report v2 returned 200. A nonexistent action-operation receipt returned the expected 404 without performing a write. Operations status reported database ready, verified backup and restore, and healthy disk state.

### Signed applications and artifacts

- Both source applications and extracted delivery packages passed `codesign --verify --deep --strict`; extracted executable hashes exactly match the signed products. Both apps report `1.8.0 (36)` and target `https://fiscal.linotsai.top`.
- macOS uses `Developer ID Application: ZheYuan Cai (HX73DFL88G)`, hardened runtime and secure timestamp. It is universal `x86_64 arm64`; executable SHA-256 is `3c9cd9abe56d76023aa82326083a986fbfc11984b8ed74e9889856722533e518`.
- iOS uses `Apple Development: linocai@hotmail.com (J6H3FXT658)`, is `arm64`, and uses profile `c2ca777b-b04b-484e-826e-eef28085a121`, valid through 2027-07-21. Its executable SHA-256 is `50c4655d49087d9a0f99ba15f4aae94a01ac910cc9f2e5f524cbe5d1ce0b5441`.
- App and dSYM UUIDs match on both platforms. Apple notarization, TestFlight and App Store upload were not performed.

Directory: `build/release-v1.8.0-36/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.8.0-build36.zip` | `6d6e74ee3eb24bfdc27aeda330f3699c16a7ecaeaf0ae0600dff42ad89f2ed56` |
| `Fiscal-macOS-v1.8.0-build36-dSYMs.zip` | `bba8ae4218842d92605042d3339b00f3b120709f9dc20b83ed67d14f1d95e0e3` |
| `Fiscal-iOS-v1.8.0-build36-development.ipa` | `d29843b474c2ad5f9a695ae8b93186d96453a72aa6fa1eba15b8ee00c21aaf3f` |
| `Fiscal-iOS-v1.8.0-build36-dSYMs.zip` | `e7b05f7b9c4c6e9781ae49c1464018f67511337afe1c48ae93b90e58d817afe7` |
| `RELEASE.txt` | `c708a4ae69d04c058322e8326c40dbd5be25c2b6294559046f5b66dafe820191` |

`SHA256SUMS` covers all five files and passed full verification. The copy in Downloads has the same IPA hash.

### Installation and rollback boundary

- Current macOS app: `/Applications/Fiscal.app`, `1.8.0 (36)`, strictly verified, running and connected to Ningbo production. Immediate application fallback: `/Applications/Fiscal-v1.7.1-build35-backup-20260902-190831.app`, preserving `1.7.1 (35)` with executable SHA-256 `69a9514dc7f605f49e4fa13cd67b1ef7c53c04f2ba468a8d355b413e12393fbb`.
- iOS installation remains the operator's action. No iOS device installation is claimed.
- This release does not change the backend or schema, so the preserved v1.7.1 client is the immediate client-only fallback.
- The existing cross-`0038` rollback restriction remains: never run a blind Alembic downgrade or DNS-only rollback. If a future rollback crosses the schema boundary, first stop writes, create and verify a current backup, restore the correct pre-migration backup into a new target, validate it and only then switch the application.
