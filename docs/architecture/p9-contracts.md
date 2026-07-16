# Fiscal P9 Contract

Date: 2026-07-16

`PROJECT_PLAN.md` remains authoritative. P9 completes the iOS capture path around the P8 server-owned proposal pipeline. Images stay on device: Vision produces bounded plain text, and only that text is sent to the server. P9 does not add attachment storage, cloud OCR, a generic notification-rule editor, or any P10/P11 settings.

## Input Sources

AI proposal source is one of:

- `text`: text entered inside Fiscal;
- `ocr`: text produced by on-device Vision from a user-selected image or the newest accessible item in the Photos Screenshots smart album;
- `shortcut_text`: direct text supplied to the Fiscal App Intent.

The existing authenticated `POST /api/v1/ai/proposals` remains the only create endpoint and still accepts `{source, text}` plus a required UUID `Idempotency-Key`. It never accepts image bytes, file URLs, temporary policy overrides, model selection, or client confidence. Fingerprints include the source domain so equal OCR and direct-text payloads remain explainable, while the idempotency key owns mechanical retry safety.

Executed OCR proposals create ordinary editable transactions with formal source `ocr`; `text` and `shortcut_text` proposals create `ai_text` transactions. The public transaction API still cannot choose a source. PostgreSQL transaction-shape and installment validators accept `ocr` only wherever they already accept trusted `ai_text`.

Server settings add `ocr_source_enabled` and `shortcut_text_source_enabled`, both default false. A new non-text request is rejected with stable `ai_source_disabled` before creating a proposal when its source is disabled. An exact replay is returned even if the source was disabled after the first accepted request. Settings use the existing complete replacement and optimistic version contract.

Automatic execution re-reads settings under the final proposal row lock. If a source is disabled while provider parsing is in flight, the normalized proposal remains pending and never auto-executes. Provider cancellation marks the proposal failed with a stable recovery state; clients retry the same proposal/idempotency receipt instead of creating another operation.

## On-device OCR

- Vision text recognition runs on device with accurate recognition, Chinese and English support where available, and no image upload.
- Input is bounded before decoding; OCR output is normalized, blank or over-2,000-character output is rejected without POST. Fiscal never silently truncates a transcript that might lose the amount or merchant.
- The image picker uses the system Photos picker and does not imply broad library permission.
- Back Tap's recommended path is a system Shortcut that takes a new screenshot and passes that image directly to Fiscal, requiring no Photos permission. “Newest screenshot” is a separate fallback using the Photos Screenshots smart album; it reports the real authorization state and refuses an obviously stale screenshot outside the fixed recency window.
- Fiscal never claims Back Tap is configured because iOS exposes no readable Back Tap configuration API.

## App Intents And Retry

- A direct-text App Intent submits `shortcut_text`.
- An image App Intent accepts explicit image input, runs Vision locally, then submits `ocr`.
- An optional newest-screenshot intent may run only when Photos authorization and an accessible screenshot exist; otherwise it returns a concise Chinese recovery instruction.
- Each invocation creates one UUID before its first network attempt and retains it for ambiguous transport retry. A changed input creates a different UUID. Cancellation never silently retries.
- Intent results distinguish executed, pending review, provider not configured, source disabled, missing device key, OCR-empty, authorization, and network failure. Siri dialog is the P9 spoken result; no separate background speech engine repeats it.

## Notifications And Undo

- Notification permission is device-local and displayed from `UNUserNotificationCenter` truth, never inferred from a toggle.
- Fiscal may notify only after a known proposal result. Pending notifications open AI Pending; automatically executed notifications include an Undo action.
- Notification payload contains only proposal UUID, the executed proposal version required for undo, and a navigation hint. It contains no device token, raw OCR text, account data, provider secret, or full transaction payload.
- The Undo action calls the formal proposal undo endpoint with both captured proposal version and transaction version. The server refuses the old notification if the transaction was edited, voided, or restored after notification creation; it never fetches the newest transaction version and force-voids changed user work.
- Exact replay of the same successful notification action is safe and creates no second ledger revision. A stale/conflicting or already restored ledger state produces stable `ai_undo_transaction_changed`; Fiscal never deletes a transaction locally to simulate undo.

## UI And Settings

- iOS Settings adds one polished “快捷录入” section for OCR, Shortcut text, Photos authorization, notification authorization, and Back Tap setup guidance.
- Server source switches are editable only after the corresponding P9 capability exists. Device authorization rows are read-only truth plus system actions such as Request Access or Open Settings.
- macOS may display the server source switches and explain that capture occurs on iPhone; it must not show fake Photos, Back Tap, or notification authorization for another device.
- iOS capture surfaces stay list-first and contain no charts, default `Form`, or legacy unstyled controls.

## Verification And Acceptance

- Backend tests cover source validation, disabled-source rejection, exact replay after disabling, source-separated fingerprints, optimistic settings, migration round trip, and downgrade guard.
- Apple tests cover OCR normalization/empty/long output, source encoding, retained idempotency key, intent result mapping, real authorization mapping, notification payload privacy, and repeated undo semantics.
- Simulator/build gates cover iOS 26 and macOS 26 under Swift 6; authenticated real-API evidence covers source settings and proposal origin.
- Final acceptance additionally requires the user to verify Siri/App Intent, Back Tap configuration, Photos/latest screenshot, notification delivery, and notification Undo on a physical iPhone. Simulator evidence cannot replace those gates.
