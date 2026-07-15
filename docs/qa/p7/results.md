# Fiscal P7 Results

Date: 2026-07-15

P7 engineering is complete and is waiting for user visual/product acceptance.

The backend now exposes one authoritative reporting service through overview, spending, actual-plus-forecast cash flow, debt, and stable-cursor drill-down endpoints. Spending re-attributes installment refunds and reimbursement effects to the original expense; actual cash flow counts cash/debit postings while separating internal transfers; forecasts include only exact credit-cycle dues and submitted reimbursements with explicit expected dates; current debt never adds future installment gross a second time. No business migration was added.

The production iOS and macOS overview fixtures were replaced with live reporting models. Both platforms share strict DTOs and one remote repository. iOS retains exactly one custom bottom bar and root-owned navigation. macOS uses dense Fiscal-native cards, charts, account rows, forecast events, category composition, debt cycles, and contribution details. The first-launch Keychain bootstrap race found by the real iOS test was fixed by loading reports only after authentication succeeds.

Verification:

- Backend Ruff: passed.
- Backend Pyright: 0 errors, 0 warnings.
- PostgreSQL 17 full suite: 113 passed; the sole warning is the existing Starlette TestClient/httpx deprecation.
- Alembic drift: no new upgrade operations.
- Apple macOS suite: 46 tests passed.
- iOS 26 and macOS 26 builds: passed under Swift 6 complete concurrency.
- Real-API iOS UI path: overview, cash flow, spending report, and debt report; zero native tab bars and one Fiscal custom bottom bar. Contribution drill-down is covered by the shared SwiftUI implementation, backend API tests, and the macOS real-API render.

Visual evidence is retained in `screenshots/`:

- `ios-p7-overview.png`
- `ios-p7-cash-flow.png`
- `ios-p7-reports.png`
- `ios-p7-debt.png`
- `macos-p7-overview.png`
- `macos-p7-cash-flow.png`
- `macos-p7-reports.png`
- `macos-p7-cash-report.png`
- `macos-p7-debt.png`
- `macos-p7-drill-down.png`

The remaining gate is explicit user acceptance before P8 begins.
