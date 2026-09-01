# Fiscal v1.7.1 release state

## v1.7.1 (Build 35) — current client release

| Field | Released state |
| --- | --- |
| Scope | macOS ledger account balance board with directly visible asset/debt summary and all active account cards; account filter/detail state retention; duplicate report/system/settings title cleanup; macOS settings information-architecture cleanup |
| Source revision | `c1e53f9f259abb0307fafd0e78487c6d52235d05` (`feat: release Fiscal v1.7.1`) |
| Git | Source revision pushed to `origin/main`; immutable annotated tag `v1.7.1` pushed and dereferences to the source revision |
| Backend | Ningbo production intentionally remains at revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4`; Alembic remains `20260831_0038` |
| App tests | `FiscalKitTests`: 392 passed / 0 failed; iOS generic simulator and macOS application builds passed; final macOS RootSmoke passed 1/1; independent code and visual review reported no findings |
| App builds | Signed macOS universal Release and iOS arm64 device Release built from the clean immutable tag |
| macOS install | `/Applications/Fiscal.app` replaced, strictly verified and launched as `1.7.1 (35)` with the live account balance board visible |
| iOS delivery | Development-signed arm64 IPA copied to `~/Downloads/Fiscal-iOS-v1.7.1-build35-development.ipa` for operator installation |

### Production verification

- The cumulative delta from the actual Ningbo production revision `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4` to the v1.7.1 source revision contains no `Backend/` change. No server deployment, database migration or backup was necessary or performed.
- `/opt/fiscal/current` remains `/opt/fiscal/releases/64cb1aee0190`; its release metadata and live database both report Alembic `20260831_0038`. `fiscal-api.service` remains active/enabled and all four Fiscal maintenance timers remain active/enabled.
- Local readiness returned database-ready, public liveness returned 200, public readiness remained deliberately blocked with 403, and an unauthenticated protected account read returned 401.
- Authenticated production reads passed for operations status, monthly report v2 and a nonexistent action-operation receipt (404 without performing a write). Operations status reported current schema, verified backup/restore state and healthy disk state.

### Signed applications and artifacts

- Both source applications and extracted delivery packages passed `codesign --verify --deep --strict`; extracted executable hashes exactly match the signed products. Both apps report `1.7.1 (35)` and target `https://fiscal.linotsai.top`.
- macOS uses `Developer ID Application: ZheYuan Cai (HX73DFL88G)`, hardened runtime and secure timestamp. It is universal `x86_64 arm64`; executable SHA-256 is `69a9514dc7f605f49e4fa13cd67b1ef7c53c04f2ba468a8d355b413e12393fbb`.
- iOS uses Apple Development signing, is `arm64`, and uses profile `c2ca777b-b04b-484e-826e-eef28085a121`, valid through 2027-07-21. Its executable SHA-256 is `2ccc658fdf76729c5663fc3d87887f7510cef65908b99add7a6206776b999564`.
- Apple notarization, TestFlight and App Store upload were not performed.

Directory: `build/release-v1.7.1-35/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.7.1-build35.zip` | `6f2ff4164e52e8d14c16bcdd5d87d7c9c0f45da092069dff776af46474888aa3` |
| `Fiscal-macOS-v1.7.1-build35-dSYM.zip` | `5809785d31904d543264c70fb3d8cafbd22037fc013365429078c064157c2191` |
| `Fiscal-iOS-v1.7.1-build35-development.ipa` | `a1eafda21d235ebd2930da375379fc1bb9867d5389f9b83193520aad233a831b` |
| `Fiscal-iOS-v1.7.1-build35-dSYM.zip` | `1384120bf863aa049fb849592f99a0d3cafc0bddb0aa4ac9ad434390ce472dbe` |
| `RELEASE.txt` | `f696294bcf42186c23f40a97b7c60ef13e27eaae2e2662f171f5001bf4c46db6` |

`SHA256SUMS` covers all five files and passed full verification. The copy in Downloads has the same IPA hash.

### Installation and rollback boundary

- Current macOS app: `/Applications/Fiscal.app`, `1.7.1 (35)`, strictly verified and running. Immediate application fallback: `/Applications/Fiscal-v1.7.0-build34-backup-20260901-165027.app`, preserving `1.7.0 (34)` with executable hash `fadb9361be442e79f1ea45226d993251f2ddeaf6e5dd5bad5558fe818262d9f9`.
- iOS installation remains the operator's action. No iOS device installation was claimed.
- This release does not change the backend or schema, so the preserved v1.7.0 client is the immediate client-only fallback.
- The existing cross-`0038` rollback restriction remains: never run a blind Alembic downgrade or DNS-only rollback. If a future rollback crosses the schema boundary, first stop writes, create and verify a current backup, restore the correct pre-migration backup into a new target, validate it and only then switch the application.
