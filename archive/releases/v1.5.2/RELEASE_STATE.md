# Fiscal v1.5.2 source-closeout state

## v1.5.2 (Build 26)

| Field | Current state |
| --- | --- |
| Scope | Independent reference-led remediation of the macOS and iOS v1.5.1 frontend against `Fiscal 前端设计启动/` |
| Source status | BUILD B1–B7 complete; version and generated Xcode project are `1.5.2 (26)` |
| Audit | B7 r7 closes the root normal-state, F2-A boundary and pseudo-field-comparison re-review findings. Remaining limits are registered `CAP-152-*` Backend-contract gaps only. |
| Backend | Unchanged; B7 does not alter schema, migration or service contracts |
| App builds | iOS/macOS Debug and unsigned Release rebuilt after r7 |
| Tests | `FiscalKitTests`: 393 passed / 40 suites / 0 failed; formal-root UI: 2 passed / 0 failed |
| Visual QA | Three actual normal-state root PNGs plus one separately stored F2-A boundary root PNG were manually inspected |
| Git | Working tree only; no commit, tag, or push was authorized or performed |
| Signing/install | Not performed; installed signed macOS application remains v1.5.1 (25) |
| iOS/TestFlight | Not performed; operator-managed |

## Authoritative records

- Frozen audit: `archive/audits/frontend-audit-v1.5.1-2026-08-22.md`.
- Fix and capability register: `archive/audits/v1.5.2-build-gap-register.md`.
- Active workflow and acceptance matrix: `PROJECT_PLAN.md`.
- Reference authority: `Fiscal 前端设计启动/Design/00-HANDOFF.md`, the static `.dc.html` files, clickable prototypes, and the direction/inventory document in that reference directory.

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
- No Apple Developer ID signing, notarization, packaging, or replacement of `/Applications/Fiscal.app`.
- No iOS archive or TestFlight upload.
- No commit, tag, push, merge, or branch operation.

Moving from this source-closeout state to a distributed release requires separate authorization and a clean release operation.
