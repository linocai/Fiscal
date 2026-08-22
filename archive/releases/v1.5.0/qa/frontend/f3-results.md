# v1.5.0 F3-A — Independent implementation review verified

Date: 2026-08-15 (Asia/Shanghai)
Status: Independent implementation review verified; `F3A-MAC-UI-AUTOMATION` deferred. F3-B1 may begin; F3-B2 and later blocks remain locked.

## Scope and contract

Implemented the read-only `GET /api/v1/reports/future-events` boundary for the exact server windows `7/30/60/90`, optional account filter, opaque cursor and `1...100` limit.  The typed decode preserves `meta`, server window/account, all three source types, both directions, four certainties, minor-unit amount, date and locator. `future_events_scope_changed` is a visible 409 reload gate: it clears the stale scope, bypasses cache on the next root read, and rejects older revisions. No write endpoint, client forecast/calculation, raw transport, old DTO/repository, overview, or formal root was added.

The local event inspector accepts only the source-matched fiscal locator path with the matching UUID. It rejects query, fragment, host/path and ID mismatches before any request. UUID comparison accepts the lower-case canonical value returned by the Python API.

## First-review fixes (2×P2)

1. The review correctly identified that `reimbursement_party` does not use the two-segment placeholder route. Backend `ReportingService._future_events_page` emits exactly `fiscal://reimbursements/{claim_id}/parties/{party_id}`. `claim_id` was already present in the typed event schema, so no guessed field or Backend change was needed. The local inspector now requires the exact host and three segments, parsed claim ID equal to `event.claimID`, parsed party ID equal to `sourceID`, and the typed `partyID` equal to `sourceID`; it accepts standard UUID case variants while rejecting extra path/query/fragment/identity mismatches. Credit-cycle and cash-flow source paths were tightened under the same event-aware routine.
2. Account filter choices no longer derive from the currently returned timeline page. The model concurrently, independently and generation-safely calls the already reviewed typed F1 `masterData.activeAccounts()` read. Both platforms show loading-disabled reason, empty, error/retry and authoritative option names/kinds; a selected account survives an empty timeline page or a page that does not contain an event for it. Account option failure never becomes a fabricated empty list.

## Owned implementation

- `App/Sources/FiscalKit/V15/Foundation/V15Contracts.swift`
- `App/Sources/FiscalKit/V15/Foundation/V15Services.swift`
- `App/Sources/FiscalKit/V15/Features/Timeline/**`
- `App/Sources/FiscalKit/V15/Shared/Fixtures/F3AFixtures.swift`
- `App/Sources/FiscalKit/V15/AppShell/V15GalleryShell.swift`
- `App/Tests/FiscalKitTests/V15/F3ATests.swift`
- `App/Tests/V15GalleryUITests/F3AGalleryUITests.swift`
- `App/Tests/V15GallerymacOSUITests/F3AMacGalleryUITests.swift`
- `App/Tests/V15GallerySnapshotTool/V15GallerySnapshotTool.swift`, `App/project.yml`

Fixture/model coverage includes all certainty/source values, empty, Int64/long content, page failure/retry retention, 409 fresh-reload gate, offline snapshot, unsafe link zero request, and refresh/window/account/page races. It now also covers valid/mismatched three-source locators, claim/party mismatch, account options success/failure/cancellation/retry race, and account option read concurrent with timeline refresh. The iOS UI suite exercises window/page error/conflict/local inspector, empty/offline at AX5, and an authoritative account option outside the first page that produces an empty server result.

## Verification

- `cd App && xcodegen generate` — passed; rerun after adding the new UI test sources so they are included in the generated project.
- `xcodebuild -project App/Fiscal.xcodeproj -scheme V15GalleryiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:V15GalleryUITests/F3AGalleryUITests` — **2 tests, 0 failures**. The first 0/0 discovery was corrected by the xcodegen rerun; an intermediate 1/2 exposed an AX identifier using the Swift enum spelling instead of the backend raw source type, fixed before this final 2/2 result.
- `xcodebuild -project App/Fiscal.xcodeproj -scheme V15GallerymacOS -destination 'platform=macOS' build-for-testing` — passed, including `V15GallerymacOSUITests`.
- `xcodebuild -project App/Fiscal.xcodeproj -scheme FiscaliOS -sdk iphonesimulator -configuration Release -destination 'generic/platform=iOS Simulator' build` — passed.
- `xcodebuild -project App/Fiscal.xcodeproj -scheme FiscalmacOS -configuration Release -destination 'platform=macOS' build` — passed.
- Gallery iOS/macOS builds and `V15GallerySnapshotTool` build/run passed. SnapshotTool wrote the offline synthetic F3-A evidence below; each F3-A image was visually inspected.
- `git diff --check` — passed. F3-A source clean-room search found no direct old-layer, facts/overview or write-endpoint usage; the fixture's protocol-required `JSONValue?` method parameter is not used by the Feature.
- First-review-fix regression: `cd App && xcodegen generate` — passed. `xcodebuild -project Fiscal.xcodeproj -scheme V15GalleryiOS -destination 'platform=iOS Simulator,id=211DD03C-812D-4A42-97EF-F693D7DF924C' test -only-testing:V15GalleryUITests/F3AGalleryUITests` — **3 tests, 0 failures**; the third test opens the actual menu, selects synthetic `旅行现金` (absent from the first timeline page), observes the selected-account label and the resulting empty server state, then verifies account-read error visibility. The old simulator display-name argument produced a destination-resolution 0/0 only; it was replaced with the installed UDID before this run.
- First-review-fix builds: `V15GallerymacOS build-for-testing` (including macOS UI target), `FiscalmacOS build-for-testing` (including `FiscalKitTests` source), both formal Release targets and both Gallery targets passed. SnapshotTool was rebuilt/run and regenerated the F3-A macOS images at 14:49; all seven were visually inspected.
- Final copy regression: the account-kind label now distinguishes cash, debit, credit and unknown instead of collapsing non-credit accounts. The final `V15GalleryiOS` run again executed **3 tests, 0 failures**; final `V15GallerymacOS build-for-testing` and both formal Release targets passed. A transient Swift string-interpolation syntax error during this last copy adjustment was caught at compile time and fixed before that final run; it is not counted as a passing test.

## Screenshots

`screenshots/f3/` contains offline synthetic images: `f3a-macos-light.png`, `f3a-macos-dark.png`, `f3a-macos-ax5.png`, `f3a-macos-empty.png`, `f3a-macos-page-error.png`, `f3a-macos-conflict.png`, `f3a-macos-offline.png`, `f3a-ios-light-timeline.png`, `f3a-ios-dark-ax5-offline.png`, `f3a-ios-light-empty.png`, `f3a-ios-light-conflict.png`, and `f3a-ios-dark-page-error.png`. The regenerated macOS normal/empty/conflict/offline evidence now includes the authoritative account-filter control and its selected-state copy. The actual iOS UI test, not the image set, is the authoritative interaction evidence for page-error/retry and selecting the out-of-page account.

## Deferred environment gate

`F3A-MAC-UI-AUTOMATION` remains open and is the same local macOS `testmanagerd` automation fault already tracked as `F2C-MAC-UI-AUTOMATION`. The macOS UI target builds for testing, but its one permitted runtime probe did not enter business tests (no valid result bundle before the runner stalled); the process was stopped. The targeted/full `FiscalKitTests` runtime gate is likewise not claimed as passed because that macOS runner is unavailable. Under the user-approved skip policy, do not close this with SnapshotTool or model evidence; rerun both on a repaired macOS automation environment before F5/publish audit.

## F3-B1 — Builder evidence, awaiting independent implementation review

Implemented the isolated typed credit read surface (`credit-accounts`, account/cycle detail and keyset cycle/transaction pages) and P33 schedule preview/commit. The preview retains old/new schedule, affected-cycle versions and checkpoints, all counts, warnings/conflicts, `available_actions`, token/expiry and revision. `CreditAccountSummary` has no account version by contract, so the model reads the existing typed `/accounts/{id}` fact before previewing; it never substitutes a cycle version. The backend provides action names only, no enabled/reason object, receipt, or replay flag; the UI consequently shows only server-supported action state and never fabricates either receipt or replay.

The iOS sheet and macOS account/cycle spine + inspector invalidate preview on account/input/dismiss changes, show local and server field reasons inside the sheet, block expired/no-action/offline/conflict commits, require reload then a fresh preview after 409, and retain an idempotency key only for exact unknown-response retry. Fixtures/model source covers opening/overdue, account selection, opaque pages/local page errors, expiry, server field error, unavailable action, 409 reload→preview→success, same-key unknown replay, and offline zero writes. B2 installment lifecycle remains untouched.

Verification: `xcodegen generate`; `V15GalleryiOS` F3B1 UI run on simulator UDID `211DD03C-812D-4A42-97EF-F693D7DF924C` **2 tests, 0 failures** (invalid→reason→input invalidation→preview→commit, 409, offline/AX5); `FiscalmacOS build-for-testing` (FiscalKit tests compiled); both formal iOS/macOS Release builds; both Gallery builds; and SnapshotTool build/run passed. The SnapshotTool produced and visual inspection covered `screenshots/f3/f3b1-macos-{light-spine,dark-spine,ax5,preview-expired,preview-disabled,conflict,offline,page-error}.png`. Modal-only screenshot states use Gallery-only visible evidence because AppKit's headless snapshot host does not attach SwiftUI sheets; this does not replace the real iOS interaction run.

`F3B1-MAC-UI-AUTOMATION` is deferred with the existing user-approved F5 policy: one macOS runtime probe stalled before business-test execution, so neither the macOS UI target nor FiscalKit runtime tests are claimed as passed. Build-for-testing, SnapshotTool and source-model coverage are not substitutes. `git diff --check` passed; scoped clean-room scan found no old repository/DTO usage or raw transport in `V15/Features/Credit`.

### F3-B1 first-review remediation (1×P1, 1×P2)

1. A response-unknown schedule commit now persists an immutable in-memory `UnknownScheduleAttempt` *before* sending: account ID, exact typed commit request/body, payload identity and `Idempotency-Key`. Its retry calls the typed service directly with that captured body/key, so later local token expiry, unavailable action, or form edits cannot turn a receipt lookup into a fresh proposal. A successful replay clears the attempt; a deterministic server expiry/field error/conflict is shown honestly. The user can explicitly abandon the unknown attempt only through a readback refresh action. A first submission still enforces preview/action/expiry gates, and duplicate submissions are single-flight.
2. `load`, account selection and account refresh now invalidate the preview and account version before awaiting network work. A 409 remains a reload-required gate until *both* the credit-account and typed master-account version reads succeed; a failed refresh stays in the sheet with an error and retry, without re-enabling commit or reviving an old preview.

Regression verification: `xcodegen generate`; `FiscalmacOS build-for-testing` passed after compiling the extended F3-B1 tests; iOS `F3B1GalleryUITests` **3 tests, 0 failures**, adding the live 409 reload-failure→retry→new-preview flow; formal iOS/macOS Release and both Gallery builds passed; SnapshotTool was rebuilt/run and regenerated all eight F3-B1 macOS PNGs. A concurrent shared-DerivedData formal build briefly reported a locked `build.db`; after the already-running serialized build completed, the clean cached macOS Release rerun passed. No source behavior changed for this environmental lock. The temporary SnapshotTool DerivedData was moved to Trash after generation.

### F3-B1 second-review remediation (1×P2) — Builder Verified, awaiting third review

`UnknownScheduleAttempt` is now transactionally retained during readback. `resolveUnknownByReadback()` keeps the exact typed request/body and idempotency key in the `.unknown` gate while independently reading the credit-account summary, master account, cycle page and the necessary cycle details. It clears the attempt only when the complete readback proves the intended schedule and new master version; that outcome is a separate `readbackConfirmed` state and never fabricates a commit receipt/effect. Old or insufficient facts remain unknown; a failed/cancelled readback reports the specific error in the sheet and preserves both actions: same-key retry and another readback. Readback is generation-guarded and single-flight. Normal account load/refresh invalidates preview and selected version before requests, but cannot discard an unknown attempt; a failed conflict reload stays commit-disabled until retry succeeds and a fresh preview is made.

Coverage adds fixture/model cases for readback failure followed by exact same-key replay, old-state retention, matching-state confirmation without a receipt, and double readback single flight. The actual iOS UI path exercises failure (both recovery actions remain, then receipt via same key) and matching confirmation, in addition to invalid input/invalidation, disabled reason, 409 reload failure→retry→fresh preview, success/receipt, paging and offline at AX5.

Regression verification: `cd App && xcodegen generate`; persistent simulator `V15GalleryiOS` `F3B1GalleryUITests` run on UDID `211DD03C-812D-4A42-97EF-F693D7DF924C` **4 tests, 0 failures** (business-test count is nonzero); formal iOS/macOS Release builds and both Gallery builds passed; `V15GallerymacOS build-for-testing` passed including the macOS UI target; `FiscalmacOS build-for-testing` passed including `FiscalKitTests`; SnapshotTool rebuilt and ran serially, regenerating and visually inspecting all eight `screenshots/f3/f3b1-macos-*.png`. `git diff --check` and the scoped old-layer/raw-transport clean-room search passed. A transient SnapshotTool linker `ENOSPC` was resolved by deleting only verified regenerable F3-B1 temporary DerivedData after no compiler process was active; it is logged in `.learnings/ERRORS.md` and does not represent a test failure. `F3B1-MAC-UI-AUTOMATION` remains deferred under the user-approved F5 policy; no macOS runtime test is claimed.

### F3-B1 third-review remediation (1×P2) — Builder Verified, awaiting fourth review

Unknown readback now proves server facts only from forced fresh reads. The typed Credit account/cycles/cycle and MasterData account boundaries accept the existing `V15ReadCachePolicy` with an additive `.standard` default; only `resolveUnknownByReadback()` requests `.reloadIgnoringCache` for the summary, master account, cycle page and required details. The readback observes the offline-snapshot marker before and after the full chain: an already-offline start sends no GET, and a decoded transport fallback snapshot cannot confirm the intended schedule. Both cases retain the immutable unknown attempt and its exact same-key retry, with the sheet stating `离线快照不能核对当前服务器事实。`; no global transport or production DI behavior changed.

Fixture/model coverage verifies the forced-fresh request order and policy, an old cached state versus fresh applied state, fallback-to-old-snapshot non-confirmation, partial GET failure retention, and ordinary reads retaining their default cache policy. The real iOS `F3B1GalleryUITests` run executed **4 tests, 0 failures**, including the offline-fallback readback notice and surviving same-key recovery action.

Regression verification: `cd App && xcodegen generate`; `FiscalmacOS build-for-testing` (including FiscalKit test sources) and `V15GallerymacOS build-for-testing` (including macOS UI sources) passed; formal iOS/macOS Release builds and both Gallery builds passed; SnapshotTool rebuilt and regenerated all eight `screenshots/f3/f3b1-macos-*.png`, each visually inspected. `git diff --check` and the scoped old-layer/raw-transport clean-room scan passed. `F3B1-MAC-UI-AUTOMATION` remains deferred under the approved F5 policy; no macOS runtime test is claimed.

### F3-B1 fourth-review remediation (1×P2) — Builder Verified, awaiting fifth review

An unknown schedule attempt is now retained when a same-key retry is offline. `retryUnknownCommit()` blocks at the model boundary before any service call if the offline snapshot marker is present, preserves the immutable captured body and idempotency key in the `.unknown` gate, and exposes an unknown-scoped offline reason. The `offlineReadOnly` race after the retry starts follows the same retention path rather than becoming a failed submission. Both iOS and macOS disable the unknown retry with that visible reason; after recovery, the original exact body/key replays normally. Readback remains separately unable to prove current server state while offline.

Fixtures/model coverage adds offline-before-retry zero-wire retention, an in-flight `offlineReadOnly` retry race, online recovery using the same exact wire, and double-tap single flight. The actual iOS `F3B1GalleryUITests` suite executed **4 tests, 0 failures**, including the unknown offline panel/reason, offline readback notice, online recovery and receipt. The macOS UI target compiled through `V15GallerymacOS build-for-testing`; no macOS runtime result is claimed.

Regression verification: `cd App && xcodegen generate`; `FiscalmacOS build-for-testing`, `V15GallerymacOS build-for-testing`, formal iOS/macOS Release builds, both Gallery builds, and SnapshotTool build/run passed. SnapshotTool regenerated and visual inspection covered all eight `screenshots/f3/f3b1-macos-*.png`. `F3B1-MAC-UI-AUTOMATION` remains deferred under the approved F5 policy.

### F3-B1 fifth-review remediation (1×P2) — Builder Verified, awaiting sixth review

Account transitions now carry list and page ownership through every master-account, cycle-page, cycle-detail and transaction-page write. `load()`, selection and refresh advance the account generation before local resets; master results must still belong to the selected account before applying its version/draft or starting cycles. Cycle and transaction pagination use dedicated ownership generations, guarded both before local reset/loading flags and after awaits, so an old account cannot clear or write a newly selected account. This is scoped to Credit read-state races and leaves preview, unknown-attempt and server contracts unchanged.

Fixtures/model coverage delays A's master, cycle page and refresh/load sequence while switching to B; B retains its id, server version, draft and cycles. The real iOS `F3B1GalleryUITests` persistent simulator run executed **5 tests, 0 failures**, adding a fast A→B interaction that asserts B's cycle, version, draft and preview request version rather than only a label. `FiscalmacOS build-for-testing` and `V15GallerymacOS build-for-testing` compiled model and macOS UI sources; no macOS runtime result is claimed under the approved F5 deferment.

Regression verification: `cd App && xcodegen generate`; formal iOS and macOS Release builds plus both Gallery builds passed; SnapshotTool rebuilt/ran and all eight `screenshots/f3/f3b1-macos-*.png` were regenerated and visually inspected. `git diff --check` and the scoped old-layer/raw-transport clean-room scan passed. The iOS Release derived artifacts were removed only after that successful build to make space for the serialized macOS Release build; after verification all F3-B1 temporary derived data/result bundles were removed, recovering disk space without touching repository artifacts.

### F3-B1 sixth-review remediation (1×P1) — Builder Verified, awaiting seventh review

Schedule command state is now stored per credit account. The UI-facing phase, preview, server reasons, field issues, conflict/reload state, readback state, retry notice, key and immutable unknown body are all derived exclusively from the currently selected account. Each account has independent preview/commit/readback generations. Thus A's delayed success, failure, conflict or unknown completion mutates only A; B remains idle/independently writable, and returning to A restores its exact same-key recovery. A deliberate abandon is only permitted on that selected unknown account and forces a fresh account reload before any new preview/write, rather than permitting a blind replacement write.

Fixtures/model coverage delays A success/conflict/failure/unknown across a B selection, verifies B isolation, B preview+single-flight commit while A remains unknown, A→B→A same-body/key replay/readback, and selected-account-only abandon. iOS UI adds the actual A-unknown→close→B preview/commit→return-A same-key receipt path. The persistent simulator executed `F3B1GalleryUITests` **6 tests, 0 failures**; the direct new test also passed **1 test, 0 failures**. `FiscalmacOS build-for-testing` and `V15GallerymacOS build-for-testing` compiled both model and macOS UI targets; macOS runtime remains explicitly deferred under the approved F5 policy.

Regression verification: `cd App && xcodegen generate`; formal iOS and macOS Release builds, both Gallery builds, SnapshotTool build/run, and visual inspection of all eight regenerated `screenshots/f3/f3b1-macos-*.png` passed. `git diff --check` and scoped clean-room searches passed. Only exact regenerable F3-B1 DerivedData/result bundle directories were removed after their checks, to recover disk space.

### F3-B1 seventh-review remediation (1×P1) — Builder Verified, awaiting eighth review

An account-owned unresolved schedule command is now a model hard gate, not a view-only convention. While the current account has its immutable attempt in `.committing` or `.unknown`, `requestSchedulePreview()` returns before validation, phase mutation, preview clearing, field/banner mutation or service dispatch; it therefore preserves the exact same-key recovery state and emits zero preview wire requests. `scheduleCommandDisabledReason` is the single source for this condition. Both `canRequestSchedulePreview` and `scheduleDisabledReason`/`canCommitSchedule` derive from it, so preview and commit cannot be visibly enabled while the model would reject their action. Ordinary expired, server-action-disabled, field-error and conflict flows retain their normal re-preview behavior once no command is unresolved.

iOS and macOS now disable the preview control with the same explicit Chinese reason. During an unresolved command they also retain a disabled commit control and reason alongside the only legal recovery controls: same-key replay, forced-fresh account readback, or explicit abandonment. No attempt is implicitly cleared or replaced.

Coverage adds model cases for unknown and in-flight commands: both assert zero preview traffic, unchanged phase/attempt state, false preview/commit predicates and the exact visible reason; the unknown case then replays and verifies that a new preview only becomes available after successful same-key recovery. The real iOS UI adds the unknown-path assertion for both disabled controls/reasons and all recovery buttons, followed by successful same-key replay and new preview.

Regression verification: `cd App && xcodegen generate`; `FiscalmacOS build-for-testing` (including FiscalKit model test sources) and `V15GallerymacOS build-for-testing` (including macOS UI target) passed. Fixed-UDID iOS `F3B1GalleryUITests` executed **7 tests, 0 failures**; the new hard-gate test also executed separately **1 test, 0 failures**. Formal `FiscaliOS` and `FiscalmacOS` Release builds passed. `V15GallerySnapshotTool` rebuilt and ran; all eight regenerated `screenshots/f3/f3b1-macos-*.png` were individually visually inspected (light/dark spine, AX5, expired, disabled, conflict, offline and page error). `git diff --check` and the scoped clean-room search passed. `F3B1-MAC-UI-AUTOMATION` remains explicitly deferred under the approved F5 policy; no macOS runtime test is claimed.

### F3-B1 eighth-review remediation (1×P2) — Builder Verified; ninth review passed

`scheduleCommandDisabledReason` now treats the account-owned `.committing` phase as a direct hard gate, rather than inferring it only from an unresolved attempt. This closes the post-success window where `finishScheduleSuccess()` had correctly cleared the immutable unknown attempt before account/cycle reload completed, but could leave preview visually enabled. The shared reason is `账期变更正在提交/刷新结果，请稍候；此时不能重新预览或重复提交。`; preview capability, commit capability and the model preview entry point all derive from it.

Normal commit success and same-key unknown replay success retain `.committing` until their account and cycle refresh settles. During that interval preview, fresh commit, retry, readback and abandon leave phase, receipt/preview state and wire counts untouched. A table-driven model fixture delays the post-success cycle read on both paths and verifies zero extra preview/commit requests, disabled predicates and the shared reason; normal expired/action-disabled/field/conflict terminal flows remain able to make a fresh preview.

The real iOS fixture delays the post-success refresh and proves the displayed committing marker, disabled preview and commit controls with both visible reasons, then receipt/success and a fresh preview. The fixed-UDID full `V15GalleryiOS` `F3B1GalleryUITests` run executed **8 tests, 0 failures** (212.056 s); the new focused UI test also executed **1 test, 0 failures**. `cd App && xcodegen generate`, `FiscalmacOS build-for-testing`, `V15GallerymacOS build-for-testing`, formal `FiscaliOS` and `FiscalmacOS` Release builds, and `V15GallerySnapshotTool` build/run all passed. SnapshotTool regenerated `screenshots/f3/f3b1-macos-{light-spine,dark-spine,ax5,preview-expired,preview-disabled,conflict,offline,page-error}.png`; every image was visually inspected. `git diff --check` and the scoped old-layer/raw-transport clean-room scan passed. `F3B1-MAC-UI-AUTOMATION` remains deferred under the approved F5 policy; no macOS runtime or FiscalKit runtime execution is claimed.

## F3-B1 independent implementation review chain — final

1. **Review 1** — 1×P1, 1×P2: persisted exact unknown attempt and made load/refresh invalidate stale preview/version before awaits.
2. **Review 2** — 1×P2: made unknown readback transactional, single-flight and evidence-only; unresolved writes remain recoverable by same key.
3. **Review 3** — 1×P2: forced all unknown readback facts fresh and rejected offline fallback snapshots as proof.
4. **Review 4** — 1×P2: blocked offline unknown retry at the model boundary while preserving the original exact request/key.
5. **Review 5** — 1×P2: added ownership/generation guards across account, master, cycles and pagination races.
6. **Review 6** — 1×P1: made command/unknown state account-owned so A can never contaminate or replay through B.
7. **Review 7** — 1×P1: made unresolved-command preview/commit predicates and UI reasons a shared hard gate with zero preview wire.
8. **Review 8** — 1×P2: retained that hard gate through the normal and same-key replay post-success refresh window.
9. **Review 9** — **0 findings**. No Backend contract change, no scope deviation, and no B2 work was started.

### Final evidence

F3-B1 is **Independent implementation review verified; `F3B1-MAC-UI-AUTOMATION` deferred**. Final builder evidence is the eighth-remediation regression set: `cd App && xcodegen generate`; fixed-UDID `V15GalleryiOS` `F3B1GalleryUITests` **8 tests, 0 failures** plus the focused post-success-refresh UI test **1 test, 0 failures**; `FiscalmacOS build-for-testing` and `V15GallerymacOS build-for-testing`; formal `FiscaliOS` and `FiscalmacOS` Release builds; and `V15GallerySnapshotTool` build/run. The eight F3-B1 macOS screenshots were regenerated and visually inspected. `git diff --check`, cached diff check and the scoped Credit old-layer/raw-transport clean-room search passed.

This is not a runtime verification claim: the one permitted macOS automation probe did not execute business tests. `F3B1-MAC-UI-AUTOMATION`, together with `F2C-MAC-UI-AUTOMATION` and `F3A-MAC-UI-AUTOMATION`, remains a F5/publish blocker under the approved policy. The next permitted implementation block is F3-B2; F3-C/D/E/F/G, F4/F5 and root switching remain locked.

## F3-B2 — Independent implementation review verified; `F3B2-MAC-UI-AUTOMATION` deferred

Date: 2026-08-15 (Asia/Shanghai)
Status: **Independent implementation review verified; `F3B2-MAC-UI-AUTOMATION` deferred.** F3-C Builder is the next permitted block; F3-D/E/F/G, F4/F5 and formal roots remain locked.

### Backend-authoritative scope

Implemented typed installment list/detail, transaction eligibility, cycle options and account liabilities directly from the current Backend schemas/routes/services. The lifecycle preserves the five authoritative statuses `active / completed / settled_early / partially_cancelled / cancelled`; an unknown future status decodes into an explicit display-only surface and cannot expose a write action. The client renders server-owned period locks, future periods, affected cycles, warnings, liabilities and command results without recalculating debt or inventing transitions.

The mutation boundaries are exact:

- purchase preview → purchase commit and plan create use stable idempotency keys for an exact response-unknown retry;
- plan replacement preview → `PUT /installment-plans/{id}` deliberately sends no token and no `Idempotency-Key`, matching the Backend contract. A response-unknown result can only perform forced-fresh GETs of both plan and purchase transaction and compare the intended server facts. Confirmed, not-confirmed and readback-failure remain distinct; the client never resends the PUT or fabricates success;
- settlement, reverse-settlement and cancel-future each require their server preview and retain an immutable request plus stable idempotency key through response-unknown recovery. Success exposes `operation_id`, `replayed` and the actual returned system transaction rows, including title, kind, UUID and amount;
- every input change, invalid edit, dismiss or cancel invalidates the applicable preview. All async list/detail/eligibility/readback/command writes are generation- and account/plan-owned. Offline mode sends zero writes; 409, server field issues, unknown/replay states and every disabled action reason are visible in the active iOS sheet or macOS inspector.

The authoritative F3-B2 schemas do not define preview expiry or a mutation token/key for plan `PUT`; this Builder did not invent either one. Expiry behavior remains covered where the Backend actually supplies it in other phases, not asserted against this contract.

### Owned implementation and fixtures

- `App/Sources/FiscalKit/V15/Foundation/V15InstallmentContracts.swift`, with the minimal installment additions in `V15Contracts.swift` and `V15Services.swift`
- `App/Sources/FiscalKit/V15/Features/Installments/**`
- `App/Sources/FiscalKit/V15/Shared/Fixtures/F3B2Fixtures.swift`
- F3-B2 Gallery route wiring and seven SnapshotTool routes
- `App/Tests/FiscalKitTests/V15/F3B2Tests.swift`
- `App/Tests/V15GalleryUITests/F3B2GalleryUITests.swift`
- `App/Tests/V15GallerymacOSUITests/F3B2MacGalleryUITests.swift`

The iOS surface is stepwise. The macOS surface is a resizable `HSplitView` with plan spine, schedule and inspector; the spine uses `ScrollView`/`LazyVStack` so headless evidence does not lose its first column. Fixtures and controlled tests cover eligibility reasons; five states plus unknown/long/AX; keyset partial failure; preview invalid → valid, input invalidation, cancel and 409; all three lifecycle commands across success/unknown/same-key/different-payload safety; no-key PUT fresh readback confirmed/not-confirmed/failure; system transaction detail; and offline zero-write behavior.

### Verification

- `cd App && xcodegen generate` — passed after adding the F3-B2 source and test files.
- `FiscalmacOS build-for-testing` — passed, compiling all 16 F3-B2 Swift Testing model/decode/race test declarations. These are compile evidence only: no FiscalKit runtime-test pass is claimed while the macOS runner is unavailable.
- Real fixed-UDID iOS `F3B2GalleryUITests` full run — **4 tests, 0 failures** in **285.583 s**. It covers five statuses plus unknown/long content, offline dark AX5, eligibility/page/purchase invalidation, three-command success/unknown/conflict recovery and no-key PUT fresh-readback outcomes.
- Final focused iOS command test, after adding the actual returned system transaction details — **1 test, 0 failures** in **76.958 s**. It asserts the returned system-transaction row rather than only a generic receipt.
- Final serialized builds passed: formal `FiscaliOS` Release for generic iOS Simulator, formal `FiscalmacOS` Release, `V15GalleryiOS`, `V15GallerymacOS` and `V15GallerySnapshotTool`.
- SnapshotTool built and ran with the product framework path, regenerated the seven F3-B2 images below, and each image was visually inspected. Light/dark, AX5 wrapping, long status copy, offline reason, selected spine row and all three complete macOS panes are visible without clipping.
- `git diff --check` and `git diff --cached --check` passed. Scoped clean-room searches found no direct `APITransport`, `URLSession`, old repository/DTO/Feature, API route literal or formal-root use in `V15/Features/Installments`; formal App roots remain untouched.

Earlier non-counting iterations are not reported as passes: the first iOS attempt hit `ENOSPC` before executing a business test; the first direct SnapshotTool run lacked `DYLD_FRAMEWORK_PATH`; and the shared macOS view initially required an iOS compile guard around `HSplitView`. Each was corrected, recorded in `.learnings/ERRORS.md`, and followed by the passing gates above.

### Screenshot evidence and limits

`screenshots/f3/` contains the final offline-synthetic macOS evidence:

- `f3b2-macos-light-spine.png`
- `f3b2-macos-dark-spine.png`
- `f3b2-macos-ax5.png`
- `f3b2-macos-offline.png`
- `f3b2-macos-page-error.png`
- `f3b2-macos-put-readback.png`
- `f3b2-macos-command-recovery.png`

The last three SnapshotTool routes prove deterministic route startup and layout, not modal interaction: the static tool does not click controls. The real iOS XCUITest run is the authoritative interaction evidence for page recovery, PUT fresh readback and command recovery.

### First independent review remediation — Builder complete; awaiting second review

The first independent review returned one P1 and three P2 findings. All four are remediated against the current Backend P5 schemas rather than inferred from the legacy client:

- **P1 — positive installment fees are now completable:** purchase+plan create, existing-purchase plan create and plan replacement all load fee categories independently from typed master data. Only active expense categories are selectable. Loading, empty, error, retry, offline and generation-race states are explicit. A positive fee requires both a server-authoritative expense category and a Shanghai occurred date; a zero fee clears both fields and sends the Backend null/omission semantics. iOS and macOS expose both controls and every disabled reason names the field the user can actually complete.
- **P2 — command unknown readback cannot manufacture confirmation:** forced-fresh GET only reports that plan facts changed or the operation may have happened; it never attributes the change to this request, never enters `confirmed`, and never clears the immutable attempt/key. A third-party status/version advance remains not-confirmed. Only replaying the exact body with the same key and receiving an operation receipt confirms the request and clears recovery state.
- **P2 — no-key plan PUT readback is an exact replacement comparison:** the fresh plan+purchase comparison now covers plan identity/version, purchase association, kind/title/principal/account/count, fee amount/category/occurred-at, start statement date and purchase amount/date/title/note/account/category with null semantics. A fee-date mismatch remains not-confirmed, keeps the unknown attempt and blocks further writes; the PUT is still never retransmitted.
- **P2 — preview details render the complete server response:** purchase, plan replacement, settlement, reverse settlement and cancel-future previews on both platforms now enumerate server locked/future/restored/cancelled/proposed periods, every affected cycle with before/after/delta, warnings/reasons and concrete dates/amounts. The views are scrollable and expose concrete first/tail period, cycle and warning accessibility identifiers; no debt or transition is recalculated locally.

Cross-cutting regression coverage also proves button predicates use the model guards, all input changes/dismiss/cancel invalidate the applicable preview, category loading is generation-owned, and errors remain inside the active sheet/inspector. The first focused positive-fee UI iteration is explicitly non-counting: it exposed a SwiftUI same-value binding write that cleared eligibility. `purchaseTransactionID` now invalidates eligibility only when its value actually changes, with a controlled model assertion, and the complete flow was rerun successfully.

Final remediation verification set (the compile/build gates were rerun after the last copy audit; that final change was explanatory copy only):

- `cd App && xcodegen generate` — passed.
- `FiscalmacOS build-for-testing` — passed after the final change and compiles all **18** F3-B2 Swift Testing declarations. This remains build/compile evidence only; no macOS or FiscalKit runtime pass is claimed.
- Focused real fixed-UDID iOS positive-fee test — **1 test, 0 failures** in **165.286 s**. It covers positive-fee purchase+create, existing-purchase create and replacement invalid → category/date selection → preview/commit success.
- Full real fixed-UDID iOS `F3B2GalleryUITests` run — **6 tests, 0 failures** in **635.573 s**: command unknown/same-key receipt; eligibility, keyset page recovery and purchase invalidation; five statuses+unknown/long/offline AX5; no-key PUT confirmed/not-confirmed/fee-date mismatch/readback failure; category error/retry and all three positive-fee flows; reverse/cancel preview detail.
- Formal `FiscaliOS` and `FiscalmacOS` Release builds, `V15GalleryiOS`, `V15GallerymacOS`, and `V15GallerySnapshotTool` all passed after the remediation.
- SnapshotTool ran successfully into an isolated output directory with its product framework path. Only the seven F3-B2 PNGs were promoted. Each was opened and visually inspected: light/dark three-pane spine, long/unknown status, offline read-only reasons, page retry, positive-fee category/date plus PUT preview, and command first/tail periods with affected-cycle details are visible; narrow and AX5 content remain reachable through the intended scroll containers without pane collapse.
- Final `git diff --check` and `git diff --cached --check` passed. The scoped Installments search returned no direct `APITransport`, `URLSession`, old installment repository/DTO/Feature, API route literal, formal App root, Backend or later-block dependency. No Xcode/Snapshot process remained. The formal roots, Backend and later F3 blocks remain untouched by this Builder.

### Second independent review remediation — Builder complete; awaiting third review

The second independent review returned one P1 and two P2 findings. All three are remediated without widening the Backend contract:

- **P1 — every in-flight write now has an immutable owner-scoped attempt before the first wire:** purchase commit, existing-purchase plan create, no-key plan `PUT`, settlement, reverse settlement and cancel-future allocate a generation-independent operation ID and persist the exact typed request, owner account/plan/purchase and stable key or explicit no-key intent before transport starts. Completion no longer depends on the currently selected plan, the editor generation or an open sheet. Dismiss, edit and plan selection changes cannot lose the result or write it into another plan; returning to the original owner restores its committing, unknown, deterministic-failure or receipt state. Purchase/create phase and receipt projection is also owner-scoped, so selecting owner B cannot expose owner A's in-flight or terminal state. Unknown transport/cancellation retains the exact retry attempt, idempotent operations issue one same-key wire per attempt, and the no-key `PUT` is never sent twice. Controlled purchase/create/PUT/command races cover success, response-unknown and deterministic failure after the wire, including plan B remaining independently writable while plan A finishes.
- **P2 — fee business dates no longer drift or jump into the future:** a newly entered date is encoded at `Asia/Shanghai` start-of-day. A Shanghai-morning test proves “today” is at or before the injected Backend-like clock; a future date is rejected locally. An existing plan whose fee date was not edited preserves the original server timestamp byte-for-byte instead of normalizing it during replacement.
- **P2 — the purchase category dependency is visible even for zero fee:** the primary purchase expense category now exposes typed category loading, empty, error and retry states in the common purchase area on both iOS and macOS. Disabled reasons name the recoverable condition instead of leaving a grey button with no reachable field. The positive-fee category has the same independently owned states. No category is guessed or defaulted.

Final second-review remediation verification:

- `cd App && xcodegen generate` passed.
- `FiscalmacOS build-for-testing` passed after the final assertions, compiling all **23** F3-B2 Swift Testing declarations. `V15GallerymacOS build-for-testing` also passed, including the macOS UI-test target. Both are compile evidence only; no macOS or FiscalKit runtime pass is claimed.
- Focused real fixed-UDID iOS zero-fee category recovery test passed: **1 test, 0 failures** in **231.158 s**. It performs category error → retry → authoritative selection → preview → commit receipt; the same method also reaches the positive-fee category error state and the purchase/create/replacement positive-fee controls.
- Full real fixed-UDID iOS `F3B2GalleryUITests` aggregation passed after the final owner-scoped audit: **6 tests, 0 failures** in **704.448 s**. Result bundle: `/Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou/Logs/Test/Test-V15GalleryiOS-2026.08.15_22-20-45-+0800.xcresult`. The run covers category recovery, all three positive-fee flows, no-key readback, five statuses+future unknown/offline, command replay/receipt, concrete first/tail preview periods, cycles and warnings, plus purchase/create owner isolation and restoration.
- Formal `FiscaliOS` and `FiscalmacOS` Release builds and `V15GalleryiOS` / `V15GallerymacOS` Release builds passed after the final owner-scoped audit. `V15GallerySnapshotTool` built and ran with the Debug product framework path into `/private/tmp/fiscal-f3b2-owner-final-snapshots.nLtho2`; exactly the seven F3-B2 PNGs were promoted.
- All seven regenerated F3-B2 macOS PNGs were opened and visually inspected. The light/dark spine, AX5/long wrapping, offline read-only reasons, page retry, positive-fee category/date replacement editor and concrete command preview details remain readable; all three panes are present, and longer evidence stays in its intended scroll container.
- A targeted `FiscaliOS` unit-test command was rejected before execution because that scheme does not contain `FiscalKitTests`; it is not counted as a test result. No workaround or false pass is claimed.
- Final `git diff --check` and `git diff --cached --check` passed. The scoped production Installments search found no direct `APITransport`, `URLSession`, old repository/DTO, raw API path, Backend import, formal App root or later F3-block dependency. The only route literals found by the wider audit are controlled-test wire assertions. No Xcode, Swift compiler or SnapshotTool process remained.

### Third independent review remediation — Builder complete; awaiting fourth review

The third independent review returned one P1 and one P2 finding. Both are remediated against the current Backend P5 service rules:

- **P1 — fee time now proves both Backend boundaries:** purchase+plan create freezes one exact purchase `occurred_at` before preview; a same-business-date positive fee reuses that exact instant. Existing-purchase create obtains its authoritative purchase timestamp through the typed ledger transaction-detail service, with independent generation/loading/error/retry state. Replacement preserves an unchanged original fee timestamp byte-for-byte; an edited date follows the same purchase boundary rule. A fee date before the purchase business date or after today is rejected locally, same-day uses the purchase instant, and a later valid Shanghai date uses start-of-day with a final `fee <= now` guard. Every wire path reasserts `purchase.occurred_at <= fee.occurred_at <= now`, and the fixture transport independently applies a Backend-like rejection. Visible disabled reasons identify the invalid fee date instead of leaving an unreachable grey action.
- **P2 — eligibility ownership compares UUID values, not text casing:** eligibility and typed purchase-detail requests reparse the current text after every await and compare UUID values to the requested owner. Success, error and cancellation paths are generation guarded and terminate only their owned loading state. Lowercase, uppercase and mixed-case spellings of the same UUID remain one semantic owner, including an in-flight lowercase-to-uppercase edit; changing to a different UUID invalidates the stale response.

Final third-review remediation verification:

- `FiscalmacOS build-for-testing` passed after the last owner-race assertion, compiling all **27** F3-B2 Swift Testing declarations. This is compile evidence only; no FiscalKit runtime pass is claimed while the macOS runner remains unavailable.
- Focused real fixed-UDID iOS flow passed: **1 test, 0 failures** in **232.075 s**. It enters the existing purchase UUID in lowercase, waits for eligibility and the independent typed purchase detail to load, then completes the positive-fee create flow. Result bundle: `/Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou/Logs/Test/Test-V15GalleryiOS-2026.08.15_22-52-45-+0800.xcresult`.
- Full real fixed-UDID iOS `F3B2GalleryUITests` aggregation passed: **6 tests, 0 failures** in **713.294 s**. The positive-fee existing-purchase path proves lowercase UUID ownership and loaded authoritative purchase detail, rejects a fee business date before the purchase date, then accepts the valid date and completes. The run also preserves the complete command/readback/category/offline/preview-detail regression set. Result bundle: `/Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou/Logs/Test/Test-V15GalleryiOS-2026.08.15_22-57-47-+0800.xcresult`.
- `V15GallerymacOS build-for-testing` passed, including the macOS UI-test target. No macOS runtime was retried and no runtime pass is claimed.
- Formal `FiscaliOS` and `FiscalmacOS` Release builds and `V15GalleryiOS` / `V15GallerymacOS` Release builds passed after the final source changes.
- `V15GallerySnapshotTool` Debug build and run passed with the Debug product framework path into `/private/tmp/fiscal-f3b2-third-review-snapshots.aO3dY2`. Exactly the seven F3-B2 PNGs were promoted and opened individually. Light/dark/AX5 three-pane layout, long and future-unknown status copy, offline reasons, page retry, positive-fee category/date replacement editor and concrete first/tail command periods plus affected cycles remain readable without pane collapse or clipping; longer content remains scrollable.
- Final `git diff --check` and `git diff --cached --check` passed. The scoped Swift trailing-whitespace check and production Installments clean-room search both returned no findings. No Xcode, Swift compiler or SnapshotTool process remained; the process probe showed only its own `pgrep` shell. `PROJECT_PLAN.md` remains the compact 109-line / 16,846-byte control plane.

Backend, formal roots and F3-C or later blocks were not modified by this Builder.

### Fourth independent review — 0 findings; verified

- Fourth independent implementation review returned **0 findings**. It confirmed the Backend-authoritative fee-time boundaries, typed purchase-detail ownership, UUID value/generation guards, immutable owner-scoped mutation recovery, complete server preview rendering and the retained Builder verification evidence without requesting another implementation or test change.
- The complete F3-B2 review chain is: **review 1 — 1×P1 + 3×P2; review 2 — 1×P1 + 2×P2; review 3 — 1×P1 + 1×P2; review 4 — 0 findings**. Every finding from the first three reviews was repaired and reverified in its corresponding Builder section above; the fourth review closes the implementation review gate.
- All previously recorded runtime/build/snapshot evidence remains authoritative and unchanged, including the real iOS nonzero business-test runs and the explicit macOS automation limitation. An accidentally triggered interrupt during final-review coordination produced no business-test result and is **not counted as a gate**, does not erase any passing result, and is not represented as a failure or pass.
- Final status is **Independent implementation review verified; `F3B2-MAC-UI-AUTOMATION` deferred**. This unlocks only F3-C Builder. F3-D/E/F/G, F4/F5 and formal roots remain locked.
- Documentation-only closeout checks passed: `git diff --check`, `git diff --cached --check`, and the control-plane size check (`PROJECT_PLAN.md`: **109 lines / 16,711 bytes**). No implementation or test file was changed and F3-C was not started during this closeout.

### Deferred environment gate

`F3B2-MAC-UI-AUTOMATION` remains open. Its permitted runtime probe stalled at `waiting for workers to materialize / Initiating test runner session`, executed **0 business tests**, and was stopped after approximately 44 seconds with exit 75. During second-review remediation, one inadvertent targeted macOS unit invocation compiled and then re-hit the same worker-materialization fault; it was stopped after approximately 20 seconds and is not counted. No further macOS runtime attempt was made. Under the approved policy, this is a F5/publish blocker and cannot be closed with build-for-testing, model source coverage or screenshots. Rerun the F3-B2 macOS UI and FiscalKit runtime suites only after the shared `testmanagerd` root is repaired.

F3-B2 is now **Independent implementation review verified; `F3B2-MAC-UI-AUTOMATION` deferred**. F3-C Builder is the next permitted block; no F3-C implementation was started by this documentation-only closeout.

## F3-C — Builder complete; awaiting Independent Review

Date: 2026-08-16 (Asia/Shanghai)
Status: **Builder complete; awaiting Independent Review. `F3C-MAC-UI-AUTOMATION` deferred.** F3-D/E/F/G, F4/F5 and formal roots remain locked.

### Backend-authoritative contract and implementation

F3-C uses the current P6/P33 Backend reimbursement schemas, routes, services and QA as the sole behavioral authority. It implements typed claim/receipt list and detail reads, candidate filtering and opaque keyset pagination, receipt-account options, the direct atomic new-claim write, all four distinct preview/commit families, and the versioned direct claim/receipt lifecycle. Candidate decoding preserves `eligible`, `reasons`, `reason_details.field_path`, canonical/allocated/available minor-unit amounts and a nullable `category_id`; an eligible uncategorized expense remains selectable and submittable. The closed claim state set is `draft / pending / partial_received / received / cancelled / partially_received_cancelled`; a future state is explicit display-only data.

The four typed preview/commit pairs are not collapsed into a generic mutation:

- claim replacement preview → `PUT` claim;
- outstanding cancellation preview → cancel outstanding;
- receipt preview → create receipt;
- receipt replacement preview → `PUT` receipt.

Every commit retains the exact expected claim/receipt versions, server preview token, immutable request body and stable idempotency key. Edits, invalid text, selection changes, cancel/dismiss and conflict invalidate previews. Owner-scoped attempts exist before the first write wire, survive in-flight sheet dismissal or selection changes, and cannot write a result into another claim. A response-unknown idempotent write exposes only an exact same-body/same-key retry; single flight and offline zero-write are enforced. Direct submit/retract/reopen/void/restore/archive/unarchive and receipt void/restore deliberately send no key or synthetic preview/receipt. Their response-unknown path performs only a forced-fresh typed readback and never treats target-looking facts as command attribution: the Backend exposes no operation marker, so even an exact one-version advance may have come from a third party. Further writes remain locked, the command is never resent, and only a successful fresh read makes an explicit user abandon action available.

All loads, previews, pages, commits and readbacks have generation and semantic-owner guards. CNY input uses `CNYAmountParser`; receipt business dates use strict `Asia/Shanghai` start-of-day and reject malformed/future values. A regression assertion covers “today” before Shanghai noon: the previous noon-normalization approach made the same business date appear future during Shanghai mornings and could leave the receipt preview button permanently grey.

### Owned surfaces, fixtures and grey-button hard gate

- `App/Sources/FiscalKit/V15/Features/Reimbursements/**`
- the minimal typed reimbursement additions in `V15Contracts.swift` and `V15Services.swift`
- `App/Sources/FiscalKit/V15/Shared/Fixtures/F3CFixtures.swift`
- F3-C Gallery routing and the 12 SnapshotTool scenes
- `App/Tests/FiscalKitTests/V15/F3CTests.swift`
- `App/Tests/V15GalleryUITests/F3CGalleryUITests.swift`
- `App/Tests/V15GallerymacOSUITests/F3CMacGalleryUITests.swift`

The iOS screen is a native decision surface with in-sheet local/remote banners. The macOS screen is a three-pane claim spine, detail and inspector. Both expose every disabled primary-action reason next to the control. New-claim and receipt editors independently model loading, empty, error and retry for candidates or receipt accounts; title, party, allocation, amount, date and account reasons preserve local and server `field_path` information. The fixture transport covers normal, empty/error/race, conflict, remote-field-reason, response-unknown/readback, long/AX5, partial, offline and unknown-status modes without using real financial data.

During the real iOS run, two defects were found and corrected before the final evidence set: an outer accessibility identifier masked descendant button identifiers, and receipt “today” was normalized to noon rather than Shanghai start-of-day. Final screenshot inspection found and corrected a literal list-count interpolation; the complete iOS suite and affected Release builds were rerun after that final visible change.

### Verification

- `cd App && xcodegen generate` passed after adding the F3-C sources and tests.
- `FiscalmacOS build-for-testing -only-testing:FiscalKitTests/F3CTests` passed and compiles all **15** Swift Testing declarations. `V15GallerymacOS build-for-testing` passed and compiles both F3-C macOS UI-test declarations. These are build/compile evidence only while the local macOS test runner is unavailable.
- Final real fixed-UDID iOS `F3CGalleryUITests` aggregation passed after the last visible-text correction: **5 tests, 0 failures, 0 skipped** in **271.235 s**. It completes a new claim with `eligible=true, category_id=null`; reaches candidate empty/error/retry, future unknown and offline AX5; reaches receipt-account loading/empty/error/retry; performs receipt invalid → valid → preview → edit invalidation → repreview → commit; and keeps remote reasons plus 409 reload/repreview/success inside the active sheet.
- The final `xcresulttool` summary independently reports `totalTestCount=5`, `passedTests=5`, `failedTests=0`, `skippedTests=0`. Its **13** named interaction attachments were exported to `screenshots/f3/` and opened for visual inspection.
- Formal `FiscaliOS` Release and `V15GalleryiOS` Release were rerun after the final iOS-only count-text fix and passed. Formal `FiscalmacOS` Release, `V15GallerymacOS` Release and `V15GallerySnapshotTool` had already passed after the final shared/macOS source state.
- SnapshotTool ran with the Debug product framework path into an isolated F3-C directory. Only the 12 F3-C macOS PNGs were promoted. Every macOS image was opened individually and checked for three-pane presence, light/dark contrast, AX5/long wrapping, candidate and account states, visible field/action reasons, preview, conflict, success, partial and offline states.
- The final screenshot matrix contains all 12 planned state names on each platform: `claim-new`, `claim-reasons`, `receipt-loading`, `receipt-empty`, `receipt-retry`, `invalid-valid`, `preview`, `conflict`, `success`, `partial`, `offline`, and `ax5`. iOS matrix aliases point to the corresponding final real-XCUITest attachments when one interaction screenshot proves more than one axis; they are not separate runtime claims.
- `git diff --check` and the scoped clean-room searches passed. Production `Features/Reimbursements` contains no direct `APITransport`, `URLSession`, raw API path, old reimbursement repository/DTO/View, `FiscalDesign`, Backend import, formal root or later F3-block dependency.

### Deferred macOS runtime gate

The one permitted macOS runtime probe built successfully but did not execute a business test and ended interrupted in the same local Xcode test-runner failure family already tracked by earlier F2/F3 blocks. It was not retried. Neither SnapshotTool, model/source assertions nor build-for-testing is reported as a macOS runtime pass. `F3C-MAC-UI-AUTOMATION` remains deferred and is a mandatory F5/publish blocker; it must run the compiled new-claim and receipt flows on a repaired macOS automation environment.

F3-C is therefore **Builder complete; awaiting Independent Review**. This does not unlock F3-D. Backend, F3-D+, F4/F5 and formal roots were not modified by this Builder.

### First independent-review remediation — Builder complete; awaiting second Independent Review

Status: **First-review remediation Builder complete; awaiting second Independent Review. `F3C-MAC-UI-AUTOMATION` remains deferred.** F3-D/E/F/G, F4/F5 and formal roots remain locked.

The first independent review reported two P1 and two P2 findings. The Builder corrected all four without broadening the Backend contract:

- New-claim and receipt attempts are now owner-scoped recovery authority independent of transient sheet phase. Closing an unknown operation does not clear its immutable request/body/key/token; reopening its owner restores same-key recovery without reloading candidates/accounts over the attempt. Switching A → B cannot expose or mutate A, and returning to A restores it.
- Every reimbursement mutation phase, message, preview, unknown state and receipt is scoped to its claim/receipt owner. Async completion requires both semantic owner and operation ID/generation, so delayed success, failure or cancellation from A cannot overwrite selected B.
- Direct no-key attempts persist their owner, expected version, intent and complete pre-write claim/receipt facts. Backend P6/P33 lifecycle responses contain no operation marker, therefore fresh readback can never prove attribution, including target-looking facts with a single version advance. Pre-already-satisfied state, no advance, mismatched advance, third-party-looking target state and read failure all retain the unknown lock with the visible text “事实变化但无法归因”; no second POST is sent. After a successful fresh read only, the user may explicitly acknowledge facts and abandon the attempt.
- Outstanding-cancellation availability is now one shared model predicate consumed by both iOS and macOS. Offline, unresolved unknown, receipt-detail reload gate, draft, non-`pending`/`partial_received`, archived, voided and zero-outstanding conditions each expose their concrete reason beside the disabled action.

Remediation verification:

- `cd App && xcodegen generate` passed. `FiscalmacOS build-for-testing -only-testing:FiscalKitTests/F3CTests` passed and compiles all **21** F3-C Swift Testing declarations. `V15GallerymacOS build-for-testing` passed and compiles both macOS UI-test declarations; neither is claimed as a macOS runtime pass.
- The focused real-iOS remediation aggregation passed **3 tests, 0 failures**. The subsequent complete fixed-simulator `F3CGalleryUITests` run passed **8 tests, 0 failures, 0 skipped** in **390.444 s**; its xcresult independently reports `totalTestCount=8`, `passedTests=8`, `failedTests=0`, `skippedTests=0`. The added business flows prove claim unknown → close → reopen → same-key success, receipt unknown → close → B → A → same-key success, and shared valid/draft cancellation reasons.
- Formal `FiscaliOS` and `FiscalmacOS` Release builds passed from the final shared source state. `V15GalleryiOS` and `V15GallerymacOS` Release builds passed; `V15GallerymacOS build-for-testing` also passed.
- `V15GallerySnapshotTool` Debug build and isolated run passed. Exactly the 12 F3-C macOS state images were opened individually and inspected; 11 matched the prior evidence byte-for-byte and the final offline-reason image was promoted. The 12-image matrix remains `claim-new`, `claim-reasons`, `receipt-loading`, `receipt-empty`, `receipt-retry`, `invalid-valid`, `preview`, `conflict`, `success`, `partial`, `offline`, and `ax5`.
- Final `git diff --check` and `git diff --cached --check` passed. The scoped production Reimbursements scan found no direct transport, raw API path, old repository/DTO/View, `FiscalDesign`, Backend import, formal root or later F3 dependency. No Xcode, Swift compiler or SnapshotTool process remained; only exact `/private/tmp/fiscal-f3c-r1-*` regenerable artifacts were removed after verification.

`F3C-MAC-UI-AUTOMATION` remains a mandatory F5/publish blocker under the approved one-probe policy. This remediation is **not** Independent Review verification and does not unlock F3-D. The next permitted action is the second Independent Review of F3-C.

### Second independent-review remediation — Builder complete; awaiting third Independent Review

Status: **Second-review remediation Builder complete; awaiting third Independent Review. `F3C-MAC-UI-AUTOMATION` remains deferred.** F3-D/E/F/G, F4/F5 and formal roots remain locked.

The second independent review reported two P2 findings. The Builder corrected both at the typed model and both native UI surfaces:

- The Backend-authoritative claim/receipt action matrix is now public typed model policy (`claimActionReasons`, `receiptActionReasons` and the corresponding `can…` predicates). Both iOS sheets and the macOS inspector expose all applicable claim replace/cancel/direct and receipt create/replace/direct entries from that same policy, hide actions that do not exist for the current Backend state, and render offline, owner-pending, response-unknown, readback/reload and fact-refresh blockers beside every disabled action. Claim replacement and receipt replacement have reachable native editors; every preview commit button consumes the same model reason list as its entry point, with no UI-only shortcut or silent model return.
- Receipt create, replace, void and restore now install an owner-scoped fact-refresh gate synchronously before the mutation attempt can be cleared. A successful wire must force-refresh the owner claim and receipt list before terminal success/unlock, converging claim version, status, outstanding amount, receipt count and party facts. Refresh failure is explicitly partial success: writes stay locked, the user sees a GET-only retry, and the mutation is never resent. Replacement and direct follow-up requests therefore use the refreshed claim/receipt versions.

Remediation verification:

- `cd App && xcodegen generate` passed after the final source/test changes. `FiscalmacOS build-for-testing -only-testing:FiscalKitTests/F3CTests` passed and compiles all **24** F3-C Swift Testing declarations. `V15GallerymacOS build-for-testing -only-testing:V15GallerymacOSUITests/F3CMacGalleryUITests` passed and compiles both macOS UI tests. These remain compile/BFT evidence only; no second macOS runtime probe was made and no macOS runtime pass is claimed.
- Focused real-iOS runs passed independently: action matrix/editor **1/1**, fact-refresh failure and GET-only retry **1/1**, receipt replace → void → restore with refreshed facts **1/1**, and direct response-unknown recovery **1/1**. The final complete fixed-simulator `F3CGalleryUITests` aggregation then passed **12 tests, 0 failures, 0 skipped** in **584.221 s**. Its `xcresulttool` summary independently reports `totalTestCount=12`, `passedTests=12`, `failedTests=0`, `skippedTests=0` on simulator `211DD03C-812D-4A42-97EF-F693D7DF924C`. Result bundle: `/Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou/Logs/Test/Test-V15GalleryiOS-2026.08.16_02-25-17-+0800.xcresult`.
- The complete iOS suite opens every action-matrix entry, enters the claim-replacement editor, preserves the existing unknown-close-reopen and A/B owner isolation proofs, exercises refresh failure without a duplicate mutation, and completes receipt replacement followed by void/restore with claim-fact convergence. Unit fixtures additionally assert versioned next-wire bodies and refresh-failure GET-only retry for receipt create, replace and direct operations.
- Formal `FiscaliOS` and `FiscalmacOS` Release builds and `V15GalleryiOS` / `V15GallerymacOS` Release builds passed after the final source state. `V15GallerySnapshotTool` Debug build and isolated run passed.
- Exactly **14** F3-C macOS images were promoted and opened individually: the original 12-state matrix plus `action-matrix` and `receipt-replace`. Both additions expose the action policy and replacement editor; all 14 retain readable three-pane geometry, reasons, fields, preview/conflict/success and loading/empty/error/retry/offline states without blank output or clipping.
- Final `git diff --check` and `git diff --cached --check` passed. The scoped production Reimbursements clean-room scan found no direct transport, raw API path, old reimbursement repository/DTO/View, `FiscalDesign`, Backend import or later F3 dependency. No Xcode, Swift compiler, XCTest or SnapshotTool process remained; only exact `/private/tmp/fiscal-f3c-r2-*` regenerable artifacts were removed. `PROJECT_PLAN.md` remains the compact **109-line / 16,967-byte** control plane.

`F3C-MAC-UI-AUTOMATION` remains a mandatory F5/publish blocker under the approved one-probe policy. This remediation is **not** Independent Review verification and does not unlock F3-D. The next permitted action is the third Independent Review of F3-C.

### Third independent-review remediation — Builder complete; awaiting fourth Independent Review

Status: **Third-review remediation Builder complete; awaiting fourth Independent Review. `F3C-MAC-UI-AUTOMATION` remains deferred.** F3-D/E/F/G, F4/F5 and formal roots remain locked.

The third independent review reported one P2 finding. The Builder corrected the retry semantics and fact-refresh presentation without changing the Backend contract:

- The owner-scoped fact-refresh gate now has explicit `refreshing` and `failed` phases plus public typed retry reasons. Receipt create/replace/direct success installs the gate before terminal success; a failed convergence stays write-locked and exposes only `retryFactRefresh()`, which performs fresh claim and receipt `GET`s and never resends the prior `POST` or `PUT`.
- The macOS top inspector renders the complete fact-refresh panel before the active receipt inspector, so create-receipt partial success cannot hide it. The panel states that the accepted write cannot yet be attributed to final facts, explains the GET-only policy, and exposes the real `v15.f3c.mac.fact-refresh.retry` action. Closing the receipt editor does not discard the gate; the same retry remains reachable after close/reopen. iOS operation and receipt sheets use the same priority and typed gate policy.
- Both F3-C native views were audited for visible retry affordances. Every remaining retry invokes an actual async load, conflict refresh, same-key recovery or fresh-fact read. Generic `.failed` / `.unknown` editor banners with no safe retry are now explanatory, non-interactive error components; there is no empty retry closure or silent button.

Remediation verification:

- `cd App && xcodegen generate` passed. `FiscalmacOS build-for-testing -only-testing:FiscalKitTests/F3CTests` passed and compiles all **24** F3-C Swift Testing declarations. `V15GallerymacOS build-for-testing -only-testing:V15GallerymacOSUITests/F3CMacGalleryUITests` passed and compiles all **3** macOS UI tests, including the receipt-refresh-failure route and real retry identifier. These remain compile/BFT evidence only; no macOS runtime probe was repeated and no macOS runtime pass is claimed.
- The focused real-iOS fact-refresh test passed **1 test, 0 failures** in **64.416 s** after the final accessibility ownership fix. The final complete fixed-simulator `F3CGalleryUITests` aggregation passed **12 tests, 0 failures, 0 skipped** in **610.916 s**. Its `xcresulttool` summary independently reports `totalTestCount=12`, `passedTests=12`, `failedTests=0`, `skippedTests=0` on simulator `211DD03C-812D-4A42-97EF-F693D7DF924C`. Result bundle: `/Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou/Logs/Test/Test-V15GalleryiOS-2026.08.16_03-19-22-+0800.xcresult`.
- The existing model proof still observes zero duplicate mutation wires after receipt fact-refresh failure. It now also proves failed-gate retry availability, close persistence and the explicit unable-to-attribute copy; the real iOS test closes the sheet, reaches the priority gate on the owner detail, taps the actual retry, and converges to success.
- Formal `FiscaliOS` and `FiscalmacOS` Release builds and `V15GalleryiOS` / `V15GallerymacOS` Release builds passed after the final source state. `V15GallerySnapshotTool` Debug build and isolated run passed.
- Exactly **15** F3-C macOS images were promoted and opened individually. The prior 14-state matrix remains readable, and the new `partial-success` image visibly contains the priority fact-refresh panel, unable-to-attribute and fresh-GET/no-repeat-write copy, the real retry control, and the receipt inspector without blank output or clipping.
- Final `git diff --check`, `git diff --cached --check`, the scoped no-op retry scan and the production Reimbursements clean-room scan passed. No Xcode, Swift compiler, XCTest or SnapshotTool process remained; only exact `/private/tmp/fiscal-f3c-r3-*` regenerable artifacts were removed after verification.

Two corrected non-evidence iterations are recorded in `.learnings/ERRORS.md`: the first focused invocation used the wrong UI-test target prefix and executed zero tests, and the next exposed an accessibility-container identifier masking its child retry identifier. Neither is counted as passing evidence; both were followed by the passing focused and complete runs above.

`F3C-MAC-UI-AUTOMATION` remains a mandatory F5/publish blocker under the approved one-probe policy. This remediation is **not** Independent Review verification and does not unlock F3-D. The next permitted action is the fourth Independent Review of F3-C.

### Fourth Independent Review — 0 findings; implementation review verified

Date: 2026-08-16 (Asia/Shanghai)

The fourth independent implementation review returned **0 findings**. The complete F3-C review chain is closed:

- initial Independent Review: **2×P1 + 2×P2**;
- second Independent Review after the first remediation: **2×P2**;
- third Independent Review after the second remediation: **1×P2**;
- fourth Independent Review after the third remediation: **0 findings**.

All accepted fixes and their evidence remain authoritative in the preceding sections: Backend-typed claim/receipt contracts, owner-scoped immutable attempts and unknown recovery, direct no-key attribution boundaries, shared cancellation/action reasons, the complete four-preview and direct-action matrix, receipt fact convergence, priority GET-only fact-refresh recovery, real iOS **12/12 with 0 failures**, dual Release/Gallery builds, macOS BFT-only evidence, 15 individually inspected macOS images, and the final diff/no-op-retry/clean-room/process checks.

F3-C terminal status is **Independent implementation review verified; `F3C-MAC-UI-AUTOMATION` deferred**. The deferred macOS runtime gate remains an explicit F5/publish blocker and is not waived, replaced or claimed complete by BFT, model tests or screenshots. Together with `F2C-MAC-UI-AUTOMATION`, `F3A-MAC-UI-AUTOMATION`, `F3B1-MAC-UI-AUTOMATION` and `F3B2-MAC-UI-AUTOMATION`, it must run on a repaired macOS automation environment before publish.

This 0-findings review unlocks only the next serial block, **F3-D Builder**. F3-E/F/G, F4/F5 and formal roots remain locked; no F3-D implementation was started by this documentation-only closeout.

## F3-D — Independent implementation review verified

Date: 2026-08-16 (Asia/Shanghai)

Status: **Independent implementation review verified; `F3D-MAC-UI-AUTOMATION` deferred.** Only F3-E Builder is unlocked; F3-F/G, F4/F5 and formal roots remain locked.

### Owned implementation and Backend authority

The Builder changed only the F3-D-owned surface and its minimal typed seams:

- `App/Sources/FiscalKit/V15/Features/CashFlow/**` for the owner-scoped model, native iOS decision surface and macOS spine/inspector;
- `App/Sources/FiscalKit/V15/Foundation/V15CashFlowContracts.swift` and the minimal cash-flow additions in `V15Services.swift`;
- `App/Sources/FiscalKit/V15/Shared/Fixtures/F3DFixtures.swift`, F3-D Gallery routing and the 10 SnapshotTool scenes;
- `App/Tests/FiscalKitTests/V15/F3DTests.swift`, `App/Tests/V15GalleryUITests/F3DGalleryUITests.swift`, and `App/Tests/V15GallerymacOSUITests/F3DMacGalleryUITests.swift`;
- the explicitly authorized Backend D5 seam only: cash-flow schemas/service/model, migration `20260816_0034_cash_flow_reimbursement_fact_amount.py`, and the focused P13 schema/PostgreSQL/migration tests.

Backend cash-flow schemas, routes, services and P5/P33 tests were treated as the only business authority. The typed boundary implements active `GET /cash-flow-items?account_id?`, optional-month history `GET /cash-flow-items/history?month?`, and manual detail `GET /cash-flow-items/{id}`. The Backend exposes no cursor/keyset contract for these lists, so the client does not invent one. Create and settle are the only stable-key writes. Settle sends exactly `{expected_version,actual_amount_minor,occurred_at,account_id,destination_account_id?,category_id?,title?,note?}`. Update, confirm, cancel and system-item `PUT` use the real expected version and direct response/readback semantics.

The model renders only server item/history/status/actions and never derives cash-flow truth from timeline or facts. Unknown status/direction raw values remain visible and read-only. Credit-cycle system projections are display-only. Reimbursement system projections expose only the server-permitted display edit while preserving the D5 fact amount/status. All CNY input uses `CNYAmountParser`; business dates and month validation use `Asia/Shanghai`. Transfer settlement requires two active cash/debit accounts and rejects identical source/destination accounts.

### Mutation, recovery and UI policy

Before the first create/settle wire, the model installs an owner-scoped immutable attempt containing the exact body, idempotency key and operation identity. Single-flight and offline guards therefore produce zero extra wires; unknown recovery can only resend the identical key/body. Every successful mutation force-refreshes active facts, the selected detail and history. If that convergence fails, writes remain gated and the only recovery is GET-only retry.

Update/confirm/cancel/system writes have no Backend request key. Their response-unknown state is never resent. A forced fresh GET may reveal current facts, but the Backend provides no operation marker with which to attribute the change, so the UI retains the unknown state and exposes explicit abandon only after that read. It never infers success or displays a false receipt. Selection generation, account owner, item owner and operation owner guards prevent stale async completion from replacing a newer surface.

Both platforms consume the same model guard for every enabled predicate and adjacent disabled reason. The iOS implementation is a stepwise native decision surface with local/remote error content inside the active sheet. macOS uses a native sidebar/spine/inspector layout. Fixtures cover normal, empty, initial/history error, field error, create/settle/direct unknown, 409, post-success refresh failure, selection race, offline and long/unknown-value states. The interactive and snapshot routes cover occurrence `this`/`this_and_future`, transfer accounts, confirm/settle/cancel, system fact, history/detail, conflict and both stable-key/direct unknown recovery.

Three defects were found by the real gates and corrected before this final evidence set: an outer iOS accessibility identifier masked descendant action identifiers; a settlement-date comparison rejected the current Shanghai business day before noon; and the summary used a sign-neutral money presentation for a negative server net. The final shared summary now visibly renders `−¥2,724.12` from the synthetic server net on both platforms.

### Verification

- `cd App && xcodegen generate` passed after adding the F3-D sources and targets.
- `FiscalmacOS build-for-testing -only-testing:FiscalKitTests/F3DTests` passed and compiles all **13** Swift Testing declarations. `V15GallerymacOS build-for-testing` passed and compiles the F3-D macOS UI-test target. These are compile/BFT evidence only and are not reported as runtime test passes.
- Final fixed-simulator `F3DGalleryUITests` aggregation passed from the final visible source state: **4 tests, 0 failures, 0 skipped** in **169.825 s**. The added fourth test switches active/history ownership and proves series edit omits create-only recurrence/end controls while retaining the server-boundary explanation. Result bundle during verification: `/private/tmp/fiscal-f3d-r1-ios.xcresult`.
- Formal Release builds passed from the final shared source state for `FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS`, and `V15GallerymacOS`. `V15GallerySnapshotTool` Release build and isolated run also passed.
- Exactly **10** final F3-D macOS PNGs were promoted to `screenshots/f3/` and opened individually: `light-spine`, `dark-spine`, `ax5`, `offline`, `history`, `occurrence-future`, `settle-transfer`, `system-fact`, `conflict`, and `unknown`. Source/output SHA-256 values match. Light/dark contrast, three-pane geometry, long/Int64 wrapping, visible reasons, history/detail, recurrence scope, transfer accounts, D5 system fact, 409 and both recovery surfaces have no blank output or clipping; longer content remains scrollable.
- Final `git diff --check`, cached diff check and the scoped clean-room search passed. Production `Features/CashFlow` contains no direct transport, `URLSession`, raw API path, old repository/DTO/View, `FiscalDesign`, Backend import, formal root or later F3 feature dependency; endpoint literals remain confined to the typed Foundation service. After verification no Xcode, Swift compiler, XCTest or SnapshotTool process remained, and only the exact regenerable `/private/tmp/fiscal-f3d-*` artifacts were removed; the promoted 10-image QA set remains in the repository.

### First independent-review remediation — Builder complete; awaiting second Independent Review

The first review found **1×P1 and 2×P2**. All three findings are repaired without unlocking F3-E:

- **P1 / D5 fact authority:** reimbursement system overrides can no longer persist or replay a client-supplied planned amount. The compatibility field is optional/deprecated at the Backend boundary and ignored by the service; new overrides store `NULL`, while active and history responses always derive the amount from the current reimbursement outstanding fact. Migration 0034 makes the column nullable and clears legacy reimbursement override amounts. PostgreSQL coverage proves a title/date override, a later partial receipt, a deliberately injected legacy frozen amount and a stale/wrong client amount cannot freeze or pollute the derived amount. Credit projection remains read-only and unchanged.
- **P2 / selection ownership:** account filter, history month and active/history surface changes advance list/detail ownership before awaiting network work, immediately clear the old editor/detail/action surface, cancel obsolete detail work and only auto-select from the current filter/month token. Controlled A→B and August→July races prove stale results cannot restore old detail or actions; the real iOS run proves the old active row disappears after switching to history.
- **P2 / recurrence boundary:** update wire bodies no longer contain `recurrence` or `recurrence_end_date`; the Backend replace schema rejects those extra fields and preserves the existing series boundary for both occurrence scopes. Create still owns recurrence inputs. Both native editors hide recurrence/end controls while editing and show the server-authority explanation for `this_and_future`.

The remediation gates are green: focused Backend P13/P17 schema, recovery, PostgreSQL and migration suites passed **19 tests** with only the existing Starlette deprecation warning; repository-wide Ruff and Pyright passed with **0 errors / 0 warnings**; an empty PostgreSQL database migrated from zero to head, and the focused migration test verifies legacy override cleanup. Apple BFT passed with the **13** F3-D model-test declarations, the real iOS suite passed **4/0**, all four Release products and SnapshotTool Release passed, and all **10** regenerated F3-D PNGs were opened individually. Eight images were byte-identical to the initial set; only `occurrence-future` and `conflict` changed for the new server-boundary explanation, and the promoted 10-image set matches the generated SHA-256 values. A fresh empty DerivedData root then built `FiscaliOS` for generic iOS Simulator and compiled `FiscalmacOS` plus `FiscalKitTests/F3DTests` with build-for-testing; no macOS runtime process was started.

### Deferred macOS runtime gate

The one permitted macOS runtime probe built successfully but remained in the local `testmanagerd` runner before any business test executed and was interrupted after 58 seconds. It was not retried. Neither BFT, source/model assertions nor SnapshotTool is claimed as a macOS runtime pass. `F3D-MAC-UI-AUTOMATION` is therefore deferred under the approved one-probe policy and remains a mandatory F5/publish blocker; on a repaired environment it must run the two compiled F3-D macOS UI tests covering the spine/inspector/editor and conflict/unknown/partial-refresh surfaces.

### Second Independent Review — 0 findings; implementation review verified

The second independent implementation review returned **0 findings** and requested no implementation or test changes. The complete F3-D review chain is **first review — 1×P1 + 2×P2; Builder remediation and full re-verification; second review — 0 findings**. The terminal review therefore closes the implementation-review gate.

Verification provenance remains explicit: the Backend **19/0** focused PostgreSQL result, zero-to-head migration, legacy override cleanup test, Ruff and Pyright results are Builder evidence recorded above. The second reviewer did **not** independently start PostgreSQL or rerun those database/migration commands, so the 0-findings result is not represented as a second PostgreSQL runtime pass. No residual implementation finding was reported; the remaining runtime limitation is the separately deferred macOS UI automation gate.

F3-D is **Independent implementation review verified; `F3D-MAC-UI-AUTOMATION` deferred**. This unlocks only **F3-E Builder**. Apart from the explicitly authorized Backend cash-flow D5 seam, F3-E/F/G, F4/F5 and formal roots were not modified by this closeout; F3-F/G, F4/F5 and formal roots remain locked.

## F3-E — Independent implementation review verified; `F3E-MAC-UI-AUTOMATION` deferred

Initial Builder status: **Builder complete; awaiting Independent implementation review; `F3E-MAC-UI-AUTOMATION` deferred.** F3-F/G, F4/F5 and formal roots remain locked. No Backend file was modified by this Builder.

### Owned implementation and Backend-authoritative contract

- `App/Sources/FiscalKit/V15/Features/Reconciliation/**`
- the minimal typed reconciliation boundary in `V15ReconciliationContracts.swift` and `V15Services.swift`
- `App/Sources/FiscalKit/V15/Shared/Fixtures/F3EFixtures.swift`
- the F3-E Gallery route and 13 SnapshotTool scenes
- `App/Tests/FiscalKitTests/V15/F3ETests.swift`
- `App/Tests/V15GalleryUITests/F3EGalleryUITests.swift`
- `App/Tests/V15GallerymacOSUITests/F3EMacGalleryUITests.swift`

The typed service sends checkpoint list reads with exactly one of `account_id` or `credit_cycle_id`, checkpoint detail by ID, diagnosis with `target_kind`, UTC `as_of` and exactly one target ID, and the attention list. Checkpoint creation is the direct atomic `POST /reconciliation/checkpoints` with the exact body `{target_kind, exactly-one account_id|credit_cycle_id, as_of, actual_balance_minor, note?}` and no idempotency key. Attention ignore is sent only when the current item contains an enabled Backend `available_actions.ignore`; the UI preserves the Backend reason when disabled and sends the real `expires_at` when enabled. Its 204 response is represented by the typed no-content seam rather than a fabricated receipt.

Both direct writes install an immutable, owner-scoped attempt before the first wire. A lost response never causes a resend. The client performs only forced-fresh list/fact `GET`s and, because the Backend exposes no operation marker, never attributes target-looking state to that attempt. The lock can be released only by explicit abandon after a successful fresh read. Offline writes are zero-wire. A successful checkpoint write refreshes checkpoint list/detail, diagnosis and attention; refresh failure remains a visible accepted-write gate whose retry is GET-only. Target, date, checkpoint, attention and operation ownership use generation/semantic-owner guards, including A/B selection races and invalid input changes.

### Native surfaces, fixtures and disabled-action policy

The iOS surface uses a stepped target → facts → final-confirmation editor with in-sheet field and service errors. The macOS surface uses an account/credit-cycle spine, checkpoint history and difference inspector. `CNYAmountParser` is the only amount parser; zero and negative CNY values are accepted, malformed precision is rejected, Shanghai business dates are validated and API timestamps remain UTC. Every disabled button consumes the same model reason list as the guard. There is no UI-only capability guess or silent model return.

Fixtures and UI routes cover account and credit-cycle exact-one requests; open/reconciled checkpoints; missing, overdue and unknown attention; Backend-disabled ignore reason; diagnosis/service errors and retry; 409 conflict; response-unknown and fresh-facts/explicit-abandon recovery; accepted-write partial refresh; field errors; offline; empty; long `Int64`/AX5; light and dark appearance. A moving-clock regression test also proves that a valid “today” diagnosis is owned by the captured date input rather than equality between two advancing `now()` instants.

### Verification

- `cd App && xcodegen generate` passed after adding the F3-E sources and tests.
- `FiscalmacOS build-for-testing -only-testing:FiscalKitTests/F3ETests` passed and compiles all **11** F3-E Swift Testing declarations. `V15GallerymacOS build-for-testing -only-testing:V15GallerymacOSUITests/F3EMacGalleryUITests` passed and compiles both F3-E macOS UI-test declarations. These are compile/BFT evidence only; no macOS runtime pass is claimed.
- The final real fixed-simulator `F3EGalleryUITests` run passed **4 tests, 0 failures, 0 unexpected failures** in **148.216 s**. The flows exercise both target kinds and the stepped form, invalid-to-valid field reasons, Backend-disabled attention, attention response-unknown recovery, checkpoint response-unknown fresh facts and explicit abandon, 409/error retry, accepted-write partial refresh and offline zero-wire policy. Result bundle: `/private/tmp/fiscal-f3e-ios-4of4.xcresult` (regenerable bundle removed only after recording this evidence).
- Formal Release builds passed for `FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS` and `V15GallerymacOS`. `V15GallerySnapshotTool` Release also built and its executable ran successfully with the matching Release framework path.
- Exactly **13** F3-E macOS PNGs were promoted to `screenshots/f3/` and opened individually: `light-spine`, `dark-spine`, `ax5`, `offline`, `empty`, `service-error`, `diagnosis-error`, `editor-confirm`, `conflict`, `keyless-unknown`, `attention-disabled`, `attention-unknown` and `partial-refresh`. The inspection found readable three-pane geometry, light/dark contrast, long content, visible field/action reasons and the required recovery gates without blank output or blocking clipping.
- `git diff --check` and `git diff --cached --check` passed. Scoped clean-room scans found no direct `APITransport`, `URLSession`, raw reconciliation path, old repository/DTO/View, `FiscalDesign`, Backend import, formal root or later F3 dependency in production `Features/Reconciliation`. Raw endpoint strings remain only inside the typed Foundation service.

### Deferred macOS runtime gate

The one permitted macOS runtime probe built and linked successfully but remained in the local `testmanagerd` runner before any business test executed, so it was interrupted and not retried. Neither BFT, model/source assertions nor SnapshotTool is reported as a macOS runtime pass. `F3E-MAC-UI-AUTOMATION` remains a mandatory F5/publish blocker; on a repaired environment it must run the two compiled F3-E macOS UI flows for the spine/inspector/editor and conflict/unknown/partial-refresh surfaces.

F3-E is therefore **Builder complete; awaiting Independent implementation review; `F3E-MAC-UI-AUTOMATION` deferred**. This does not unlock F3-F. The next permitted action is an Independent implementation review of F3-E.

### First independent-review remediation — Builder complete; awaiting second Independent Review

Status: **First-review remediation Builder complete; awaiting second Independent Review; `F3E-MAC-UI-AUTOMATION` remains deferred.** The first review reported **1×P1, 1×P2 and 1×P3**. All three findings are repaired. F3-F/G, F4/F5 and formal roots remain locked, and no Backend file was modified.

- **P1 / direct no-key outcome classification and owner recovery:** checkpoint creation and attention ignore now share the typed `outcomeMayBeUnknown` classifier. The immutable owner attempt is installed before the first wire. Cancellation, transport cancellation, invalid response bodies and other response-unknown outcomes retain that attempt in `unknown`; no second POST is available. Recovery remains forced-fresh GET/list/attention only followed by explicit abandon when attribution is impossible. Deterministic request/field rejection and 409 remain distinct from response-unknown. Every success, failure and cancellation callback checks the operation ID and semantic owner before changing state. The editor may close and reopen the active unknown owner; A→B inspection hides A's recovery surface without losing the lock, and B→A restores it.
- **P2 / complete macOS mutation surface:** macOS now mirrors the iOS loading, response-unknown, accepted-refresh and deterministic-failure phases. Deterministic failure uses stable `v15.f3e.mac.mutation.error` / `.mutation.retry` identifiers and invokes a real new owner-scoped operation; checkpoint and attention-ignore labels remain distinct. Unknown has no ordinary mutation retry and retains only fresh-fact recovery plus explicit abandon. No empty or no-op retry closure remains.
- **P3 / independent partial-fact refresh:** the accepted-write partial-refresh surface has stable `v15.f3e.mac.fact-refresh` / `.fact-refresh.retry` identifiers, calls the real GET-only refresh path and consumes the model's offline/concurrent disabled reasons. It cannot overlap another fact refresh or mutate server state.

Fixtures now record POST-before-throw paths for checkpoint and attention-ignore cancellation and invalid response bodies, plus a deterministic first rejection that can safely create a new operation on retry. Model coverage asserts one and only one POST for every response-unknown variant, retained owner attempts, GET-only recovery, close/reopen and A/B restoration, explicit abandon, deterministic retry and input invalidation. The real iOS suite adds the cancelled-checkpoint UI flow and proves the editor can close/reopen while the unknown operation remains locked, ordinary retry is absent, fresh GET is used and explicit abandon is required.

#### Remediation verification

- `cd App && xcodegen generate` passed for the final source graph.
- `FiscalmacOS build-for-testing -only-testing:FiscalKitTests/F3ETests` passed and compiles all **14** F3-E Swift Testing declarations. `V15GallerymacOS build-for-testing -only-testing:V15GallerymacOSUITests/F3EMacGalleryUITests` passed and compiles both F3-E macOS UI declarations, including source assertions for the deterministic mutation retry and independent fact-refresh retry. These remain BFT/source evidence only; macOS runtime was not rerun.
- The new cancelled-response iOS test passed focused **1/0** in **31.000 s**. The final fixed-simulator aggregation then passed **5 tests, 0 failures, 0 skipped and 0 unexpected failures** in **179.881 s** on iPhone 17 Pro simulator `211DD03C-812D-4A42-97EF-F693D7DF924C`. Verification bundle: `/private/tmp/fiscal-f3e-r1-ios-full2.xcresult` (regenerable bundle removed after evidence recording). An earlier complete run was **5 tests, 1 failure** because it asserted a parent SwiftUI accessibility label would concatenate a child title; that run is explicitly non-evidence. The assertion was narrowed to stable surface/action identifiers, the focused repair passed, and only the final 5/0 aggregation is claimed.
- Final Release builds passed for `FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS` and `V15GallerymacOS`. `V15GallerySnapshotTool` Release build and isolated executable run passed with the matching Release framework path.
- Exactly **14** F3-E macOS PNGs were regenerated, opened one-by-one and promoted with matching source/output SHA-256 values: the prior 13 scenes plus `mutation-error`. `mutation-error` visibly exposes the deterministic owner/action-specific real retry; `partial-refresh` exposes the independent GET-only fact retry; the checkpoint and attention unknown scenes expose fresh GET and explicit abandon without ordinary POST retry. The full set has no blank output or blocking clipping.
- Final `git diff --check`, cached diff check, declaration/identifier checks and scoped clean-room scans passed. Production `Features/Reconciliation` contains no direct transport, `URLSession`, raw reconciliation path, old repository/DTO/View, `FiscalDesign`, Backend import, formal root or later F3 dependency; raw endpoint literals remain confined to the typed Foundation service.

The single permitted macOS runtime probe remains the same previously recorded `testmanagerd` blocker and was not repeated. `F3E-MAC-UI-AUTOMATION` is still a mandatory F5/publish blocker. F3-E is now **first-review remediation Builder complete; awaiting second Independent Review**. This status does not unlock F3-F.

### Second independent-review remediation — Builder complete; awaiting third Independent Review

Status: **Second-review remediation Builder complete; awaiting third Independent Review; `F3E-MAC-UI-AUTOMATION` remains deferred.** The second review reported **1×P2**: deterministic retry owned the captured typed request but did not also preserve and compare a stable representation of the visible form, so an advancing clock or changed input could make retry ownership ambiguous. The finding is repaired without unlocking F3-F/G, F4/F5 or formal roots, and no Backend file was modified.

- A deterministic failed checkpoint now retains both its exact typed request and a stable visible-form fingerprint: target kind/ID, canonical minor-unit amount, the literal `asOfDateText`, trimmed note and semantic owner. Attention-ignore retains the corresponding item/source/date fingerprint. Retry compares the current visible fingerprint before changing phase or clearing any failure; it reuses the captured typed request and never rebuilds a moving “today” timestamp.
- Amount, date, target or owner changes explicitly invalidate the failed intent. The model keeps the failure visible, moves checkpoint entry back to confirmation when appropriate and returns the same `mutation_intent_changed` reason consumed by the button predicate and adjacent disabled copy. A changed form sends **zero** retry wire calls until the user confirms and submits it as a new intent.
- Offline, accepted-refresh, concurrent-operation, owner-mismatch and changed-input guards all run before retry can enter loading. A deterministic re-failure remains failed and retryable; cancellation, invalid response or other possibly-written outcomes still transition to the existing owner-scoped unknown gate with no second POST; success performs the normal fresh fact refresh.

Model coverage keeps **14** Swift Testing declarations and adds the moving-clock proof: the first checkpoint fails deterministically at T0, the clock advances to T1 while the same visible “today” form remains unchanged, and retry sends a second wire whose request body is exactly the captured original. Separate amount, date and target mutations produce no retry wire and an explicit reconfirmation/new-intent reason. The real iOS suite adds a deterministic-failure route whose first POST must fail and whose second can succeed only after the wall clock advances, proving the retry is neither silent nor rebuilt from a moving instant.

#### Second-remediation verification

- `cd App && xcodegen generate` passed. `FiscalmacOS build-for-testing -only-testing:FiscalKitTests/F3ETests` passed with all **14** F3-E model declarations, and `V15GallerymacOS build-for-testing -only-testing:V15GallerymacOSUITests/F3EMacGalleryUITests` passed with both macOS UI declarations. These remain compile/BFT evidence; macOS runtime was not started.
- The focused deterministic moving-clock iOS flow passed **1 test, 0 failures** in **25.578 s**. The final fixed-simulator aggregation passed **6 tests, 0 failures, 0 skipped and 0 unexpected failures** in **204.805 s** on iPhone 17 Pro simulator `211DD03C-812D-4A42-97EF-F693D7DF924C`. Verification bundles were `/private/tmp/fiscal-f3e-r2-ios-focused.xcresult` and `/private/tmp/fiscal-f3e-r2-ios-full.xcresult` and were removed only after recording the evidence.
- Final Release builds passed for `FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS` and `V15GallerymacOS`. `V15GallerySnapshotTool` Release build and isolated executable run passed with the matching Release framework path.
- Exactly **14** F3-E macOS PNGs were regenerated, opened individually and promoted. The set includes `mutation-error`, which shows the owner/action-specific deterministic retry, and `partial-refresh`, which shows the independent GET-only fact retry. Light/dark, AX5, offline, error, conflict, unknown, disabled-action, empty and confirmation states have no blank output or blocking clipping. Every generated/promoted SHA-256 pair matches.
- The first model BFT attempt exposed a missing explicit `return` in the new optional checkpoint-fingerprint helper. That compile attempt is not acceptance evidence; the helper was corrected immediately and the final model/macOS UI BFT, real iOS runs, all Release builds and SnapshotTool gates passed from the repaired source.
- Final `git diff --check`, cached diff check, declaration/identifier/fingerprint checks and scoped clean-room searches passed. Production `Features/Reconciliation` contains no direct transport, `URLSession`, raw reconciliation path, old repository/DTO/View, `FiscalDesign`, Backend import, formal root or later F3 dependency; raw endpoint literals remain confined to the typed Foundation service.

The macOS runtime limitation is unchanged: the single permitted earlier probe reached the shared `testmanagerd` blocker before any business test and was not repeated. `F3E-MAC-UI-AUTOMATION` remains a mandatory F5/publish blocker. F3-E is now **second-review remediation Builder complete; awaiting third Independent Review**. This status does not unlock F3-F.

### Third Independent Review — 0 findings; implementation review verified

The third independent implementation review returned **0 findings** and requested no implementation or test changes. The complete F3-E review chain is **`1×P1+1×P2+1×P3 → 1×P2 → 0 findings`**: first review findings, Builder remediation and re-verification; second review finding, Builder remediation and re-verification; third review with no residual finding. The terminal review closes the F3-E implementation-review gate.

Verification provenance remains explicit: the final model/macOS UI BFT declarations, focused and complete real iOS runs, four Release builds, SnapshotTool run, 14-image visual inspection, matching hashes and clean-room checks are Builder evidence recorded above. The third reviewer reported no residual implementation finding and did not create another runtime result. `F3E-MAC-UI-AUTOMATION` therefore remains deferred and is still a mandatory F5/publish blocker; the 0-findings implementation review does not replace that runtime gate.

F3-E is **Independent implementation review verified; `F3E-MAC-UI-AUTOMATION` deferred**. This unlocks only **F3-F Builder**. F3-G, F4/F5 and formal roots remain locked.

## F3-F Backend D3 prerequisite — Builder complete; awaiting Independent Review

Status: **F3-F Backend D3 Builder complete; awaiting Independent Review.** F3-F frontend remains paused and has not resumed; F3-G, F4/F5 and formal roots remain locked. This entry records Builder evidence only and does not claim an independent review.

### Backend-authoritative repair

- Migration `20260816_0035_retire_ai_auto_execute.py` follows actual head `20260816_0034`, clears every persisted `ai_settings` and `ai_execution_policies` enable flag, then installs fail-closed checks on both tables. Downgrade removes only those schema checks and deliberately never restores a retired `true` fact.
- Settings and strategy responses keep their compatibility fields but type and return `auto_execute_enabled=false`; settings also always returns `effective_auto_execute=false`, including a legacy enabled row with a configured provider.
- Both settings and strategy write paths reject enable attempts and limit/confidence relaxations with HTTP 409 code `ai_auto_execute_retired`. A false, tighter or ordinary non-automatic settings/source update remains writable. The rejection is evaluated before stale-version handling so an enable attempt cannot obtain a different legacy outcome from an old expected version. A two-session PostgreSQL race proves the advisory lock accepts the concurrent tightening while the legacy relaxation still receives the retirement code.
- Proposal create and retry still parse through the configured provider and deterministic rules, but parse/finalize always stops at `pending`, records the parsed event and creates no transaction or cash-flow item. Only the existing explicit human `execute` path can create the corresponding fact; its edit, idempotent replay, version, undo and manual quality-event behavior remains covered.
- Archive export and every restore/import decode path force both compatibility flags to false. PostgreSQL constraints provide a second fail-closed boundary for direct or legacy rows. Historical `automatic_execute` quality-event vocabulary is retained read-only for old metrics; there is no executable automatic branch.

Owned implementation paths are `Backend/src/fiscal_api/api/p8_schemas.py`, `Backend/src/fiscal_api/db/models/ai.py`, `Backend/src/fiscal_api/services/{ai,archive}.py`, migration 0035, and the focused P8/P35 tests. No route/repository edit was required after tracing both writes to the repaired service boundary. No App/F3-F frontend file was changed by this prerequisite repair.

### Verification

- A disposable empty PostgreSQL database upgraded from zero through the linear chain to `20260816_0035 (head)`. The focused migration test then exercised `0034 → 0035`, cleaned seeded legacy-true settings and policy rows, verified both database checks reject direct `true`, downgraded to 0034 without resurrecting either flag, and re-upgraded to head. Focused migration/archive result: **2 passed, 0 failed**.
- A real encrypted archive was exported with settings and an execution-policy row, its legacy payload was changed to `true` for both tables, its canonical hash was recomputed, and it was sealed and reopened through `ArchiveService.open` before the actual PostgreSQL restore. `ArchiveService.restore_empty_target` restored both flags as `false`. The existing complete P22 archive/restore integration suite also remained in the related gate.
- Related AI/provider/migration/archive command passed **59 tests, 0 failures** in **11.84 s**: `tests/test_p8_provider.py`, `test_p8_migration_postgres.py`, `test_p8_policy.py`, both P35 files, `test_p8_postgres.py`, `test_p8_api_postgres.py` and `test_p22_archive_revision_postgres.py`. This includes stable API error codes, provider-configured false reads, stale-version and concurrent-policy rejection, parse-finalize zero-fact behavior, manual edited execute, idempotent execute replay, repayment execute, future cash-flow execute and undo.
- Final Backend-wide PostgreSQL run passed **386 tests, 0 failures** in **87.87 s**. The only warning in these pytest runs is the environment's existing Starlette `TestClient`/httpx2 deprecation warning.
- Repository-wide `uv run ruff check .` passed. Repository-wide `uv run pyright` passed with **0 errors, 0 warnings**. Scoped Ruff and `ruff format --check` passed for all D3-owned source, migration and test paths, and the post-format unit rerun passed **11/11**.
- Repository-wide `ruff format --check .` is explicitly **not** recorded as a D3 pass: it still reports two shared, non-owned paths, `Backend/src/fiscal_api/services/cash_flow.py` and `Backend/tests/test_p13_cash_flow_postgres.py`. This Builder did not format or otherwise modify those files. D3 scoped format and `git diff --check` are clean.
- Final disposable database inspection reported one head, `20260816_0035`, and both D3 check constraints. Source scan found transaction creation only inside the explicit manual `execute` method; parse/finalize has no transaction mutation path.

The next permitted action is an **Independent Review of the F3-F Backend D3 prerequisite**. F3-F frontend may resume only after that review reaches 0 findings; F3-G remains locked.

### First Independent Review — 1×P2; remediation Builder complete; awaiting second IR

The first independent review did not pass and reported **1×P2**: strategy replacement compared against the latest row from every scope and omitted `minimum_sample_size`, so a policy could lower sample size from 30 to 1 and unrelated source/kind scopes could incorrectly set each other's baseline.

The remediation is deliberately limited to that finding:

- `AIRepository.latest_policy_for_scope` now resolves the newest row for the exact `(source, transaction_kind)` pair using explicit NULL-safe equality and optional `FOR UPDATE`. `replace_policy` remains inside the repository-wide transaction advisory mutation lock, so even a previously empty scope is serialized; existing exact-scope rows are additionally locked before comparison.
- Global `ai_settings` remains the fail-closed amount ceiling and confidence floor inherited by every scope. A scoped row can only tighten those values. Once a scope has history, its own latest row further tightens the baseline; another scope is never consulted. Because settings has no sample-size field, every first scope receives the explicit retirement baseline **30**, and later writes compare against the greater of 30 and that exact scope's previous sample size.
- The all-table latest policy query is now used only under the same advisory lock to preserve the existing globally increasing response `version`; it no longer supplies strategy-relaxation values.
- `_reject_retired_auto_execute` now rejects `minimum_sample_size < current_minimum_sample_size` with the same stable `ai_auto_execute_retired` code. Settings supplies a neutral 30→30 pair because its schema has no sample field; strategy supplies the exact candidate and resolved fail-closed scope baseline.
- Controlled unit/API/PostgreSQL coverage proves first-scope 30→1 rejection, same-scope sample relaxation rejection, legal same-scope three-dimensional tightening, independent text/OCR baselines, `transaction_kind=NULL` as an exact scope rather than a wildcard, response fields remaining false, and a two-session same-scope race in which only the tightening commits. The rejected concurrent sample-size-1 row is absent from policy history; stale settings enable remains the retirement code.

Remediation verification from the final source state:

- Focused unit helper: **10 passed, 0 failed**. Focused D3 policy/API/PostgreSQL aggregation: **28 passed, 0 failed**. The complete related provider/migration/archive/P8/P22 gate passed **60 tests, 0 failures** in **16.95 s**.
- Backend-wide PostgreSQL run passed **387 tests, 0 failures** in **81.78 s**. Migration 0035, authenticated legacy-true archive restore, parse-finalize zero-fact behavior, explicit manual execute/replay/undo and response false regressions all remained green. The sole warning remains the existing Starlette `TestClient`/httpx2 deprecation warning.
- Repository-wide Ruff passed; repository-wide Pyright passed with **0 errors, 0 warnings**; all remediation-owned files pass scoped `ruff format --check` and `git diff --check`. Repository-wide format is still not claimed because the same two non-owned shared paths, `Backend/src/fiscal_api/services/cash_flow.py` and `Backend/tests/test_p13_cash_flow_postgres.py`, would be reformatted and were not touched.
- The disposable database ended at the single `20260816_0035 (head)` with both retirement constraints present. No migration, archive implementation, settings/strategy false response, parse/manual-execute code or App frontend file was changed by this remediation.

Status: **F3-F Backend D3 first-review remediation Builder complete; awaiting second Independent Review.** F3-F frontend remains paused; F3-G, F4/F5 and formal roots remain locked. No second review is claimed here.

### Second Independent Review — 0 findings; Backend D3 verified

The second independent review returned **0 findings**. The complete Backend D3 review chain is **`1×P2 → remediation → 0 findings`**: the first review found the cross-scope/sample-size relaxation gap, the Builder repaired and reverified it, and the second review reported no residual implementation finding.

Evidence provenance remains explicit. The initial related **59/0**, remediation related **60/0**, Backend-wide **387/0**, zero-to-head migration, 0034↔0035 retirement checks, authenticated legacy-true archive restore, manual execute/undo and two-session scope race are Builder PostgreSQL evidence recorded above. The second reviewer did **not** independently start PostgreSQL or rerun those commands, so the terminal 0-findings result is not represented as a second PG runtime pass.

Backend D3 is therefore **Independent implementation review verified**. This unlocks only **F3-F frontend Builder**. F3-G, F4/F5 and formal roots remain locked; the frontend must continue to enforce false-only settings, explicit human confirmation and the absence of automatic-execution, provider-secret and financial-chat UI.

## F3-F frontend — Builder complete; awaiting Independent Review

### Scope and contract audit

Owned frontend evidence is limited to `V15/Foundation/V15AIContracts.swift`, `V15/Features/AI/**`, `Shared/Fixtures/F3FFixtures.swift`, the F3-F Gallery route/SnapshotTool scene and `F3FTests` / iOS/macOS Gallery tests. It uses the typed AI service only: D3 decoding rejects either legacy `auto_execute_enabled=true` or `effective_auto_execute=true`; the visible setting remains false-only. There is no automatic-execution, strategy-relaxation, provider-secret or financial-chat affordance. A draft save is required before explicit human execute; ignore/retry/undo carry exact versions, undo includes the transaction version, and keyless response-unknown takes a fresh GET-only readback without re-sending or attributing a result.

The iOS sheet keeps remote field errors inside the sheet, and macOS has a proposal spine, fact detail and safety/action inspector. Model guards supply the same disabled reasons to both surfaces, including offline and an in-flight/unknown mutation; the sheet disables dismissal while a direct write is loading or unknown. Controlled fixtures cover all known statuses plus a forward-readable display-only future state, missing/low confidence, edit→confirm→manual execute, failed retry, ignore/undo, 409, deterministic error, no-key unknown and offline zero-write behavior.

### Final current-source verification

- `cd App && xcodegen generate` passed after the final Gallery-only initial-state correction. `FiscalmacOS build-for-testing` compiled all **11** F3-F Swift Testing declarations; `V15GallerymacOS build-for-testing` compiled both **2** F3-F macOS UI declarations. This is BFT/compile evidence only.
- Fixed simulator `211DD03C-812D-4A42-97EF-F693D7DF924C` ran `V15GalleryUITests/F3FGalleryUITests` from the final source into `/private/tmp/fiscal-f3f-final/F3FGalleryUITests-final2.xcresult`: **6 passed, 0 failed, 0 skipped** in **177.796 s**. It covers D3 false-only, confidence/missing/unknown display-only, confirmed manual execution, retry/ignore/undo, sheet-local field error, keyless GET-only recovery, same-key create recovery, conflict, empty/error/offline and AX5 long content. The bundle `Info.plist` SHA-256 is `4c70e28c70fd451c85428f84324e79885353df01cdb56020a0492327c8e003eb`.
- Final serialized Release builds passed for `FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS` and `V15GallerymacOS`; `V15GallerySnapshotTool` Release build and isolated executable run passed with the matching Release framework path.
- SnapshotTool generated exactly **11** F3-F synthetic macOS PNGs, each opened individually and promoted with matching SHA-256: `f3f-mac-{light-spine,dark-compact,review-sheet,ax5-long,offline,empty,service-error,field-error,conflict,response-unknown,d3-contract-error}.png`. The final Gallery-only scenario uses a 1.5-second settle so the async field-error, conflict and response-unknown routes reach their terminal state rather than silently falling back to the default queue. The complete spine/detail/inspector layout, D3 error, offline read-only explanation, AX5 long state, empty/error, visible conflict/unknown lock and no forbidden UI were visually checked. The headless AppKit host does not substitute for a live macOS sheet interaction; the real iOS suite is the interaction evidence.
- `git diff --check`, `git diff --cached --check`, owned-path trailing-whitespace scan and clean-room searches passed. Production `Features/AI` contains no direct `APITransport`/`URLSession`, raw API literal, old AI repository/DTO/View, `FiscalDesign`, formal root or later-F3 dependency. No Xcode, XCTest, SnapshotTool or Swift compiler process remained.

### Deferred runtime and non-counting history

The two prior macOS runtime attempts reached the shared `testmanagerd`/worker-materialization root with **0 business tests** (one recorded F3-F interruption: `waiting for workers to materialize`); neither is a pass and no third probe was made. `F3F-MAC-UI-AUTOMATION` is therefore an F5/publish blocker alongside the seven earlier macOS gates. An earlier interrupted iOS attempt with no durable `/private/tmp/fiscal-f3f*` bundle is diagnostic only and contributes no count; only the final bundle above is acceptance evidence.

Status: **F3-F frontend Builder complete; awaiting Independent Review.** F3-G, F4/F5 and formal roots remain locked.

## F3-F frontend — first-review remediation Builder complete; awaiting second Independent Review

### First-review findings and repair

The first frontend review returned **2×P1 + 3×P2**. The two P1s were ownerless keyless-recovery failure paths that could hide a still-locked direct write, and treating a `cash_flow` target as an immediate transaction proposal. The P2s were stale owner/generation callbacks, kind-switch reference leakage, and macOS pagination lacking the iOS loading/error/retry state.

- Direct attempts are now immutable, proposal-owner-scoped records containing the operation, request body, editor generation and fingerprint. Each owner retains its `.unknown` or `.conflict` state, message and retry gate across selection/sheet changes. A failed fresh GET remains a visible GET-only retry with writes locked; conflict reload likewise remains reloadable. Explicit abandon is enabled only after a successful fresh readback. No recovery code resends a mutation or attributes an outcome.
- Review data is typed as transaction versus cash-flow. For the authoritative P8 replace wire, the client still sends only `AIProposalReplace(draft: TransactionDraft, expected_version:)`; the typed cash-flow presentation/validation accepts only income, expense and transfer, shows planned amount/date/direction and does not claim an immediate transaction will be created. Future unknown targets remain display-only.
- Direct/readback/conflict state and callbacks are owner-scoped. A stale callback may update only its own row and may not confirm a changed editor fingerprint; `A → B → A`, write→edit and success/unknown/failure races are covered. The global direct-attempt lock remains single-flight.
- `changeKind` clears category, destination and credit-cycle references that no longer apply; draft guards validate account direction/type, transfer non-self destination and repayment credit/cycle ownership from typed master-data facts before any wire is made.
- macOS spine pagination now mirrors iOS `pagePhase`, preserves loaded pages on a local error and exposes owner-tokenized loading/error/retry controls. Gallery fixtures cover the page-error terminal state.

### Final remediation verification

- `cd App && xcodegen generate`; `xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' build-for-testing -quiet`; and the matching `V15GallerymacOS` build-for-testing all passed. Final source declares **15** `F3FTests` and **3** macOS F3-F Gallery UI tests; BFT is compile evidence only.
- Fixed simulator `211DD03C-812D-4A42-97EF-F693D7DF924C` ran `xcodebuild -project App/Fiscal.xcodeproj -scheme V15GalleryiOS -destination 'platform=iOS Simulator,id=211DD03C-812D-4A42-97EF-F693D7DF924C' -only-testing:V15GalleryUITests/F3FGalleryUITests test -resultBundlePath /private/tmp/fiscal-f3f-remediation/F3FGalleryUITests-remediation2.xcresult`: **7 passed, 0 failed, 0 skipped** in **216.489 s**. Its `Info.plist` SHA-256 is `ba0f07973e2b431e4d575d5f42ab8fa42eb01a1cba1633308764aa66176e69a4`. This is the sole final iOS acceptance bundle; the first remediation run was diagnostic **5/2**, and the former pre-review **6/0** bundle is superseded.
- Final source Release builds passed for `FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS`, `V15GallerymacOS`, and `V15GallerySnapshotTool`; the SnapshotTool Release executable ran to completion against its matching Release framework.
- SnapshotTool produced and promoted exactly **14** F3-F PNGs under `screenshots/f3/`; byte-for-byte `cmp` and SHA-256 checks passed. The matrix is `f3f-mac-{light-spine,dark-compact,review-sheet,ax5-long,offline,empty,service-error,field-error,conflict,response-unknown,response-unknown-read-failure,d3-contract-error,page-error,cash-flow-review}.png`. Every image was opened individually: the mac spine/detail/inspector, cash-flow target wording, sheet/error state, unknown and conflict locks, local page retry, offline/empty/error and AX5 long states were visible; no chat, provider secret, strategy control or auto-execute affordance appeared.
- `git diff --check`, `git diff --cached --check`, owned-path whitespace and raw-transport/root/old-layer searches passed. No F3-F Xcode/XCTest/SnapshotTool process remained. Only F3-F named screenshots were promoted; no Backend path was changed. The requested precise `/private/tmp/fiscal-f3f-*` cleanup remains unperformed because the command safety policy rejected the removal; no bypass was attempted.

### Deferred runtime and next gate

The two earlier macOS runtime attempts remain **0 business tests** at the shared `testmanagerd` worker-materialization failure. No macOS runtime was rerun, so `F3F-MAC-UI-AUTOMATION` remains the eighth F5/publish blocker. Status: **first-review remediation Builder complete; awaiting second Independent Review.** F3-G, F4/F5 and formal roots remain locked.

## F3-F frontend — second-review remediation Builder complete; awaiting third Independent Review

The second review reported **1×P1 + 4×P2**. Root accepted the P1 confirmation-identity issue and the three P2s for readback generation, stale mutually-exclusive fields, and deterministic owner failure. The remaining fixture-production P2 is **rejected by authority**: frozen `PROJECT_PLAN.md §4` assigns `V15/Shared` to fixture/Gallery injection with one FiscalKit target and separate Gallery hosts; formal roots have no fixture route. F3-F therefore does not invent a conflicting module boundary.

- Confirmation is now an owner record `{proposal ID, proposal version, server fingerprint, exact target+wire-draft fingerprint}`. Fresh list/select/readback/conflict facts invalidate it on any mismatch; input or sheet dismissal invalidates it; execute requires a current exact match. Gallery PUT fixtures now echo the complete request draft (kind, amount, date, title, note and all account/category/cycle fields) while preserving the server target/version, and real iOS covers edit title → confirm → manual execute.
- Unknown and conflict GET recovery each use an owner generation and loading gate. Stale success/failure/cancel cannot overwrite a newer readback; the visible loading reason uses the same disabled reason on both platforms. Normal deterministic failures remain in owner-local `directStates`, retain field issues after `A → B → A`, and leave the write lock clear for a new decision.
- `makeDraft` rejects stale incompatible shapes before a wire: income/expense and credit purchase destination/cycle, transfer category/cycle, and repayment category; cash-flow compatibility drafts use the same validation. The expanded model matrix also covers exact unchanged confirmation, changed server version/draft, single-flight recovery, owner failure and zero invalid mutation wire.

Final current-source verification: `xcodegen generate`, `FiscalmacOS build-for-testing` and `V15GallerymacOS build-for-testing` passed with **19** F3-F model, **8** iOS UI and **3** macOS UI declarations (BFT only; no macOS runtime). Fixed simulator `211DD03C-812D-4A42-97EF-F693D7DF924C` ran the sole final bundle `/private/tmp/fiscal-f3f-remediation/F3FGalleryUITests-remediation8.xcresult`: **8 passed, 0 failed, 0 skipped**, **238.569 s**, `Info.plist` SHA-256 `2f6edc431289e74d1bab14e5e81221b5db78f3a1ebcb820ac79052d7ee5ca2d7`. Earlier remediation3–7 runs are diagnostic/non-final; remediation6's 8/0 deliberately weakened the title-edit test and is expressly non-evidence.

All four Release builds (`FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS`, `V15GallerymacOS`) and SnapshotTool Release build/run passed. SnapshotTool regenerated **14** F3-F PNGs; every file was opened individually and exact-promoted with `cmp`: light/dark spine, review, AX5, offline/empty/error/field-error, conflict, unknown/readback failure, page error, cash-flow and D3 error. No visual product issue, forbidden chat/secret/strategy/auto-execute affordance, duplicate sheet AX, or blocked-layout clipping was seen. `git diff --check`, cached diff check and scoped raw transport/root/old-layer scans passed; the approved temporary-directory deletion remains unperformed after the safety policy rejection. `F3F-MAC-UI-AUTOMATION` remains the eighth F5/publish blocker; F3-G/F4/F5/formal roots remain locked.

Status: **`1P1+4P2 reported; fixture P2 rejected by authority; accepted 1P1+3P2 repaired; awaiting third Independent Review`.**

## F3-F frontend — third-review remediation Builder complete; awaiting fourth Independent Review

### Third-review findings and authoritative disposition

The third review reported **1×P1 + 1×P2**. The P1 was a test expectation contrary to the frozen rule: selection or dismissal must invalidate a human confirmation even if the selected server fact is unchanged. Production `dismissEditor` already enforced that rule, so the repair changes the test and evidence only: fresh same-owner selection and dismissal now require a new confirmation and emit **zero additional execute wires**. A separate exact-unchanged server-response test proves an unchanged, already-confirmed owner can execute without a selection; changed version/draft remains invalid.

The P2 was a product repair. Per Backend `TransactionDraft`, `title` is stripped and must remain nonempty; `note` is trimmed and whitespace-only becomes absent. `makeDraft` now canonicalizes before validation/wire construction, and both editor/server fingerprints use the canonical typed draft. The Gallery fixture mirrors the server trim/null behavior rather than echoing raw text. Transaction and cash-flow use the same canonical wire. Model coverage verifies padded title/note round-trip and whitespace-only note omission; the real iOS edit→confirm→manual execute path enters a padded title.

### Final current-source verification

- `cd App && xcodegen generate`, then `FiscalmacOS` and `V15GallerymacOS` `build-for-testing`, passed from final source. Declarations: **21** F3F model, **8** iOS UI and **3** macOS UI. This is compile evidence; no macOS UI runtime was run.
- The authorised targeted model runtime `xcodebuild -project App/Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests/F3FTests -resultBundlePath /private/tmp/fiscal-f3f-remediation/F3FTests-remediation10.xcresult` passed **21/0/0**. Its preceding `remediation9` run was **20/1** only because the new whitespace-note test expected JSON `null`; the real optional encoder omits a nil field. The corrected final test asserts that omission; no product behavior changed for that diagnostic correction.
- Fixed simulator `211DD03C-812D-4A42-97EF-F693D7DF924C` ran the new final bundle `/private/tmp/fiscal-f3f-remediation/F3FGalleryUITests-remediation9.xcresult`: **8 passed, 0 failed, 0 skipped** in **225.896 s**. It retains D3 false-only, missing/low confidence, future display-only, edit→confirm→manual execute, no-key GET-only recovery, retry/ignore/undo, 409, offline, empty/error and AX5/long coverage.
- Release builds passed for `FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS`, `V15GallerymacOS`, and `V15GallerySnapshotTool`. The Release SnapshotTool executable ran with its matching Release framework and generated **14** F3-F-only images in `/private/tmp/fiscal-f3f-remediation/snapshots-fourth`.
- Every generated F3-F image was opened individually and exact-promoted with `cmp` to `screenshots/f3/`: light/dark spine, review, cash-flow, AX5, offline/empty/service/field error, conflict, unknown/readback failure, page error and D3 contract error. All are legible with the intended spine/detail/inspector or error presentation; no forbidden chat, provider secret, strategy or automatic-execution UI, duplicate sheet accessibility element, or clipping was observed. Promoted count is **14**; SHA-256 values match the generated files.
- `git diff --check`, cached-diff check and scoped raw-transport/old-layer/root/forbidden-surface searches were run from final source. The temporary-directory deletion remains deliberately unperformed because the safety policy rejected it; no bypass was attempted.

The reviewer’s prior `19`-test macOS model run is recorded only as the source of the P1 test failure; it is not a macOS UI automation pass. The final targeted model runtime above is authorised evidence, but `F3F-MAC-UI-AUTOMATION` remains deferred with the other seven macOS gates as an F5/publish blocker. F3-G, F4/F5 and formal roots remain locked.

Status: **`1P1+1P2 reported; P1 was an authority-corrected test expectation; P2 canonicalization repaired; awaiting fourth Independent Review`.**

## F3-F frontend — fourth-review remediation Builder complete; awaiting fifth Independent Review

### Fourth-review P1 repair

The fourth review found one P1: a safe initial settings read followed by a false-only D3 contract violation could leave stale `settings=false` facts available to mutation guards. The repair is session-sticky and fail-closed.

- `V15AISettings` now emits the typed `ai_settings_contract_violation` only when either retired automatic-execution field is true. Ordinary malformed JSON remains an ordinary decode error. `V15AIProposalModel` records that violation as a sticky `settingsContractViolation`; a later false settings response does not silently unlock the same model session.
- Any settings failure clears stale settings, confirmations and editor confirmation state, invalidates mutation callbacks by generation, and disables create/confirm/execute/direct retry/ignore/undo/same-key replay. The D3 violation has one stable shared disabled reason. A normal settings transport/decode failure is also fail-closed, but has its distinct unavailable reason.
- Keyless unknown/conflict records retain their owner-scoped recovery facts and remain GET-readable; their mutation paths stay locked. Late safe settings responses and late direct callbacks cannot clear a newer violation. Read-only queue/detail/quality/readback remain available.
- iOS and macOS show the same D3 contract banner and disabled reason. The focused iOS run first exposed duplicate D3 presentation in one surface; changing the contract-failure mutation surface to idle left the single shared banner without weakening controls. The final focused and full runs below are the only acceptance evidence.

### Final current-source verification

- `cd App && xcodegen generate` passed. Final `FiscalmacOS build-for-testing` and `V15GallerymacOS build-for-testing` passed; source declares **24** F3F model, **9** iOS Gallery UI and **3** macOS Gallery UI tests. BFT is compile evidence only; no macOS UI runtime was run.
- Authorized targeted model runtime `xcodebuild -project App/Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests/F3FTests -resultBundlePath /private/tmp/fiscal-f3f-remediation/F3FTests-remediation14.xcresult` passed **24/0/0**. It covers initial and later true fields, safe→violation sticky semantics, ordinary settings failure, generation race, preserved unknown readback and zero mutation wires.
- Fixed simulator `211DD03C-812D-4A42-97EF-F693D7DF924C` ran `V15GalleryUITests/F3FGalleryUITests` into `/private/tmp/fiscal-f3f-remediation/F3FGalleryUITests-remediation12.xcresult`: **9 passed, 0 failed, 0 skipped** in **240.619 s**; its `Info.plist` SHA-256 is `07c6b5e657d169c759f84dfdf981d8d058e56be525ee64a9e6300462fab52f90`. This final bundle covers the safe→D3 banner/disabled controls in addition to D3 false-only, confidence/missing/future display-only, edit→confirm→manual execute, keyless GET-only recovery, retry/ignore/undo, conflict, offline, empty/error and AX5 long content. The prior focused duplicate-banner run is diagnostic only; corrected focused `remediation11` passed 1/0 before this full run.
- Release builds passed for `FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS`, `V15GallerymacOS`, and `V15GallerySnapshotTool`. The Release SnapshotTool executable ran with matching Release frameworks and generated exactly **14** F3-F-only PNGs. Each was opened individually, then exact-promoted with `cmp` to `screenshots/f3/`: `f3f-mac-{light-spine,dark-compact,review-sheet,ax5-long,offline,empty,service-error,field-error,conflict,response-unknown,response-unknown-read-failure,d3-contract-error,page-error,cash-flow-review}.png`. The sorted 14-file SHA-256 manifest hashes to `0160321df8e28a010f3be725c6851342db4290bddd0d8418170dabe527839337`.
- The visual matrix is legible: the macOS spine/detail/inspector, one D3 contract presentation per relevant column, disabled create, offline/empty/service/field errors, conflict and unknown recovery locks, local pagination error/retry, cash-flow review, review sheet and AX5 long content are visible. No chat, provider secret, strategy or automatic-execution affordance, duplicate sheet accessibility element, or clipping was found.
- `git diff --check`, cached-diff check and scoped raw-transport/old-layer/root/forbidden-surface scans passed from final source. Only F3-F names were promoted. The approved precise `/private/tmp/fiscal-f3f-*` deletion remains unperformed because the command safety policy rejected removal; no bypass was attempted.

The reviewer’s macOS model runtime is model evidence only; it does not close `F3F-MAC-UI-AUTOMATION`. That gate remains deferred with the other seven macOS gates as an F5/publish blocker. F3-G, F4/F5 and formal roots remain locked.

Status: **`1P1 reported; fail-closed sticky settings-contract remediation complete; awaiting fifth Independent Review`.**

## F3-F frontend — fifth-review remediation Builder complete; awaiting sixth Independent Review

### Fifth-review P2 repair

The fifth review found that a stable create response-unknown record could be hidden when owner restoration replaced the global mutation phase. Stable create recovery is now an independent owner/state, not a selected-direct-row side effect.

- `StableAttempt` now has its own loading/unknown recovery phase and an always-reachable create recovery panel. Selecting A/B, list replacement, detail reload and direct owner restoration cannot remove it while the immutable request/key still exists. The create panel is present on iOS and macOS with stable recovery, retry and abandon accessibility identifiers.
- `unknownCreateRetryReasons` is the single source for both UI and model guard: it reports offline, D3 sticky violation, settings loading/unavailable, old attempt generation, direct single-flight and local recovery phase. The retry cannot send a wire unless that same list is empty. Abandon has its own shared reason list, sends no wire and can clear the local attempt without clearing D3.
- A transient settings failure increments the mutation generation and disables replay while retaining the panel. Only a current fresh false-only settings load rebases the same immutable operation/request/key onto that generation; replay then uses the original idempotency key and canonical wire body. A D3 violation remains sticky across later safe responses and cannot authorize replay.
- Gallery adds the transient create-unknown settings route, real iOS A→B→A/recovery interaction, macOS BFT accessibility assertions, and a macOS stable-recovery snapshot. Fixture wire capture now uses sorted JSON keys so the immutable wire-body assertion is byte-stable rather than dependent on dictionary emission order.

### Final current-source verification

- `cd App && xcodegen generate` passed. `FiscalmacOS build-for-testing` and `V15GallerymacOS build-for-testing` passed from final source with **26** F3F model, **10** iOS Gallery UI and **4** macOS Gallery UI declarations. The macOS UI target is BFT-only; no macOS UI runtime was run.
- Authorized model runtime `xcodebuild -project App/Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests/F3FTests -resultBundlePath /private/tmp/fiscal-f3f-remediation/F3FTests-remediation18.xcresult` passed **26/0/0**. It covers same-key/body replay only after fresh safe settings, D3-sticky no replay, local abandon, owner selection, generation mismatch and duplicate retry single-flight. Earlier remediation15/16 were compile diagnostics and remediation17 was a non-final fixture JSON-key-order test diagnostic; none are acceptance evidence.
- Fixed simulator `211DD03C-812D-4A42-97EF-F693D7DF924C` ran the complete `V15GalleryUITests/F3FGalleryUITests` into `/private/tmp/fiscal-f3f-remediation/F3FGalleryUITests-remediation13.xcresult`: **10 passed, 0 failed, 0 skipped** in **280.497 s**; `Info.plist` SHA-256 is `77f8e997c3d70d229bd07cc0e726dc9f1be3e3dbc6ee6c14fc885ce977edc596`. It includes the focused stable create recovery path in addition to all previous D3, human-confirm, direct unknown, conflict, offline, empty/error and AX5 evidence.
- Current-source Release builds passed for `FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS`, `V15GallerymacOS` and `V15GallerySnapshotTool`. An earlier SnapshotTool launch overlapped the still-running Release chain and is expressly non-evidence; after the builds completed, the isolated Release executable was rerun into `snapshots-seventh`.
- The final SnapshotTool run generated exactly **15** F3-F-only PNGs. Every image was opened individually and exact-promoted with `cmp`; the sorted 15-file SHA-256 manifest is `60402b86986bf4f5d05d7745a3e835a73faa23423b8c694112438d96aa87cad3`. The previous 14-image matrix remains, with `f3f-mac-stable-create-recovery.png` added for the visible owner-independent recovery panel, settings-failure reason, disabled same-key retry and no hidden write lock. No clipping, duplicate sheet AX, chat, provider secret, strategy or automatic-execution affordance was observed.
- Final `git diff --check`, cached-diff check and scoped raw-transport/old-layer/root scans passed. The only auto-execute/search hits are the required D3 false-only decoder/invariant and negative copy; no process remained from the final builds or SnapshotTool.

`F3F-MAC-UI-AUTOMATION` remains deferred with the seven other macOS runtime gates; model/BFT/snapshot evidence does not close it. F3-G, F4/F5 and formal roots remain locked. The precise temporary-directory deletion remains unperformed after the prior safety-policy rejection; no bypass was attempted.

Status: **`1P2 reported; stable create unknown recovery remediation complete; awaiting sixth Independent Review`.**

## F3-F frontend — sixth Independent Review verified

The sixth Independent Review returned **0 findings**. The complete frontend chain is **R1 `2P1+3P2` → R2 `1P1+4P2 reported; fixture P2 authority-rejected; accepted 1P1+3P2 repaired` → R3 `1P1+1P2` → R4 `1P1` → R5 `1P2` → R6 `0 findings`**. The R2 fixture item is not a repaired finding: Root rejected it under frozen `PROJECT_PLAN.md §4`, which assigns fixture/Gallery injection to `V15/Shared` in the single FiscalKit target with separate Gallery hosts; no competing production fixture boundary was introduced.

Final frontend status: **Independent implementation review verified; `F3F-MAC-UI-AUTOMATION` deferred.** The accepted final Builder evidence remains the current-source F3F model runtime **26/0/0**, fixed-UDID iOS bundle **10/0/0**, **4** macOS Gallery UI declarations compiled by BFT only, four Release builds, Release SnapshotTool run and **15** individually inspected/promoted F3-F screenshots. The reviewer did not independently run iOS, Release or SnapshotTool, so R6 0 findings is review disposition, not a second runtime/build evidence pass.

F3-G Builder is now the only unlocked next block. F4/F5 and formal roots remain locked. `F2C-MAC-UI-AUTOMATION`, `F3A-MAC-UI-AUTOMATION`, `F3B1-MAC-UI-AUTOMATION`, `F3B2-MAC-UI-AUTOMATION`, `F3C-MAC-UI-AUTOMATION`, `F3D-MAC-UI-AUTOMATION`, `F3E-MAC-UI-AUTOMATION` and `F3F-MAC-UI-AUTOMATION` remain independent F5/publish blockers.

## F3-G — Historical builder evidence (superseded by remediation)

Implemented the typed P24–P28 statement-import boundary and native iOS step flow/macOS three-pane workbench. Registration sends metadata only; local PDF processing retains only a SHA, masked evidence and normalized boxes. The request-bound provider attempt retains immutable authorization/version/evidence digest/idempotency key for same-body recovery; deterministic provider failure is distinct from transport unknown. Confirmation uses the server-derived request exactly; unknown confirmation only reads the receipt using that same key.

This pre-remediation snapshot is retained only as history. Its model **6/0** and macOS UI **1/0** figures are not current acceptance evidence and are superseded by the remediation record below.

Builder fixes during this historical verification are retained for traceability only. Current F3-G acceptance remains the remediation section below; F4/F5 and formal roots remain locked.

## F3-G — Second-review remediation complete; awaiting third Independent Review

Accepted findings repaired against P24–P28 authority: production views no longer auto-run or expose synthetic imports (Gallery route only); registration always sends `display_name="statement.pdf"` and never retains a user filename; batch/workbench/preview unknown statuses share a display-only zero-write gate; provider/validation/resolution/preview/confirm are owned model tasks cancelled on scene/disappear/dismiss, retaining same-key provider recovery after a post-wire cancellation; and the workbench now uses integer cursor plus JSON filters, next-page local failure and retry without losing existing rows. Second-review repair synchronously claims the confirm owner before its first task yield: pre-wire sheet dismissal is an explicit zero-write cancel, while a possibly delivered confirm keeps its exact server request/idempotency key and can only read the receipt. The iOS/macOS preview sheets now render their own loading, deterministic failure/409 and retry states; iOS prevents dismissal while a confirm is in flight. The latest completed F3-G model runtime passed **12/0** (including confirm-dismiss pre/post-wire ownership and preview loading/failure/409 retry); fixed UDID iOS `F3GGalleryUITests` passed **5/0** with the real delayed confirm sheet and loading/error/retry interactions. `xcodegen generate`, macOS UI `build-for-testing`, and all four current-source Release targets (`FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS`, `V15GallerymacOS`) passed. SnapshotTool Release build/run completed with its Release framework path; all **14** current F3-G PNGs were individually inspected and exact-promoted, adding preview-retry to production intake without a synthetic entry, workbench/filter/pagination, masked evidence, future-status read-only, review/preview, unresolved/source-unavailable, partial/unknown receipts, request-bound recovery and AX5 offline. Headless AppKit snapshot hosting does not attach sheets, so preview/retry screenshots are the documented host frame; fixed-UDID interaction evidence is the acceptance proof for sheet content. macOS UI was previously retried three times; each failed before any business test with the same `Timed out while enabling automation mode` / `testmanagerd` root, so `F3G-MAC-UI-AUTOMATION` remains deferred as a ninth F5/publish blocker. A post-remediation macOS model-run attempt again produced no business result and was stopped under the same deferred gate; it is not claimed as a pass. F4/F5 and formal roots remain locked.

## F3-G — Third-review remediation complete; awaiting fourth Independent Review

The third review’s two P2 findings are repaired against the P24 workbench contract. `V15StatementWorkbenchFilter` now explicitly serializes `candidate_kind`, `check_status` and `evidence_state`; the F3-G transport fixture parses the `filters` JSON, rejects camelCase/unknown keys, applies the evidence filter, and model coverage asserts the actual query wire. Masked-page reads now have a separate owner/generation, loading flag and failure state: a failed page GET leaves the current workbench and global phase untouched, exposes stable iOS/macOS retry affordances, and succeeds on the fixture’s next request.

Current-source verification: `xcodegen generate`; FiscalKit F3-G runtime **14/0**; fixed-UDID (`211DD03C-812D-4A42-97EF-F693D7DF924C`) real `F3GGalleryUITests` **6/0** including page-error → local retry; macOS Gallery UI `build-for-testing`; and all four Release targets (`FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS`, `V15GallerymacOS`) passed. Release SnapshotTool built and ran with its Release framework path into `/private/tmp/fiscal-f3g-third-snapshots.3easWj`; exactly the **15** F3-G PNGs were individually opened and exact-promoted, adding the dark page-error/retry surface. The macOS UI runtime remains deferred under the existing three identical pre-business-test `testmanagerd` automation-enable failures; this Builder run did not retry that gate. F4/F5 and formal roots remain locked.

## F3-G — Fourth-review remediation complete; awaiting fifth Independent Review

The fourth review’s P1 separates mutation ownership from workbench/page reads: delayed draft-resolution PUT remains owned through page, filter, reload and next requests; read tasks use their own generations and never cancel or advance mutation state. A no-idempotency-key resolution cancelled after wire is retained as outcome-unknown and only fresh workbench readback may converge it—never a rebuilt second PUT. Model coverage is **16/0**; fixed-UDID real iOS coverage is **7/0** with the delayed resolution PUT plus masked-page and reload interaction. `xcodegen`, macOS Gallery BFT and all four Release targets passed (iOS uses generic Simulator with `CODE_SIGNING_ALLOWED=NO`); SnapshotTool Release ran into `/private/tmp/fiscal-f3g-fourth-snapshots`, and all **15** F3-G PNGs were individually inspected and exact-promoted. `F3G-MAC-UI-AUTOMATION` remains the existing ninth F5/publish blocker; F4/F5 and formal roots stay locked.

## F3-G — Fifth-review remediation complete; awaiting sixth Independent Review

The fifth review’s P1 is fail-closed: a claimed provider/validation/resolution/preview/confirm mutation owner cannot be cancelled or replaced by another write. The delayed post-wire resolution race proves one PUT and zero preview/confirm wire attempts; iOS exposes the same disabled reason. P2 binds confirmation preview to the batch/workbench version and selected row identities/versions. A replacing reload invalidates preview and receipt, so a stale confirm is zero-wire and requires a fresh server preview; only response-unknown retains its exact preview/key recovery state.

Gallery-only `statement-import-preview-delayed` now holds its first preview response for five seconds, long enough to verify the actual SwiftUI sheet loading AX transition without changing production routes. Current-source verification: `xcodegen generate`; FiscalKit F3-G runtime **18/0**; fixed-UDID (`211DD03C-812D-4A42-97EF-F693D7DF924C`) real `F3GGalleryUITests` **7/0**; macOS Gallery UI BFT; and all four Release targets (`FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS`, `V15GallerymacOS`) passed, with iOS Release using generic Simulator and `CODE_SIGNING_ALLOWED=NO`. SnapshotTool Release built and ran to `/private/tmp/fiscal-f3g-fifth-snapshots`; all **15** current F3-G PNGs were individually inspected and exact-promoted, including future read-only, pagination/filter, page error, preview retry, request-bound cancel, partial/unknown receipt and AX5 offline. `F3G-MAC-UI-AUTOMATION` remains the existing ninth F5/publish blocker under the three identical pre-business-test automation-enable timeouts; no macOS runtime pass is claimed. F4/F5 and formal roots remain locked.

Status: **fifth-review remediation Builder complete; awaiting sixth Independent Review.**

## F3-G — Sixth-review remediation complete; awaiting seventh Independent Review

The sixth review’s P1 makes resolution `response_unknown` recovery owner-scoped and read-only. The immutable owner now retains its batch/row identifiers, pre-write batch/row/draft versions and exact requested resolution facts. Its independent recovery task scans the authoritative unfiltered workbench from cursor zero through opaque next cursors without mutating the user’s current filter/page. It clears the unknown lock only after finding that owner row and confirming a fresh batch, an advanced draft and the exact intended resolution/match-or-ignore facts. Missing owners, a page failure, a stale draft or malformed pagination retain the visible GET-only lock and never issue a second PUT.

Fixture and model coverage exercise an owner excluded by the visible filter on page two, plus missing, local-page-failure and stale-result locks; the PUT count remains one. The real fixed-UDID iOS Gallery route covers filtered second-page recovery and its retry/readback state. Current-source verification passed: `xcodegen generate`; FiscalKit F3-G runtime **19/0**; fixed-UDID (`211DD03C-812D-4A42-97EF-F693D7DF924C`) real `F3GGalleryUITests` **8/0**; macOS Gallery UI BFT; and all four Release targets (`FiscaliOS`, `FiscalmacOS`, `V15GalleryiOS`, `V15GallerymacOS`), with generic-Simulator iOS Release and `CODE_SIGNING_ALLOWED=NO`. A transient simulator Busy preflight produced zero business tests, was recorded as a resolved tooling diagnostic, and is not acceptance evidence.

SnapshotTool Release built and ran from current source; all **16** F3-G PNGs, including the new resolution-readback state, were individually inspected and exact-promoted. `F3G-MAC-UI-AUTOMATION` remains the existing ninth F5/publish blocker under the three identical pre-business-test automation-enable timeouts; no macOS runtime pass is claimed. F4/F5 and formal roots remain locked.

Status: **sixth-review remediation Builder complete; awaiting seventh Independent Review.**

## F3-G — Seventh Independent Review verified

The seventh Independent Review returned **0 findings**. The complete F3-G chain is **`4×P1+1×P2 → 1×P1+1×P2 → 2×P2 → 1×P1+1×P3 → 1×P1+1×P2 → 1×P1 → 0 findings`**. The six remediation sections above record the corresponding repairs and current-source Builder evidence; the terminal review required no further implementation or test change.

Final F3-G status: **Independent implementation review verified; `F3G-MAC-UI-AUTOMATION` deferred.** The existing macOS gate remains the ninth F5/publish blocker after three same-root pre-business-test automation-enable timeouts; it is not replaced by model, BFT, iOS, Release or snapshot evidence. The only newly unlocked work is **F4 Planner/Build planning**; F5 and formal roots remain locked.

The reviewer did execute the full FiscalKit command, which initially reported **14 failed tests / 17 non-F3-G issues**. Root treated that as a separate cross-stage regression gate rather than an F3-G finding. The repaired batch preserved strict same-key/exact-body assertions while canonicalizing fixture wire recording in F3-B1/B2/C/D/E, cleared stale F3-B1 previews on response-unknown, restored field-specific F3-B2 disabled-reason precedence, aggregated F3-C receipt reasons, corrected F3-C fact-convergence filtering, and updated the reimbursement eligibility fixture to the current Backend contract. An independent review found one remaining P3 in replacement-receipt reason aggregation; that path now reports title/amount/date together and proves zero preview wire. The final independent review returned **0 findings**, and the current full command passed **369/369 tests in 37 suites** (`/private/tmp/fiscal-cross-stage-full-current-3.xcresult`). This closes the F4-before/global-regression gate without changing the nine deferred macOS UI runtime blockers.
