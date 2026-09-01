# Fiscal v1.7.0 release state

## v1.7.0 (Build 34) — current production release

| Field | Released state |
| --- | --- |
| Scope | macOS five-module workspace reset, ledger context controls moved into the workspace, future/report/system entry consolidation, and full retirement of the balance-reconciliation feature and data tables while preserving one-release read compatibility for installed v1.6 clients |
| Source revision | `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4` (`feat: release Fiscal v1.7.0`) |
| Git | Source revision pushed to `origin/main`; immutable annotated tag `v1.7.0` pushed and dereferences to the source revision |
| Backend | Ningbo production active at the source revision; Alembic `20260831_0038` |
| App tests | `FiscalKitTests`: 391 passed / 0 failed; iOS generic simulator and macOS application builds passed; final macOS RootSmoke passed 1/1 |
| Backend tests | Full disposable-PostgreSQL suite: 394 passed; Ruff format/check and Pyright passed |
| App builds | Signed macOS universal Release and iOS arm64 device Release built from the clean immutable tag |
| macOS install | `/Applications/Fiscal.app` replaced, strictly verified and launched as `1.7.0 (34)` |
| iOS delivery | Development-signed arm64 IPA copied to `~/Downloads/Fiscal-iOS-v1.7.0-build34-development.ipa` for operator installation |

### Production deployment and verification

- The release audited the cumulative delta from the actual Ningbo production revision `dee89464c0404dc31cc59b19ae57bf7d15e4716a` and Alembic `20260830_0037` to the target release.
- The production deploy dry-run reported no state mutation. The apply path reran format, lint, type and database-independent release gates, then created and verified pre-migration backup `fiscal-20260901T065638Z.dump` (419,965 bytes; SHA-256 `16216d35261f7febf095df72e23bcb0bbfccff0d912f290177820a5b1dfcbd1a`).
- Alembic upgraded linearly from `20260830_0037` to `20260831_0038`. Post-migration backup `fiscal-20260901T065639Z.dump` was then created and verified (415,046 bytes; SHA-256 `c045b6f09d26c05f56b1c7b558b9f9a759e1dec8ee7f73fb31723247a87ae34d`). Both dumps passed their SHA-256 manifests and `pg_restore --list`; the post-migration `fiscal-restore-verify.service` run completed successfully.
- Core data remained 7 accounts, 230 transactions, 252 postings, 23 credit cycles and 0 statement imports. `reconciliation_checkpoints` and `attention_dismissals` are absent after migration. `/reconciliation/*` returns 404, the public OpenAPI has no reconciliation routes or retired fields, and the one-release legacy report shim still returns safe `0/null` placeholders to v1.6 clients.
- `/opt/fiscal/current` resolves to `/opt/fiscal/releases/64cb1aee0190`; `fiscal-api.service` is active/enabled with zero restarts, successful main status and no post-deploy warning journal entries. All four Fiscal maintenance timers are active/enabled.
- Local readiness returned database-ready, public liveness returned 200, public readiness remained deliberately blocked with 403, and an unauthenticated protected read returned 401.
- Authenticated production reads passed for operations status, monthly reporting v2, the one-release legacy monthly/facts responses and a nonexistent action-operation receipt (404 without performing a write). The only failed system unit remains the pre-existing non-Fiscal `systemd-networkd-wait-online.service` documented in `NB_info.md`.

### Signed applications and artifacts

- Both source applications and extracted delivery packages passed `codesign --verify --deep --strict`; extracted executable hashes exactly match the signed products. Both apps report `1.7.0 (34)` and target `https://fiscal.linotsai.top`.
- macOS uses `Developer ID Application: ZheYuan Cai (HX73DFL88G)`, hardened runtime and secure timestamp. It is universal `x86_64 arm64`; executable SHA-256 is `fadb9361be442e79f1ea45226d993251f2ddeaf6e5dd5bad5558fe818262d9f9`.
- iOS uses Apple Development signing, is `arm64`, and uses profile `c2ca777b-b04b-484e-826e-eef28085a121`, valid through 2027-07-21. Its executable SHA-256 is `6c6969fd18aa8c3f72336132183b460d849a547a92f30984cf3238c954d9021f`.
- Apple notarization, TestFlight and App Store upload were not performed.

Directory: `build/release-v1.7.0-34/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.7.0-build34.zip` | `c747d98946907ab359a67ff0c57a19c1df21fc085f0068d8e9d2f736501ab488` |
| `Fiscal-macOS-v1.7.0-build34-dSYM.zip` | `10071a4372e7e83bc56468634d51fb8498ef5589c9a30df2676d90486c9e45f2` |
| `Fiscal-iOS-v1.7.0-build34-development.ipa` | `a4d2620de090f3d69252b2ec8c3643447d754cd20b727e664e3dd001481c3a21` |
| `Fiscal-iOS-v1.7.0-build34-dSYM.zip` | `30e2bab6dc452eac163b55ad9c6ee59f229f6c7f777f3f135e89c05c199bae5d` |
| `RELEASE.txt` | `8b9ea80d25e48df36fca0163433091839b172477eb64f6bde293ca57b3bcc752` |

`SHA256SUMS` covers all five files and passed full verification. The copy in Downloads has the same IPA hash.

### Installation and rollback boundary

- Current macOS app: `/Applications/Fiscal.app`, `1.7.0 (34)`, strictly verified and running. Immediate application fallback: `/Applications/Fiscal-v1.6.0-build33-backup-20260901-150039.app`, preserving `1.6.0 (33)`. The earlier v1.5.5 backup also remains untouched.
- iOS installation remains the operator's action. No iOS device installation was claimed.
- The previous server release remains `/opt/fiscal/releases/dee89464c040`, but application-only rollback across the `0038` schema boundary is forbidden.
- For a cross-schema rollback, first stop writes, create and verify a new current Ningbo backup, restore `fiscal-20260901T065638Z.dump` into a new target, validate data and schema, and only then switch the application. Never run a blind Alembic downgrade or DNS-only rollback.
