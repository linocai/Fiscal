# Fiscal P9 QA Checklist

Date: 2026-07-16

## Contract and backend

- [x] P8 is recorded as user accepted before P9 construction begins.
- [x] P9 source, OCR privacy, permission truth, retry, notification, and undo boundaries are frozen.
- [x] Migration expands only proposal input sources and adds versioned OCR/Shortcut settings with safe defaults.
- [x] Disabled sources create no proposal; exact idempotent replay remains recoverable after disabling.
- [x] OCR images never reach the backend and source-separated fingerprints remain non-unique.
- [x] Full backend static, migration, PostgreSQL, security, and regression gates pass.

## Apple

- [x] Vision OCR accepts explicit images and the newest accessible screenshot without uploading image bytes.
- [x] Direct-text and image App Intents use the correct source and retain one idempotency key across ambiguous retry.
- [x] Siri/App Intent results distinguish executed, pending, provider/source, token, permission, OCR, and network states in Chinese.
- [x] Notification authorization is real device state; executed notifications expose formal idempotent Undo.
- [x] iOS Settings exposes real OCR/Shortcut switches, Photos/notification states, and accurate Back Tap guidance.
- [x] macOS shows server source behavior without pretending to expose iPhone-only authorization state.
- [x] iOS/macOS P9 surfaces preserve the Fiscal design system and do not use default Form/legacy controls.
- [x] Swift tests, iOS 26 build/UI gate, macOS 26 test/build, and snapshot rendering pass.

## Visual and physical-device evidence

- [x] iOS P9 quick-capture settings.
- [x] iOS OCR capture state.
- [x] iOS AI proposal clearly shows OCR origin.
- [x] macOS P9 source settings and OCR proposal inspector.
- [ ] User verifies Siri/App Intent on a physical iPhone.
- [ ] User verifies Back Tap → Shortcut on a physical iPhone.
- [ ] User verifies Photos/latest screenshot authorization and OCR on a physical iPhone.
- [ ] User verifies notification delivery and Undo on a physical iPhone.
- [ ] User accepts P9 before P10 begins.
