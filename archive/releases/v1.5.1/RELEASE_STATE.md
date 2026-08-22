# Fiscal v1.5.1 release state

## v1.5.1 (Build 25)

| Field | Current state |
| --- | --- |
| Scope | Frontend-led v1.5.1 corrective release; Backend schema and production service are unchanged |
| Apple composition | Formal iPhone and macOS roots use the approved prototype structure with production V15 services |
| Review | Independent review completed with no P0/P1 release blocker; final sheet-lifecycle P2 fixed before packaging |
| Source revision | `558ec4a53155b4966279e6c9ead1a7f37b676198` (`release: prepare v1.5.1 frontend`) |
| macOS signing | Complete with `Developer ID Application: ZheYuan Cai (HX73DFL88G)`; hardened runtime; no notarization |
| macOS install | `/Applications/Fiscal.app` replaced with v1.5.1 (25), strictly verified and successfully launched |
| iOS / TestFlight | Outside this release operation; handled by the operator |
| Git | Authorized annotated `v1.5.1` tag and push of `main` plus tag to `origin` |
| Backend deploy | Not part of this release; no Backend source or production service change |

## Release method

The signed macOS application was built from the clean v1.5.1 source revision
above in Release configuration as a universal `arm64`/`x86_64` application.
Both the built application and the application extracted from the distribution
archive passed strict deep signature verification. Apple notarization was
deliberately not performed, matching the operator's established release policy.

## Artifacts

Directory: `build/release-v1.5.1-25/artifacts/`

| Artifact | SHA-256 |
| --- | --- |
| `Fiscal-macOS-v1.5.1-build25.zip` | `0bb466fc1267f04c904c459006d2d1a97bb8044e25483d1c2c3a5c53518d2960` |
| `Fiscal-macOS-v1.5.1-build25-dSYM.zip` | `3fc73ba661a03314f7cc380766a4f883244a66650cbc6a03f85143cc7ced6e51` |
| `RELEASE.txt` | `cd811a643e34b6af7a7af33a185ac6ad9eb75c36de6ae622a79b121de650d5e8` |

The directory also contains `SHA256SUMS` covering the three files above.

## Local deployment and recovery

- Installed application: `/Applications/Fiscal.app`, v1.5.1 (25).
- Launch confirmation: process started from `/Applications/Fiscal.app/Contents/MacOS/Fiscal`.
- Recoverable previous application: `/Applications/Fiscal-v1.5.0-build24-backup-20260822-1639.app`.
- Final Git operation: create annotated `v1.5.1` on this release-record commit and push `main` plus the tag to `origin`.
- Explicitly not performed: Apple notarization, iOS/TestFlight work, and Backend deployment.
