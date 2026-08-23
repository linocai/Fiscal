# Fiscal v1.5.3 release state

## v1.5.3 (Build 29)

| Field | Final state |
| --- | --- |
| Scope | Fix `NEXT-01` through `NEXT-04`: post-entry fact refresh, duplicate-submit prevention, macOS single record workspace, and posting-driven account transaction presentation |
| Source revision | `78fd1c321d110dab49a5e93b3e9871499ac610c4` (`fix(frontend): close v1.5.3 interaction backlog`) |
| Backend | Unchanged; no schema, migration, service or production deployment change |
| Tests | `FiscalKitTests`: 401 passed / 41 suites / 0 failed; focused record and ledger regressions: 21 passed / 2 suites / 0 failed |
| App builds | Final macOS universal Release and iOS arm64 device Release built with signing from the clean source revision |
| Git | Source and release-record commits are pushed to `origin/main`; immutable annotated tag `v1.5.3` identifies Build 29 |
| macOS signing | Developer ID Application: ZheYuan Cai (HX73DFL88G); hardened runtime and secure timestamp enabled; no notarization |
| macOS install | `/Applications/Fiscal.app` replaced with v1.5.3 (29), strictly verified, executable-hash matched to the signed source app and successfully launched |
| iOS delivery | Development-signed arm64 IPA produced for operator installation; no TestFlight upload |

## Completed fixes

- Server-confirmed recording now invalidates and refreshes macOS and iOS account, ledger and summary facts without an App restart.
- A successful or queued recording clears the old draft immediately; model-level non-reentrancy prevents a fast double tap from issuing a second create request.
- The macOS recording workspace contains one primary editor instead of a redundant introduction pane plus a fixed narrow editor.
- Account-filtered ledger rows use the selected account's authoritative posting. Transfers and repayments expose both account names and distinguish balance changes from credit-debt changes.
- iOS shares the record lifecycle and account-posting logic; its existing single full-screen editor layout remains intact.

## Artifacts

Directory: `build/release-v1.5.3-29/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.5.3-build29.zip` | `59b34cc6eaa5056d94345176626b4869263d3659339d8ebf615bc1fc8420cc1f` |
| `Fiscal-macOS-v1.5.3-build29-dSYM.zip` | `e869653ba8a0b6076827e95d926475ae7549e7f05f7b70dc7589feb894b3de2d` |
| `Fiscal-iOS-v1.5.3-build29-development.ipa` | `8f17e5d3cef3d9d079b9ea222699e59a2f635d1f402f92b5efb398076a578fb6` |
| `Fiscal-iOS-v1.5.3-build29-dSYM.zip` | `a85d1157010413fc8dd096ffe9b00475d879f142b38d80ea534908f619dd1721` |
| `RELEASE.txt` | `79b4276b8b5ea32e029238c2cbf0067d410a75e2f44716da62798c0281f2833d` |

`SHA256SUMS` covers all five files and passed full verification. Both packaged apps passed strict deep signature verification after extraction. The macOS executable in `/Applications/Fiscal.app` has SHA-256 `85bb3ac49c382be393c4a5206d1a5e4967cb382476d049c379e5556b83c1dc86`, identical to the signed build source and the extracted archive.

## Deployment and recovery

- Installed application: `/Applications/Fiscal.app`, v1.5.3 (29), launched as PID-confirmed `/Applications/Fiscal.app/Contents/MacOS/Fiscal`.
- Recoverable previous application: `/Applications/Fiscal-v1.5.2-build28-backup-20260823-1834.app`.
- iOS provisioning: `iOS Team Provisioning Profile: *`, UUID `c2ca777b-b04b-484e-826e-eef28085a121`, valid through 2027-07-21; device installation is left to the operator.
- macOS is universal `arm64`/`x86_64`; iOS is device `arm64`.
- Both apps use `https://fiscal.linotsai.top` and report `1.5.3 (29)`.

## Verification evidence

- Final shared suite: 401 tests / 41 suites / 0 failures.
- Focused F1-A and F1-B suite: 21 tests / 2 suites / 0 failures.
- Generic iOS Simulator and macOS Debug app targets built successfully before release.
- Signed macOS and iOS Release products passed `codesign --verify --deep --strict` before packaging and again after extraction.
- Packaged executable hashes match their signed source apps; all artifact checksums pass.
- macOS Gallery runtime inspection confirmed the single-editor layout and clean post-save empty state.
- `git diff --check` passed before both the source and release-record commits.

## Deliberately not performed

- No Apple notarization, App Store upload or TestFlight upload.
- No iOS device installation; installation is operator-managed.
- No Backend/schema/migration or production-service change.
