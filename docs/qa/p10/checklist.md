# Fiscal P10 QA Checklist

Date: 2026-07-16

## Contracts and backend

- [x] P9 is recorded as accepted and P10 boundaries are frozen.
- [x] CSV-only export, device-local preferences, semantic dark mode and memory-only cache decisions are recorded.
- [x] Uncategorized filter and atomic versioned batch classification pass PostgreSQL tests.
- [x] Advanced filters and filter-bound cursor behavior pass pagination/concurrency regressions.
- [x] Filtered CSV export escapes formulas and preserves exact CNY minor-unit values.
- [x] Full backend formatting, typing, migration and test gates pass.

## iOS

- [x] Exactly one custom bottom bar remains and root safe-area ownership survives keyboard and accessibility text.
- [x] New-entry defaults and stay-after-save affect the real manual entry flow.
- [x] High-use transaction editing no longer uses legacy default Form presentation.
- [x] Global ledger search, advanced filters and uncategorized inbox route to real records.
- [x] Batch classification is atomic and exposes conflict recovery.
- [x] Settings contains truthful sync, recording preference, classification/statistics, cache and export groups without logout/E2EE.
- [x] VoiceOver semantics, Dynamic Type, Reduce Motion handling, and light/dark appearance engineering gates pass.

## macOS

- [x] Dense table/Inspector supports advanced search, multi-selection and batch classification.
- [x] Keyboard shortcuts and adaptive window/Inspector layout are verified.
- [x] Settings shares real local preferences/cache/export behavior without pretending to expose P11 controls.
- [x] Empty, loading, refresh-error, disabled, conflict, long-content and pagination states have explicit product handling.
- [x] Light and dark screenshots preserve Fiscal hierarchy and contrast.

## Final

- [x] iOS 26 build/UI tests, macOS 26 tests/build and real-API snapshots pass.
- [ ] User visually accepts P10 before P11 begins.
