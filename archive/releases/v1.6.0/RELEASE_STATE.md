# Fiscal v1.6.0 release state

## v1.6.0 (Build 33) — current production release

| Field | Released state |
| --- | --- |
| Scope | Formal server-preview write flows, same-revision reporting v2, account reconciliation history, safe known-future navigation, truthful local-login recovery, and the reviewed dual-platform workflow/visual repairs |
| Source revision | `dee89464c0404dc31cc59b19ae57bf7d15e4716a` (`feat: release Fiscal v1.6.0`) |
| Git | Source revision pushed to `origin/main`; immutable annotated tag `v1.6.0` pushed and dereferences to the source revision |
| Backend | Ningbo production active at the source revision; Alembic `20260830_0037` |
| App tests | `FiscalKitTests`: 420 passed / 41 suites / 0 failed; iOS generic simulator and macOS application builds passed |
| Backend tests | Full disposable-PostgreSQL suite: 399 passed; Ruff format/check and Pyright passed |
| App builds | Signed macOS universal Release and iOS arm64 device Release built from the clean immutable tag |
| macOS install | `/Applications/Fiscal.app` replaced, strictly verified and launched as `1.6.0 (33)` |
| iOS delivery | Development-signed arm64 IPA copied to `~/Downloads/Fiscal-iOS-v1.6.0-build33-development.ipa` for operator installation |

### Production deployment and verification

- The release audited the cumulative delta from the actual Ningbo production revision `3eb49cbc4151aa06b0dacecc7025ad2ed7d85f42` and Alembic `20260823_0036` to the target release.
- The production deploy dry-run reported no state mutation, the apply path reran format, lint, type and database-independent release gates, then created and verified pre-migration backup `fiscal-20260831T022012Z.dump`.
- Alembic upgraded linearly from `20260823_0036` to `20260830_0037`. Post-migration backup `fiscal-20260831T022014Z.dump` was then created and verified. Both dumps passed their SHA-256 manifests and `pg_restore --list`; their sizes are 413,734 and 418,310 bytes respectively.
- `/opt/fiscal/current` resolves to `/opt/fiscal/releases/dee89464c040`; `fiscal-api.service` is active/enabled with zero restarts and successful main status. All four Fiscal maintenance timers are active.
- Local readiness returned database-ready, public liveness returned 200, public readiness remained deliberately blocked with 403, and an unauthenticated protected read returned 401.
- Authenticated production reads passed for system status and monthly reporting v2. A lookup of a nonexistent action-operation receipt returned 404 after authentication, confirming the new protected route was active without performing a write.

### Signed applications and artifacts

- Both source applications and extracted delivery packages passed `codesign --verify --deep --strict`; extracted executable hashes exactly match the signed products.
- macOS uses `Developer ID Application: ZheYuan Cai (HX73DFL88G)`, hardened runtime and secure timestamp. It is universal `x86_64 arm64`; executable SHA-256 is `ef1a3fd511522da7889a5352f57e179abd59442ff51d267c5291db6c49f6a57d`.
- iOS uses Apple Development signing, is `arm64`, and uses profile `c2ca777b-b04b-484e-826e-eef28085a121`, valid through 2027-07-21. Its executable SHA-256 is `01e205a88b78bb0df1bba4d3a83d910de85583c031fa7c112df84ecffcb44f3f`.
- Both apps report `1.6.0 (33)` and target `https://fiscal.linotsai.top`. Apple notarization, TestFlight and App Store upload were not performed.

Directory: `build/release-v1.6.0-33/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.6.0-build33.zip` | `4e427f4c93afaf2d4ba47fd85fbaeba3eda07fa53284382a625254a5002476fc` |
| `Fiscal-macOS-v1.6.0-build33-dSYM.zip` | `e676a8e34c41b99faa16ada628d9f3565c911d906e0624c31319d69a45ef864a` |
| `Fiscal-iOS-v1.6.0-build33-development.ipa` | `0b28aabbd94a4fb830ae27b0d23a700f325e7c186debeced395122b6cb01514b` |
| `Fiscal-iOS-v1.6.0-build33-dSYM.zip` | `369161d5a2a0f37715e62d0b2608f9104962538c3574e3f3d5011b4d11c6a163` |
| `RELEASE.txt` | `cc0d0de3a72ce66bc1b7588e23d6a43f48d1698c8b5c2e0b9600f7e823ecf00c` |

`SHA256SUMS` covers all five files and passed full verification. The copy in Downloads has the same IPA hash.

### Installation and rollback boundary

- Current macOS app: `/Applications/Fiscal.app`, `1.6.0 (33)`, strictly verified and running. Immediate application fallback: `/Applications/Fiscal-v1.5.5-build32-backup-20260831-102147.app`, preserving `1.5.5 (32)`.
- iOS installation remains the operator's action. No iOS device installation was claimed.
- The previous application revision remains `/opt/fiscal/releases/3eb49cbc4151`, but application-only rollback across the `0037` schema boundary is forbidden.
- For a cross-schema rollback, first stop writes, create and verify a new current Ningbo backup, restore `fiscal-20260831T022012Z.dump` into a new target, validate data and schema, and only then switch the application. Never run a blind Alembic downgrade or DNS-only rollback.
