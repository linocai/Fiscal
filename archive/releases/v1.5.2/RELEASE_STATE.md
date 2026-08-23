# Fiscal v1.5.2 release state

## v1.5.2 (Build 28)

| Field | Current state |
| --- | --- |
| Scope | macOS monthly-ledger scope hotfix: the main ledger defaults to all transactions while uncategorized remains an independent filter |
| Source revision | `bf12f8a5e1c32fc33e10a7940b5162ce5aaf0ae0` (`fix(frontend): restore macOS monthly ledger scope`) |
| Audit | Month selection, Shanghai month bounds, account/lens reset and history segmentation are recorded in `archive/audits/v1.5.2-build28-macos-ledger-scope-quickfix-2026-08-23.md` |
| Backend | Unchanged; no schema, migration, service or production deployment change |
| Tests | `FiscalKitTests`: 396 passed / 41 suites / 0 failed; targeted monthly-ledger regression: 5 passed / 0 failed |
| App builds | Final macOS universal Release and iOS arm64 device Release built with signing from the clean source revision |
| Git | Source and release-record commits are pushed to `origin/main`; immutable annotated tag `v1.5.2-build28` identifies this build without moving the existing `v1.5.2` Build 26 tag |
| macOS signing | Complete with `Developer ID Application: ZheYuan Cai (HX73DFL88G)`; hardened runtime and secure timestamp enabled; no notarization |
| macOS install | `/Applications/Fiscal.app` replaced with v1.5.2 (28), strictly verified, byte-hash matched to the signed source app and successfully launched |
| iOS / TestFlight | Development-signed arm64 IPA produced for operator installation; no TestFlight upload |

### Build 28 artifacts

Directory: `build/release-v1.5.2-28/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.5.2-build28.zip` | `f40bfff751d98f5e5e02b3a26fab89929de68e3991d43ab912074ab09ccb8336` |
| `Fiscal-macOS-v1.5.2-build28-dSYM.zip` | `7ce4a53f2edd7d83571ec40f1fcf3f8a0bb0ef69335f1bc1d6584680396f2d50` |
| `Fiscal-iOS-v1.5.2-build28-development.ipa` | `bf6f40dbd5c484f33be7ee9215e43bf6c61d40999cb9dfa68c2d541d9b953c01` |
| `Fiscal-iOS-v1.5.2-build28-dSYM.zip` | `179f80941d6ffc71beb3878aa42d72bb4d2920f357c55da9cd6df6f6238f820e` |
| `RELEASE.txt` | `92ea703ad944676ae208acdd4ae01fc6f752b18aa7cb8e0837e76d01c4ee1136` |

`SHA256SUMS` covers all five files and passed full verification. Both packaged apps passed strict deep signature verification after extraction. The macOS executable in `/Applications/Fiscal.app` has SHA-256 `95c07f09ecdb8e0ce2f6efbfed0f3735202af9ca8efd76bc31b66dabab67c6c6`, identical to the signed build source and the extracted archive.

### Build 28 deployment and recovery

- Installed application: `/Applications/Fiscal.app`, v1.5.2 (28), launched as PID-confirmed `/Applications/Fiscal.app/Contents/MacOS/Fiscal`.
- Recoverable previous application: `/Applications/Fiscal-v1.5.2-build27-backup-20260823-1446.app`.
- iOS provisioning: `iOS Team Provisioning Profile: *`, UUID `c2ca777b-b04b-484e-826e-eef28085a121`, valid through 2027-07-21; device installation is left to the operator.
- Both apps use `https://fiscal.linotsai.top` and report `1.5.2 (28)`.

### Build 28 deliberately not performed

- No Apple notarization, App Store upload or TestFlight upload.
- No iOS device installation; installation is operator-managed.
- No Backend/schema/migration or production-service change.

## v1.5.2 (Build 27)

| Field | Current state |
| --- | --- |
| Scope | User-language hotfix for the formal macOS and iOS frontends; internal safety contracts remain unchanged |
| Source revision | `8a25baa9819d4d6afd69c857601325de2ab91331` (`fix(frontend): simplify user language for build 27`) |
| Audit | Engineering-facing navigation metaphors, raw IDs/versions/revisions/codes and manual UUID inputs were removed from the user workflow; full register is `archive/audits/v1.5.2-build27-user-language-quickfix-2026-08-23.md` |
| Backend | Unchanged; no schema, migration, service or production deployment change |
| Tests | `FiscalKitTests`: 393 passed / 40 suites / 0 failed |
| App builds | Final macOS universal Release and iOS arm64 device Release built with signing from the clean source revision |
| Git | Source and release-record commits are pushed to `origin/main`; immutable annotated tag `v1.5.2-build27` identifies this build without moving the existing `v1.5.2` Build 26 tag |
| macOS signing | Complete with `Developer ID Application: ZheYuan Cai (HX73DFL88G)`; hardened runtime and secure timestamp enabled; no notarization |
| macOS install | `/Applications/Fiscal.app` replaced with v1.5.2 (27), strictly verified, byte-hash matched to the signed source app and successfully launched |
| iOS / TestFlight | Development-signed arm64 IPA produced for operator installation; no TestFlight upload |

### Build 27 artifacts

Directory: `build/release-v1.5.2-27/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.5.2-build27.zip` | `05762ac4bf92dffa7d731e56833597823f39b13b7925f09c2b0eb5683edf00d4` |
| `Fiscal-macOS-v1.5.2-build27-dSYM.zip` | `370cdbd0a8ef1cbfd43bf52c705fac09b2c6b4799efe97485e2790268d1a2d33` |
| `Fiscal-iOS-v1.5.2-build27-development.ipa` | `46c11702661a05498c83c210f13322868341ea38814819bcb15ecca57c570788` |
| `Fiscal-iOS-v1.5.2-build27-dSYM.zip` | `1763dfe8516eaf3623038dca18d9422b6de400e2fd3de0125586cb45d8e6cdab` |
| `RELEASE.txt` | `154d1b723ab9acc62bbf55369524458e34861324f5b86a46582676513bba9889` |

`SHA256SUMS` covers all five files and passed full verification. Both packaged apps passed strict deep signature verification after extraction. The macOS executable in `/Applications/Fiscal.app` has SHA-256 `19b6d11e104fc1cc5eebcd226ec3af3ab5173841e453036ccb3c43629b57d63c`, identical to the signed build source.

### Build 27 deployment and recovery

- Installed application: `/Applications/Fiscal.app`, v1.5.2 (27), launched as PID-confirmed `/Applications/Fiscal.app/Contents/MacOS/Fiscal`.
- Recoverable previous application: `/Applications/Fiscal-v1.5.2-build26-backup-20260823-1418.app`.
- iOS provisioning: `iOS Team Provisioning Profile: *`, valid through 2027-07-21; device installation is left to the operator.
- Both apps use `https://fiscal.linotsai.top` and report `1.5.2 (27)`.

### Build 27 deliberately not performed

- No Apple notarization, App Store upload or TestFlight upload.
- No iOS device installation; installation is operator-managed.
- No Backend/schema/migration or production-service change.

## v1.5.2 (Build 26)

| Field | Current state |
| --- | --- |
| Scope | Independent reference-led remediation of the macOS and iOS v1.5.1 frontend against `Fiscal 前端设计启动/` |
| Source revision | `948b610894728de7407119bd4e66269d3dc819d1` (`feat(release): prepare v1.5.2 frontend restoration`) |
| Audit | B7 r7 closes the root normal-state, F2-A boundary and pseudo-field-comparison re-review findings. Remaining limits are registered `CAP-152-*` Backend-contract gaps only. |
| Backend | Unchanged; B7 does not alter schema, migration or service contracts |
| App builds | iOS/macOS Debug and unsigned Release passed after r7; final macOS universal Release and iOS device Release were rebuilt with signing from the clean source revision |
| Tests | `FiscalKitTests`: 393 passed / 40 suites / 0 failed; formal-root UI: 2 passed / 0 failed |
| Visual QA | Three actual normal-state root PNGs plus one separately stored F2-A boundary root PNG were manually inspected |
| Git | The final release-record commit is tagged with annotated `v1.5.2`; `main` and the tag are pushed to `origin` |
| macOS signing | Complete with `Developer ID Application: ZheYuan Cai (HX73DFL88G)`; hardened runtime and secure timestamp enabled; no notarization |
| macOS install | `/Applications/Fiscal.app` replaced with v1.5.2 (26), strictly verified and successfully launched |
| iOS / TestFlight | Development-signed arm64 IPA produced for operator installation; no TestFlight upload |

## Authoritative records

- Frozen audit: `archive/audits/frontend-audit-v1.5.1-2026-08-22.md`.
- Fix and capability register: `archive/audits/v1.5.2-build-gap-register.md`.
- Active workflow and acceptance matrix: `PROJECT_PLAN.md`.
- Reference authority: `Fiscal 前端设计启动/Design/00-HANDOFF.md`, the static `.dc.html` files, clickable prototypes, and the direction/inventory document in that reference directory.

## Release method

The signed applications were built from the clean source revision above in Release configuration.
The macOS application is universal `arm64`/`x86_64`, Developer ID signed, hardened and timestamped.
The iOS application is an `arm64` device build signed with the team's Apple Development identity
and provisioning profile for direct operator installation. Both packaged applications passed
strict signature verification after extraction. Apple notarization and TestFlight upload were
deliberately not performed.

## Artifacts

Directory: `build/release-v1.5.2-26/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.5.2-build26.zip` | `71c7fd28c69ba2fc2e86b69d610fedea646c495a685287ebd5734d64ebe058cd` |
| `Fiscal-macOS-v1.5.2-build26-dSYM.zip` | `9d7f707c535bf868ed2b890799b8a0119df669c2e52e4783b169ac33dcd0a8ea` |
| `Fiscal-iOS-v1.5.2-build26-development.ipa` | `180226dc5350b7f3b307b303cfd0bd9f7d6a543d9b63ac0251c4e7b2cc4603a9` |
| `Fiscal-iOS-v1.5.2-build26-dSYM.zip` | `b347bbc6070b55fb67bdd2094e6a3cf3764acb774b7a5543fb0f22aba1ffd0fb` |
| `RELEASE.txt` | `cf4f6ff46d20fdf6cde82b9a1c95c117e7d756575c7a39ddd88d318e62a03936` |

`SHA256SUMS` covers all five files above and passes full verification.

## Local deployment and recovery

- Installed application: `/Applications/Fiscal.app`, v1.5.2 (26).
- Launch confirmation: process started from `/Applications/Fiscal.app/Contents/MacOS/Fiscal`.
- Recoverable previous application: `/Applications/Fiscal-v1.5.1-build25-backup-20260823-125259.app`.
- iOS installation is left to the operator using the development-signed IPA above.

## Closeout evidence

| Gate | Result |
| --- | --- |
| Patch hygiene | `git diff --check` passed after B7 |
| Shared model tests | 390 tests in 40 suites passed; 0 failures; 47.308 seconds |
| B5 model slice | 150 tests across credit, installments, reimbursements, cash flow, reconciliation, AI, and statement import passed |
| Synthetic visual matrix | 154 PNGs; no zero-size output; representative normal/dark/AX5 states visually inspected |
| iOS Gallery full pass 1 | 89 executed: 83 passed, 6 exposed reachability/keyboard/scroll issues |
| Remediated failures | All six original failures passed targeted reruns after fixes: installment AX5 actions, ledger void reachability, reimbursement receipt preview/commit, refresh partial success, receipt replace/void/restore, and cash-flow create/field errors |
| Adjacent iOS regression | Cash-flow edit/server-owned boundary and settle unknown/readback both passed |
| B7 formal root r7 | `testFormalWorkspaceFixtureRendersAt390x844LightDarkAndAX5` and `testFormalWorkspaceBoundaryKeepsMoneyLocalAndNavigationReachable`: 2/2 passed. Both instantiate `V151IOSWorkspace`; normal state asserts a numeric monthly fact rather than “暂不可用”, while boundary asserts full Int64 amount accessibility, local frame bounds and three hittable bottom actions. |
| B7 screenshots r7 | Normal light/dark/AX5: `archive/releases/v1.5.2/qa/v151-ios-root-390x844-r7/`; F2-A boundary: `archive/releases/v1.5.2/qa/v151-ios-root-boundary-390x844-r7/`. Manually inspected: normal states show `−1,234.56`; no horizontal overflow; AX5 reflows summary vertically; boundary amount is unscaled and local-scrollable. |
| B7 shared suite r7 | `FiscalKitTests`: 393 / 40 suites / 0 failed; result bundle `/private/tmp/fiscal-b7-fiscalkit-r7.xcresult`. |
| iOS Debug | Generic iOS Simulator, unsigned: passed (`/private/tmp/fiscal-b7-r7-ios-debug`) |
| macOS Debug | macOS, unsigned: passed (`/private/tmp/fiscal-b7-r7-macos-debug`) |
| iOS Release | Generic iOS Simulator, unsigned: passed (`/private/tmp/fiscal-b7-r7-ios-release`) |
| macOS Release | macOS universal, unsigned: passed (`/private/tmp/fiscal-b7-r7-macos-release`) |
| Product versions | All four built Info.plists report `CFBundleShortVersionString=1.5.2`, `CFBundleVersion=26` |
| B7 formal-path scan | `rg` over formal V15 paths (excluding Gallery) found no `ProgressView`, `Form`, or `.buttonStyle(.bordered)` primitive. |

The r7 formal-root result is `/private/tmp/fiscal-b7-root-ax5-r7-final.xcresult`.
The r7 B7 full-suite result is `/private/tmp/fiscal-b7-fiscalkit-r7.xcresult`.
The prior r6 root images remain under `qa/v151-ios-root-390x844/` as superseded partial-failure evidence.

## Deliberately not performed

- No Backend/schema/migration or production-service change.
- No Apple notarization.
- No iOS device installation or TestFlight upload; installation is operator-managed.
- No merge or branch operation; release work was performed directly on `main` as authorized.
