# Fiscal P9 QA Results

Date: 2026-07-16

Status: engineering complete; awaiting physical-iPhone and user visual acceptance. P10 has not started.

## Delivered

- Server-enforced `text`, `ocr`, and `shortcut_text` proposal sources with independent settings, source-bound idempotency, and correct ledger provenance.
- On-device Vision OCR for an explicitly selected image or a recent accessible screenshot; image bytes never leave the iPhone.
- Siri/App Intents for natural-language and screenshot capture, with persistent retry receipts and precise Chinese results for pending, executed, disabled, provider, permission, OCR, authentication, cancellation, and network states.
- Real Photos and notification authorization states, truthful manual Back Tap guidance, and no fabricated cross-device permission state on macOS.
- Local pending/executed notifications; only executed notifications expose authenticated Undo, bound to both proposal and transaction versions.
- Fiscal-native iOS capture/settings/proposal surfaces and a dense macOS source-settings and OCR proposal experience.

## Automated verification

- Ruff format/check: passed across 101 files.
- Pyright: 0 errors.
- Alembic upgrade/check/downgrade guard: passed against PostgreSQL.
- Full backend suite: 165 passed, 1 existing Starlette/httpx deprecation warning.
- Generic iOS 26 build: passed.
- macOS 26 Swift test/build: 57 tests across 8 suites passed.
- Authenticated real-API P9 iOS UI test on iPhone simulator / iOS 26.5: 1 passed, 0 failed.
- App Intent metadata extraction and both App Shortcut phrases: passed.
- Snapshot tool build and real-API macOS rendering: passed.

## Visual evidence

- `screenshots/ios-p9-settings-capture.png`
- `screenshots/ios-p9-ai-ocr-source.png`
- `screenshots/ios-p9-ocr-capture.png`
- `screenshots/macos-p9-settings-sources.png`
- `screenshots/macos-p9-ai-ocr.png`

The iOS and macOS evidence uses the production views connected to an authenticated local PostgreSQL-backed API. System authorization prompts and Siri/Back Tap behavior are intentionally not simulated as proof.

## Deferred physical-device acceptance

The user explicitly moved this gate after v1.0 production cutover. Failures found during real use will be handled in `v1.0.x`; the items remain visible and are not represented as tested.

- [ ] User verifies both Siri/App Intents on a physical iPhone.
- [ ] User binds and verifies Back Tap → Shortcut on a physical iPhone.
- [ ] User verifies Photos/latest-screenshot authorization and OCR on a physical iPhone.
- [ ] User verifies pending/executed notification delivery and notification Undo on a physical iPhone.
- [ ] User visually accepts P9 before P10 begins.
