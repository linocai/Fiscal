# P10 iOS UI integration tests

The P10 UI cases in `apple/Tests/FiscalUITests/FiscalUITests.swift` run against the seeded,
authenticated API. They intentionally avoid durable mutations:

- The modern transaction editor is opened and cancelled without saving.
- Recording preferences and cache state are inspected without changing or clearing them.
- CSV export calls the real filtered server endpoint, opens the system file exporter, and then
  cancels without writing a file.
- The uncategorized inbox enters selection and opens atomic batch classification, but no category
  is selected and the disabled confirmation button is never submitted.

## Covered boundaries

- Exactly one Fiscal custom bottom bar, no native tab bar, and ledger search above its safe area.
- Current global search label: `搜索标题、备注、账户或分类`.
- Card-based transaction editor fields and fixed save action.
- Settings recording preferences, truthful memory-cache status, and real CSV handoff.
- Overview-to-uncategorized routing, advanced filter sheet, selection bar, and batch sheet.
- Dark appearance plus accessibility-extra-large text, including adaptive list rows and the single
  safe-area bottom bar.

## Run

Start the seeded local API and export its local-only device token, then run:

```sh
cd apple
FISCAL_UI_TEST_DEVICE_TOKEN=integration-device-token \
  xcodebuild -project Fiscal.xcodeproj -scheme FiscaliOS \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' test
```

Use `xcrun simctl list devices available` to select the simulator UDID.

The seed must contain at least one editable uncategorized income, expense, or credit purchase. The
test must fail rather than create fallback preview data when that contract is missing.
