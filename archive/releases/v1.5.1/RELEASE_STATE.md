# Fiscal v1.5.1 release state

## v1.5.1 (Build 25)

| Field | Current state |
| --- | --- |
| Scope | Frontend-led v1.5.1 corrective release; Backend schema and production service are unchanged |
| Apple composition | Formal iPhone and macOS roots use the approved prototype structure with production V15 services |
| Review | Independent review completed with no P0/P1 release blocker; final sheet-lifecycle P2 fixed before packaging |
| macOS signing | Authorized with `Developer ID Application: ZheYuan Cai (HX73DFL88G)`; no notarization |
| macOS install | Authorized to replace the existing local `/Applications/Fiscal.app` after strict signature verification |
| iOS / TestFlight | Outside this release operation; handled by the operator |
| Git | Authorized annotated `v1.5.1` tag and push of `main` plus tag to `origin` |
| Backend deploy | Not part of this release; no Backend source or production service change |

## Release method

The signed macOS application is built from the clean v1.5.1 source commit. The
artifact directory contains the zipped app, zipped dSYM, `RELEASE.txt`, and
`SHA256SUMS`. Installation preserves the previous application as a timestamped
backup before replacing it. Apple notarization is deliberately not performed,
matching the operator's established release policy.

Exact source revision, artifact hashes, signature verification, installation,
and remote tag state are recorded here by the final release-record commit after
the package and local replacement complete.
