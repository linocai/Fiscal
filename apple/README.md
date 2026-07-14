# Fiscal Apple Client

Native SwiftUI clients for iOS 26 and macOS 26, sharing `FiscalKit` while keeping platform-specific shells.

## Generate and build

```sh
cd apple
xcodegen generate
xcodebuild -project Fiscal.xcodeproj -scheme FiscaliOS -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Fiscal.xcodeproj -scheme FiscalmacOS test
```

Debug builds use `http://127.0.0.1:8000` and allow local-network transport for development only. Override `FISCAL_API_BASE_URL` with an HTTPS endpoint for staging and release builds. The protected status endpoint is `/api/v1/system/status`; its bearer device token is stored as a this-device-only Keychain item.

For a one-time local or staging bootstrap, set `FISCAL_DEVICE_TOKEN` in the Xcode Run scheme environment. On launch the app moves it into Keychain; the value is not compiled into the bundle, written to `UserDefaults`, or logged. Remove the scheme value after the first successful launch.

P1 financial values come only from `PreviewSupport/OverviewFixtures.swift`. They are presentation fixtures and are never written to the backend or a local ledger.
