# Build 41 quick-fix verification

2026-09-06, Asia/Shanghai. App source hashes are in source-sha256.json. Screenshots contain isolated synthetic data only.

- Narrow/light 1000 pt and dark 1280 pt existing root UI case passed in mac-ui-final.xcresult, including record open/return and destination navigation.
- New 2000 pt wide-window case passed in mac-wide-passed.xcresult: light/dark, viewport fills detail width, left/right gutter pixels match the reading canvas within 1 RGB unit; analysis/settings controls >=38 pt and destination clicks pass.
- Actual native right-edge drag from narrower to wider window was visually checked: continuous canvas, readable header actions, no white strips. Manual evidence is separate from automated test counts.
- Targeted V15DesignSystemTests and P10MacWorkbenchTests: 12 tests in 2 suites passed. Two distinct Mac UI cases obtained passing results. The previous build's full 408-test run is historical; it was not rerun for this visual-only hotfix.
- Initial wide test exposed an ancestor accessibility identifier overriding child actions; fixed with a containment boundary. A subsequent dark pixel test used absolute token RGB values and failed due to captured color-space shifts; the final test compares gutters to the center within the same screenshot, with separate light/dark bounds. All final assertions passed.
- Three Release App builds and signed archive validation passed; exact records are in release/.

Raw local results/logs: build/release-v2.2.0-41. Retained screenshots and provenance: screenshots/. No private recording or desktop captures are committed.
