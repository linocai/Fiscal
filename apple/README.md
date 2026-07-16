# Fiscal Apple Client

Native SwiftUI clients for iOS 26 and macOS 26, sharing `FiscalKit` while keeping platform-specific shells.

## Generate and build

```sh
cd apple
xcodegen generate
xcodebuild -project Fiscal.xcodeproj -scheme FiscaliOS -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS test
```

Debug builds use `http://127.0.0.1:8000` and allow local-network transport for development only. Release builds use `https://fiscal.linotsai.top`. The protected status endpoints are `/api/v1/system/status`, `/api/v1/system/security-status` and `/api/v1/system/operations-status`; bearer device keys are stored as this-device-only Keychain items.

For a one-time local or staging bootstrap, set `FISCAL_DEVICE_TOKEN` in the Xcode Run scheme environment. On launch the app moves it into Keychain; the value is not compiled into the bundle, written to `UserDefaults`, or logged. Remove the scheme value after the first successful launch.

## P11 VPS and device security

Settings shows the current device role/fingerprint, server-enforced rate limits, database/schema alignment and the latest server-recorded backup, restore drill and disk facts. Operators can issue a one-time pending key. A new iPhone or Mac pastes that key into the unauthorized Settings state; activation completes before it becomes the active Keychain value. Rotation uses a separate pending Keychain slot and preserves the old key across transport ambiguity. “Remove this device key” is a revocation operation, not logout, and the UI accurately states that Fiscal is not end-to-end encrypted.

P1 financial values come only from `PreviewSupport/OverviewFixtures.swift`. They are presentation fixtures and are never written to the backend or a local ledger.

## P2 master data

Accounts and categories use the protected `/api/v1/accounts` and `/api/v1/categories` resources directly. Their screens have explicit loading, empty, unauthorized, offline, validation, optimistic-conflict, and unexpected-error states; they never substitute preview fixtures. Updates send `expected_version`, safe deletion sends it as a query parameter, and ordering/merge/split use the frozen P2 contract in `docs/architecture/p2-contracts.md`.

The iOS shell intentionally does not use `TabView`: one explicit selection drives one custom glass bottom bar. Accounts and Categories are available from More. macOS exposes both as first-class sidebar destinations.

## P3–P4 ledger and credit

The shared transaction editor uses the authenticated unified ledger for income, expense, transfer, credit purchase, and repayment. Credit purchases are assigned to statement cycles by the server; repayments always name one payment account, one credit account, and one target cycle.

iOS exposes Credit Cycles from More while preserving the single custom bottom bar. macOS keeps credit management inside Accounts with reference-style cards and a 256-point Inspector. Both platforms read debt, available/over-limit credit, opening-configuration state, cycle totals, overdue state, and archived history from the real API without Preview fallback.

## P8 AI proposals and settings

Both apps share one server-backed `AIProposalModel` and authoritative `pending_count`. iOS opens the compact pending queue from the production overview badge or More, and exposes a real Settings destination containing only P8 automatic-execution behavior. macOS uses a dense queue with an inspector and the same settings model. AI text transactions use source `ai_text` and remain editable, voidable, and restorable like manual ledger rows. OCR, Shortcuts, end-to-end-encryption, and logout controls are intentionally absent from P8.

## Integration UI tests

Start a seeded local API whose device token is `integration-device-token`, then run the `FiscaliOS` scheme against a booted simulator. The UI target verifies that no native tab bar exists, navigates through More, and reads account/category hierarchy from the authenticated API. The scheme token is local-test-only and must never be reused for staging or production.
