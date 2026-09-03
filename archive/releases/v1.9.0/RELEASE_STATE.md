# Fiscal v1.9.0 release state

## v1.9.0 (Build 37) — current client release

| Field | Released state |
| --- | --- |
| Scope | Complete iPhone frontend and interaction upgrade across bootstrap, Today, ledger and account balance board, record flow, future cash flow, credit, installments, reimbursements, reports, AI/PDF review, system/data, settings and master data; modernized hierarchy, controls, navigation, state feedback, keyboard behavior, Dynamic Type and long-content resilience while preserving accounting and backend contracts |
| Source revision | `9fe0f3af914fcccda4a93c56fa08c132c2c7637d` (`feat: release Fiscal v1.9.0`) |
| Git | Source revision pushed to `origin/main`; immutable annotated tag `v1.9.0` pushed, tag object `ef7ed3566680e03dbd957fb4cc99a62c09d6981a`, and dereferences to the source revision |
| Backend | Ningbo production intentionally remains at revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4`; Alembic remains `20260831_0038` |
| App tests | `FiscalKitTests`: 399 passed / 0 failed in 39 suites; `V15GalleryiOS`: 89 passed / 0 failed; `V15RootSmokeiOS`: 6 passed / 0 failed; iOS generic Simulator Release and macOS Release builds passed |
| App builds | Signed macOS universal Release and iOS arm64 device Release built from the clean immutable tag |
| macOS install | `/Applications/Fiscal.app` replaced, strictly verified and launched as `1.9.0 (37)`; the live workspace loaded production data and displayed the account balance board |
| iOS delivery | Development-signed arm64 IPA copied to `/Users/linotsai/Downloads/Fiscal-iOS-v1.9.0-build37-development.ipa` for operator installation |

### Production verification

- The cumulative delta from the actual Ningbo production revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4` to the v1.9.0 source revision contains no `Backend/` change. No server deployment, database migration, restart or release-only backup was necessary or performed.
- `/opt/fiscal/current` remains `/opt/fiscal/releases/64cb1aee0190`; the live operations endpoint reports release revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4`, live database and release Alembic `20260831_0038`, and schema state `current`.
- `fiscal-api.service` is active/enabled with zero restarts and successful main status. `fiscal-backup.timer`, `fiscal-restore-verify.timer`, `fiscal-health-check.timer` and `fiscal-disk-check.timer` are all active/enabled.
- Local readiness returned 200; public liveness returned 200; public readiness remained deliberately blocked with 403; an unauthenticated protected request returned 401. Independent AliDNS and Google DoH resolution returned `114.66.2.205`, direct-SNI liveness returned 200, and the TLS fingerprint remained the recorded Ningbo certificate.
- Authenticated operations status and monthly report v2 returned 200. A nonexistent action-operation receipt returned the expected 404 without performing a write. Operations status reported database ready, verified backup and restore, and healthy disk state.

### Final Apple gates

- The final full release candidate passed 399/399 `FiscalKitTests`, 89/89 iOS Gallery UI tests and 6/6 iOS Root Smoke UI tests on the existing iPhone 17 Pro / iOS 26.5 simulator. No older iPhone, iPad or pre-iOS-26 compatibility scope was added.
- Root Smoke used a disposable local PostgreSQL database migrated to `20260831_0038`; it proved real local API bootstrap, live read navigation, offline recovery, light/dark/AX5 rendering, long-money bounds and the account balance board. The local API was stopped and the disposable database was removed after the suite passed.
- Both generic iOS Simulator Release and macOS Release target builds passed. Six long-existing local Xcode scheme modifications were excluded from the source commit and remain untouched in the operator worktree.

### Signed applications and artifacts

- Both source applications and extracted delivery packages passed `codesign --verify --deep --strict`; extracted executable hashes exactly match the signed products. Both apps report `1.9.0 (37)` and target `https://fiscal.linotsai.top`.
- macOS uses `Developer ID Application: ZheYuan Cai (HX73DFL88G)`, hardened runtime and secure timestamp. It is universal `x86_64 arm64`; executable SHA-256 is `01bb65a5d26db6cb6c486132b7626a659f2540d1145f20cb9ec586ca491099f7`.
- iOS uses `Apple Development: linocai@hotmail.com (J6H3FXT658)`, is `arm64`, and uses profile `c2ca777b-b04b-484e-826e-eef28085a121`, valid through 2027-07-21. Its executable SHA-256 is `5d5bec0d56030ce5139fc21ca4f4cc31a5c287fd917cefbcbab63eba1c19e786`.
- App and dSYM UUIDs match on both platforms. Apple notarization, TestFlight and App Store upload were not performed.

Directory: `build/release-v1.9.0-37/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.9.0-build37.zip` | `0deb8c75a7968b79f7310697c7dbb21dfc3b3f20e6483b449fb59f2a0139cc53` |
| `Fiscal-macOS-v1.9.0-build37-dSYMs.zip` | `00dfa9df890f2a8995f906c82f97d79b8fb2b8aee57d8205191f29c92c4835c0` |
| `Fiscal-iOS-v1.9.0-build37-development.ipa` | `4266362c9b15b8a8a49d1ac2d25dceddf93e96a185e13e4e3fc77fe9902d3a0c` |
| `Fiscal-iOS-v1.9.0-build37-dSYMs.zip` | `9bf402ba042ae171060067d5173d8cbf2cbadf2f61d9507ec9242cdc1c922ff7` |
| `RELEASE.txt` | `2a9643ae0d4fb251f6e6b6941d4b5edd4269a7b2e7ab0442a4a9e997e0e8d4f1` |

`SHA256SUMS` covers all five files and passed full verification. The copy in Downloads has the same IPA hash. Regenerable unsigned and signed build intermediates were removed after packaging; retained release artifacts and logs occupy about 45 MiB.

### Installation and rollback boundary

- Current macOS app: `/Applications/Fiscal.app`, `1.9.0 (37)`, strictly verified, running and connected to Ningbo production. Immediate application fallback: `/Applications/Fiscal-v1.8.0-build36-backup-20260903-170948.app`, preserving `1.8.0 (36)` with executable SHA-256 `3c9cd9abe56d76023aa82326083a986fbfc11984b8ed74e9889856722533e518`.
- iOS installation remains the operator's action. No iOS device installation is claimed.
- This release does not change the backend or schema, so the preserved v1.8.0 client is the immediate client-only fallback.
- The existing cross-`0038` rollback restriction remains: never run a blind Alembic downgrade or DNS-only rollback. If a future rollback crosses the schema boundary, first stop writes, create and verify a current backup, restore the correct pre-migration backup into a new target, validate it and only then switch the application.
