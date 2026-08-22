# F0 — V15 foundation QA

## F0-A Builder

- Scope: V15 Foundation contracts, state ownership, fixture transport and tests only. No V15 View, design-system token, application shell, feature directory, or root was created or changed.
- Changed paths: `App/Sources/FiscalKit/V15/Foundation/{CNYAmountParser,V15Contracts,V15Services,V15State}.swift`, `App/Sources/FiscalKit/V15/Shared/Fixtures/{V15FixtureTransport,V15FixtureLibrary}.swift`, `App/Tests/FiscalKitTests/V15/V15FoundationTests.swift`; parser definition was mechanically removed from `DesignSystem/MoneyFormat.swift` while preserving `CNYAmountParser`'s public module symbol.
- Contract coverage: P30/P32 facts + four drilldown scopes and revision cursor; P33 future events, full credit schedule effect, reimbursement candidates + all four typed replace/cancel/create-receipt/replace-receipt previews and commits, completed installment list, request-bound statement provider; P31 merchant/history/category transforms; P34 complete report/read metadata, period drilldown and server artifacts. Stable field issues, capability reasons, 409 reload locator, receipt/revision fields, preview and idempotency ownership are represented at the boundary.
- Fixture states: success/empty facts, empty timeline/candidates/merchant/installment pages, report, field-invalid, disabled reason, conflict, offline read-only, preview and receipt. `V15FixtureTransport` is fully offline and rejects every write.
- Automated tests: strict required-field decode with additive-key tolerance; `Int64` amount boundary; UTC-to-Shanghai month boundary; unknown action safe disable; 409 mapping; generation/cancellation ownership; preview invalidation on input/dismiss/cancel/expiry; response-unknown idempotency reuse; offline snapshot read + write refusal; revision/cursor scope.
- Clean-room: `rg` over `App/Sources/FiscalKit/V15` found no imports/references to old screens/models/roots/design-system/DTO/repository and no SwiftUI/navigation/view source. The V15 directory only imports Foundation.

## Commands and result

- `cd App && xcodegen generate` — passed; project source declaration regenerated.
- `xcodebuild -project App/Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests` — passed, 150 tests / 22 suites.
- `xcodebuild -project App/Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` — passed.
- `xcodebuild -project App/Fiscal.xcodeproj -scheme FiscaliOS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` — passed.
- `git diff --check` for F0-A paths — passed.

## Risk / handoff

- V15 has no visual surface by design; F0-B must consume only the Foundation contracts and fixture states, not legacy UI types.
- The production composition root delegates credential handling, encrypted read-only snapshot fallback and revision tracking to existing neutral infrastructure via `APITransport`; V15 itself does not queue writes or access legacy repositories.
- Status: **F0-A Independent Review Verified — five review rounds closed, final review 0 findings. F0-B Builder is unlocked; F0-C and F1–F5 remain locked.**

## P30–P34 response-contract coverage check (round 2)

| Backend response contract | V15 typed boundary | Required-field evidence |
| --- | --- | --- |
| P30/P32 `ReportFacts`, `FactsDrillDownPage`, `KnownFutureEventPage` | `V15Facts`, `V15FactsMeta`, `V15DrillDownScope`, `V15FactDrillDown`, `V15FutureEvents` | schema/revision/window; all future certainty totals and `known_future_events`; cursor/scope revision test |
| P30-B available action / 409 / checkpoint / migration | `V15AvailableAction`, `V15Capability`, `V15Failure`, `V15Conflict`, `V15DeepLinkReadService` | unknown safe-disable, field issue + reload path; exact `/migrations/runs/{id}` assertion |
| P31 merchant/history/category transform | `V15Merchant`, paged history seam, typed transform preview + commit seams | page/cursor and preview-token seams retained; no legacy DTO/repository dependency |
| P33 credit schedule | complete `V15CreditSchedulePreview` and typed affected-cycle effect rows | old/new schedule, cycle dates/version/checkpoints, counts, expiry/version/revision; full JSON + missing required test |
| P30-C/P33 reimbursement | `V15ReimbursementCandidate`, `V15ReceiptAccountOptions`, typed claim/cancel/receipt preview effects | account/category/kind/eligibility fields; candidate query/date/cursor encoding; all four preview endpoints decoded from full response samples and required-missing failure |
| P33 installments / statement provider | `V15InstallmentPlan`, `V15StatementProviderAttempt` | explicit completed status stays display-only; `execution_scope == request_bound` seam |
| P34 `PeriodReport` / export | complete `V15ReportMeta`, `V15PeriodReport` summary + account/category/merchant/source/completeness lenses, `V15ReportArtifact` | `generated_at`, full summary/lenses/revision identity; full JSON + required-missing test; artifacts remain server output |

## Independent-review repair — round 3

- P31 category merge/split responses are now dedicated effect DTOs: dependency totals, child mapping requirements, target/root, required transaction IDs, child names, atomic marker and preview token. Preview request types bind the backend’s expected versions; P31 response schemas do not expose an expiry or returned version field, so none was invented.
- `V15Conflict` now preserves P22/P30/P32/P34 top-level reload/revision information. In `common.py`, `current_version`, `expected_version`, and `safe_to_reload` are top-level fields; only the opaque reload locator is nested under `resource`, and no resource identity is logged or derived.
- Report routes are separate `monthly(V15ReportMonth)` / `yearly(V15ReportYear)` calls. The period drill-down receives a `V15ReportPeriod` sum type; export uses a typed format and associates the returned bytes with an already-read report revision for downstream comparison—it does not send or claim a client `expected_revision` parameter.
- Future-event domain locators (`claim_id`, `party_id`, `cycle_id`) and the actual credit cycle-mode enum values are retained and covered by fixture tests.

## Independent-review repair — round 4

- P31 merge/split uses only typed public request and response seams: preview and commit requests cover preview token, expected versions, child mappings/assignments and the complete category-transform receipt. Exact snake-case request encoding, required-field failures and additive-response tolerance are covered by the Foundation suite.
- Audit removed every public formal mutation method that previously accepted a bare `JSONValue` or arbitrary path: credit schedule, all reimbursement preview/commit variants, installment settle/cancel/reverse operations, and statement-provider attempts now receive a schema-shaped `Encodable` request. `JSONValue` remains solely the private transport payload representation and read-only opaque legacy-neutral record seam; no V15 formal write can receive it from a caller.
- Typed requests retain backend-required versions, preview tokens, monetary minor units, UTC timestamps, reimbursement allocation/party inputs, installment action fields, and provider authorization evidence. The only intentionally opaque responses are P5 installment operation receipts until F3 owns its feature-specific response DTOs; their route and request are no longer caller-selectable or untyped.

## Independent-review repair — round 5

- `V15BodyEncoder` now uses the same `.iso8601` date encoding strategy as `APITransport`; all typed write `Date` fields (`received_at`, `occurred_at`) are asserted to be timezone-aware strings rather than reference-date numbers. Fixture decoding accepts backend `Z`, `+00:00`, and fractional-second timestamps, with all three forms covered by tests.
- Reimbursement claim replacement and receipt replacement are phase-specific types: preview inputs cannot encode `preview_token`; every corresponding commit input requires one. Create-receipt and cancellation follow the same backend preview/commit token rule, and exact snake-case tests cover required version/token fields.
- `V15Request`, `V15Transporting`, API/fixture adapters and fixture transport injection are internal. The only public construction path is `V15Services`' production composition root; tests retain replacement injection through `@testable`. A source-scan test fails if future `V15/Features` reaches any raw transport/JSON type.

## Independent-review closure

- Five review rounds completed: round 1 repaired contract fidelity across P30–P34; round 2 completed P31 transforms, conflict facts, report routes and future locators; round 3 removed public raw mutation bodies; round 4 aligned date/token/raw-transport seams; round 5 found **0 findings**.
- Final verification evidence remains 150 FiscalKit tests in 22 suites, regenerated Xcode project, macOS and generic iOS Simulator builds, clean-room/raw-surface scans, and `git diff --check`.
- Residual risk: V15 intentionally has no visual surface until later blocks; P5 installment operation responses remain opaque records until F3 owns feature-specific response DTOs. Their routes and write inputs are already typed and non-caller-selectable.

## F0-B Builder

- Scope: only `V15/DesignSystem/**`, `V15/Shared/State/**`, `V15/Shared/Accessibility/**` and the V15 design-system test suite. No gallery, shell, feature screen, root, legacy View, old design system, HTML/WebView, or raw transport seam changed.
- Design sources consumed: `00-HANDOFF.md`, `06-direction-decision-and-inventory.md`, `07-highfi-index.md`, `Fiscal Design System.dc.html`, `Fiscal 深色模式.dc.html`, and `Fiscal 大字号与文案规范.dc.html`.

### Source-to-implementation mapping

| Approved visual rule | V15 implementation |
| --- | --- |
| paper/card/ink, teal/yellow/gold and deep rebalancing | `V15Palette`: exact light and dark pairs, including `#0F1615/#1A2423/#E8EFED/#4FB3AC/#B99333/#D9A93C/#241F12/#122A29`; values stay independently testable as `V15ColorToken`. |
| PingFang/system roles, tabular CNY and no floating point | `V15Typography`, `V15MoneyPresentation`, `V15MoneyText`; amounts receive `Int64` minor units only, group deterministically, use monospaced digits and a fixed one-line layout. |
| Native controls, not a web-card recreation | `V15ActionButton` (primary/secondary/destructive/quiet), `V15Field`, `V15PickerRow`, `V15SearchField`, `V15LedgerRow`, `V15Section`, and `V15InspectorAction`. iOS targets 44pt; compact mac rows retain 28px visible rhythm plus 4px vertical hit extension and keyboard focus ring. |
| Ten-state syntax and honest copy | standalone loading, empty, service-retry, field issue, disabled-reasons, offline snapshot, conflict reload, preview, archive-readonly, receipt and partial-progress Views. Each uses visible text plus a shape/state marker; preview is dashed yellow, archive is 45° hatched, and conflict says no modification was made. |
| AX5 / VoiceOver / reduce-motion | documented yielding order, explicit labels/hints, custom-action helper, safe unknown-reason/status fallbacks, VoiceOver amount labels, and no press-motion when Reduce Motion is enabled. |

### Automated verification

- `cd App && xcodegen generate` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests/V15DesignSystemTests -quiet` — passed (5 design-system tests).
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscaliOS -destination 'generic/platform=iOS Simulator' build -quiet` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' build -quiet` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests -quiet` — passed.
- `git diff --check` and clean-room `rg` over F0-B-owned paths — passed; no legacy visual type, root, WebView, HTML bridge, or raw V15 transport reference is present.

### Risk / handoff

- No Gallery or screenshot is intentionally produced here: F0-C owns all fixture rendering, visual matrix and screenshot evidence after independent review unlocks it.
- F0-B exposes only primitive visual/state surfaces. Feature builders remain responsible for binding their server facts, 409 reload operations and action capabilities to these components; they must not recreate their own palette or disabled-state syntax.
- Status: **F0-B Builder Verified — awaiting Independent Review. F0-C and F1–F5 remain locked.**

## F0-B independent-review repair — round 1

- Initial review found 3×P2 and 1×P3. All four were repaired within the F0-B ownership boundary; no shell, feature, root, old UI or gallery file changed.
- Disabled action rendering now reads SwiftUI `isEnabled` inside `V15ButtonStyle`. `V15ButtonVisualSpec` gives enabled/disabled states an independently tested semantic mapping: disabled foreground is approved ink 35%, background ink 8%, and border hairline; the visible per-item reason list remains outside the disabled control.
- `V15OfflineReadOnlyBanner` now has exactly one input, `snapshotAt`, and says only `离线 · 只读` plus snapshot time/write prohibition. It contains no pending-count, queue, or synchronization language. A full V15 source/test scan returns no offline-queue/pending-sync semantics.
- State accessibility is now policy-driven: static states combine text, while empty/error/conflict/receipt states with actions use `.contain` so their button remains independently navigable and retains its label/hint. Partial progress is static again instead of wrapping a receipt container with a misleading interaction policy.
- `V15InspectorAction` now has an explicit button HStack/VStack rather than a trailing overlay: title and long detail both wrap, detail has layout priority, the chevron is a separate decorative element, and an extended reason stays beneath the control without overlap.

### Repair verification

- `cd App && xcodegen generate` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests/V15DesignSystemTests -quiet` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscaliOS -destination 'generic/platform=iOS Simulator' build -quiet` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' build -quiet` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests -quiet` — passed.
- `git diff --check` and clean-room F0-B `rg` (legacy/web/raw transport plus offline queue/pending-sync terms) — passed.

- Status: **F0-B repair verified — awaiting Independent Review round 2. F0-C and F1–F5 remain locked.**

## F0-B independent-review closure

- Review round 1 found 3×P2 and 1×P3; all were repaired and fully reverified in the preceding repair entry.
- Review round 2 found **0 findings**. F0-B is **Independent Review Verified**.
- Residual visual/assistive risk: component-level builds and semantic tests cannot replace F0-C's physical device/simulator gallery inspection. F0-C must still validate the visual matrix in shallow/deep color, AX3/AX5, long Chinese and long-money layouts, plus VoiceOver focus order and custom-action discoverability on both platforms.
- Handoff: F0-C may now consume the F0-B primitives; F1–F5 remain locked until F0-C is independently reviewed with zero findings.

## F0-C Builder

- Scope: isolated V15 Gallery and parallel shell only: `V15/AppShell/V15GalleryShell.swift`, `V15/Shared/Gallery/V15Gallery.swift`, the independent iOS/macOS Gallery apps, Gallery tests and snapshot tool. Neither `IOSRootView.swift` nor `MacRootView.swift` changed or references V15; the production roots remain unreachable by the Gallery launch arguments.
- Fixture route: `--v15-gallery-fixture <id>` deterministically selects one offline fixture without DTO, endpoint, or legacy View access. The supported IDs are `loading`, `empty`, `service-error`, `field-invalid`, `disabled-reasons`, `offline-readonly`, `conflict`, `preview`, `archive-readonly`, `success-receipt`, and `partial-progress`. The plan prose says “10 states” but enumerates eleven semantic states; all eleven are rendered and evidenced here.
- Platform layouts intentionally differ while retaining the same fixture semantics: iPhone uses a portrait decision card with 44pt actions and an entry-point error sheet; macOS uses state index + ledger spine + inspector, with compact/comfortable density and focusable keyboard-equivalent controls. No iPad split view is claimed.
- Accessibility and motion: fixture state has a stable accessibility identifier/summary; action and disabled-reason labels are exposed individually; UI tests assert preview state/action and sheet-local service + field error. AX5 yields header/action order into a scrollable card while the `Int64` extreme-money presentation stays single-line. Gallery supports deterministic `--v15-gallery-reduce-motion` and `--v15-gallery-reduce-transparency` evidence variants and respects system motion/transparency settings in normal use.

### Screenshot matrix and visual review

All files are synthetic offline fixture data; no real account, card, receipt, or endpoint data appears in evidence.

| Surface | Evidence |
| --- | --- |
| iPhone portrait / default light | `screenshots/ios-{loading,empty,service-error,field-invalid,disabled-reasons,offline-readonly,conflict,preview,archive-readonly,success-receipt,partial-progress}-light-default.png`, plus `ios-states-light-contact-sheet.png` |
| iPhone variants | `ios-preview-dark-default.png`, `ios-preview-light-ax3.png`, `ios-preview-light-ax5.png`, `ios-preview-light-reduce-motion-transparency.png`, and sheet-local error `ios-field-invalid-sheet-error.png` |
| macOS comfortable light / compact dark | `screenshots/macos-*-light.png`, `screenshots/macos-*-dark-compact.png`, `macos-preview-dark-comfortable.png`, plus `macos-states-light-contact-sheet.png` and `macos-states-dark-compact-contact-sheet.png` |

- Visual review against `Fiscal 前端设计启动/` high-fidelity sources: paper/ink, teal selection, yellow dashed preview, gold receipt and dark-surface rebalancing follow the approved tokens. The deliberately visible deviation is that Gallery is a fixture harness, not feature navigation or live data; it demonstrates the state syntax rather than recreating the handoff prototype.
- Manual inspection of default, AX3 and AX5 iPhone evidence found no long-Chinese collision or truncation. The extreme `Int64` CNY amount does not wrap; at AX5 adjacent hierarchy yields/scrolls instead. macOS contact sheets show every state in both reviewed densities/colors, with state markers and text rather than color-only meaning.

### Verification

- `cd App && xcodegen generate` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' test -only-testing:FiscalKitTests -quiet` — passed, 158 tests / 0 failures.
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscaliOS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO -quiet` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO -quiet` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme V15GalleryiOS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO -quiet` and `... -scheme V15GallerymacOS ... build` — passed.
- `xcodebuild -project Fiscal.xcodeproj -scheme V15GalleryiOS -destination 'platform=iOS Simulator,id=211DD03C-812D-4A42-97EF-F693D7DF924C' test CODE_SIGNING_ALLOWED=NO -quiet` — passed, 2 UI tests / 0 failures (fixture route, semantic action, sheet-local retry/field-error/disabled-save assertions).
- `V15GallerySnapshotTool` built and rendered the macOS matrix to PNG. It is an intentionally standalone developer harness and needs `DYLD_FRAMEWORK_PATH=<DerivedData>/Build/Products/Debug` when launched directly, because it does not embed the development framework.
- `git diff --check` and F0-C-owned clean-room scans (legacy roots/views, `FiscalDesign`, `WebView`, `HTML`) — passed; root scans find no V15 reference.

### Risk / handoff

- The harness has no network or production route by design; F1–F5 must reuse these primitives with their typed V15 contracts rather than treating Gallery copy as business content.
- XCUITest validates the exposed semantic tree and actions. A physical-device VoiceOver rotor session remains a release-level validation item, not a reason to connect this isolated fixture app to production roots.
- Status: **F0-C Builder Verified — awaiting Independent Review. F1–F5 remain locked.**

## F0-C independent-review repair — round 1

- Review findings repaired within F0-C ownership only: 1×P2 iPhone header compression and 1×P3 semantic/motion evidence gap. No Feature, legacy View, formal root, network route, DTO, or V15 contract changed.
- **P2 header:** `V15GalleryDecisionHeader` uses a 520pt `ViewThatFits` wide threshold and an explicit stacked fallback for iPhone/AX. The title remains a naturally readable text block; the tabular extreme `Int64` CNY amount is fixed-size/nonwrapping on its own right-aligned row whenever the horizontal option does not fit. This is applied before every state surface, so all 11 fixture states receive the same policy.
- **P3 semantics/motion:** card sections now expose ordered identifiers and priorities for title, amount, state, action and pagination. The Gallery UI suite checks their actual rendered order by accessibility elements/frames, all 11 fixture headers, retry/reload reachability, disabled-reason text and disabled action, plus the deterministic Reduce Motion/Transparency rendering-mode value. The flags produce a visible, inspectable mode label and a stable no-animation transaction/opaque card surface; tests do not infer this from timing.

### Replacement iPhone matrix

All 11 states were recaptured on `ICTW-v170-iPhone17Pro` in each of default light, AX3 light, AX5 light and default dark (44 state screenshots). Contact sheets were regenerated for all four reviewed variants:

| Variant | Files |
| --- | --- |
| default light | `ios-*-light-default.png`, `ios-states-light-contact-sheet.png` |
| AX3 light | `ios-*-light-ax3.png`, `ios-states-light-ax3-contact-sheet.png` |
| AX5 light | `ios-*-light-ax5.png`, `ios-states-light-ax5-contact-sheet.png` |
| default dark | `ios-*-dark-default.png`, `ios-states-dark-contact-sheet.png` |

- Manual visual result: the repaired default/AX3/AX5/dark matrix keeps every header title in a readable horizontal/wrapped text block and preserves the full nonwrapping money string. AX5 moves the header amount to its own row; large state/action copy may extend below the initial viewport and uses the card's scroll route rather than clipping or overlap. This replaces the earlier broad “no collision” claim with state-by-state screenshot evidence.
- The refreshed Sheet and Reduce Motion/Transparency screenshots retain synthetic data only: `ios-field-invalid-sheet-error.png` and `ios-preview-light-reduce-motion-transparency.png`.

### Accessibility inspection and limitation

- XCUITest result: 5 / 5 passed. It inspects the live iOS accessibility tree for the ordered title → amount → state → action → pagination elements; verifies retry and conflict-reload buttons can be reached and activated; reads the disabled report reason; and asserts `motion=reduced;transparency=reduced` for the two launch flags.
- This is an accessibility-tree/interaction assertion, **not** an automated VoiceOver rotor simulation. Manual VoiceOver review procedure for a device or Simulator with VoiceOver enabled: launch `preview`, swipe through title, amount, preview content, confirm action, disabled pagination/reason; repeat `service-error`, `conflict` and `disabled-reasons`, confirming retry/reload and both visible reason lines are announced in source order. Result in this CI/simulator capture environment: tree order and actions passed; a spoken rotor/audio session is not automatable here and remains a release-device follow-up, not a claim of automated VoiceOver focus coverage.

### Commands and result

- `xcrun simctl ui <device> appearance {light,dark}` and `xcrun simctl ui <device> content_size {large,accessibility-large,accessibility-extra-extra-extra-large}` selected default/AX3/AX5 conditions.
- For each fixture: `xcrun simctl launch --terminate-running-process <device> com.linotsai.fiscal.v15-gallery.ios --v15-gallery-fixture <id>` then `xcrun simctl io <device> screenshot <QA path>` — completed 44 matrix captures. The Reduce Motion/Transparency capture additionally supplied `--v15-gallery-reduce-motion --v15-gallery-reduce-transparency`.
- `ffmpeg -pattern_type glob -i '.../ios-*-<variant>.png' -vf 'scale=244:528:force_original_aspect_ratio=decrease,pad=244:528:(ow-iw)/2:(oh-ih)/2,tile=4x3' ...` — regenerated four contact sheets.
- `cd App && xcodegen generate`; full `FiscalKitTests` (158 / 0); formal `FiscaliOS` + `FiscalmacOS` builds; Gallery iOS/macOS + snapshot-tool builds; `V15GalleryiOS` UI tests (5 / 0); and the macOS snapshot harness — passed. Existing unrelated legacy test warnings remain warnings only.
- `git diff --check`, F0-C clean-room scan, and root V15 scan — passed.

- Status: **F0-C review-round-1 repair verified — awaiting Independent Review round 2. F1–F5 remain locked.**

## F0-C independent-review closure

- Review round 2 found **0 findings**. F0-C is **Independent Review Verified** and the complete F0 foundation is verified.
- Final evidence: 75 synthetic Gallery PNGs (including 44 iPhone state captures and four iPhone contact sheets), Gallery UI tests 5 / 0, FiscalKit tests 158 / 0, regenerated Xcode project, formal iOS/macOS builds, independent Gallery iOS/macOS builds, macOS snapshot harness, clean-room/root scans and `git diff --check` all passed.
- Residual risk: the Simulator/XCUITest accessibility-tree order and action assertions pass, but they do not simulate a spoken VoiceOver rotor session. The documented physical-device VoiceOver sweep remains a release-device check; it does not reopen the isolated Gallery/root boundary.
- Handoff: **F1 Planner** may now split facts entry, ledger and master-data work into mutually exclusive construction blocks. F2–F5 remain locked until F1 receives its own final independent-review clearance.
