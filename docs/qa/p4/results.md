# Fiscal P4 QA Results

Date: 2026-07-15 (Asia/Shanghai)

## Outcome

P4 credit purchases, statement cycles, and repayments are implemented across the authenticated API, iOS 26, and macOS 26. The Apple flows were exercised against a disposable local PostgreSQL database through the real FastAPI service. P5 does not begin before P4 user acceptance.

## Backend gates

- Ruff format/check: pass
- Pyright strict: pass (0 errors, 0 warnings)
- default pytest: 50 passed, 27 PostgreSQL tests skipped by design
- disposable real PostgreSQL suite: 77 passed
- fresh P1 → P4 migration and harmless second upgrade: pass
- empty-data P4 → P3 → P4 migration round trip: pass
- data-bearing downgrade preflight: transactionally rejected without deleting P4 data
- Alembic model drift check and offline SQL generation: pass

The real integration suite used local PostgreSQL 14 because Docker Hub downloads for the PostgreSQL 17 container remain blocked by the host proxy path. No PostgreSQL 17 result is claimed.

## Apple gates

- Project generation: `xcodegen generate --spec apple/project.yml` passed.
- iOS 26 build passed.
- macOS 26 build passed.
- macOS shared Swift Testing suite passed: 21 tests.
- Authenticated iOS UI integration test passed: 1 test, 0 failures, 17.460 seconds.
- Toolchain remains Swift 6 language mode with iOS 26.0 and macOS 26.0 minimum deployment targets.

## Real integration smoke

The UI run used only the disposable PostgreSQL database `fiscal_p4_qa_codex_20260715`. Alembic migrated the empty database to head, the real API seeded two cash/debit accounts and two credit cards, and the native clients read the same records through authenticated HTTP requests.

The retained scenario includes an overdue 招行信用卡 cycle with a ¥3,280.00 purchase and ¥1,280.00 partial repayment, a current cycle with two purchases, and a settled 中信信用卡 cycle. The iOS UI test navigated More → 信用账期 → 招行信用卡 → cycle detail → repayment editor. It also asserted zero native tab bars and exactly one `fiscal.customBottomBar`.

After capture, the API and macOS app were stopped, the disposable database was dropped, the exact QA generic-password item was removed from macOS Keychain, and the test Simulator was shut down and erased. No QA service or app process remains.

## Visual evidence

Evidence is retained under `docs/qa/p4/screenshots/`:

- `ios-credit-account.png` — authenticated credit summary with debt, limit, overdue state, and cycle history.
- `ios-credit-cycle.png` — stable navigation state with a complete back button, cycle totals, repayment action, and traceable purchase/repayment rows.
- `ios-credit-repayment.png` — repayment editor with explicit payment account, credit account, and an untruncated two-line target-cycle summary.
- `mac-accounts-credit-inspector.png` — exact 1880×1400 Retina capture (940×700 points) with reference-style account cards, selected credit state, and the 256-point cycle inspector.

Visual comparison against `design_handoff_fiscal_app` confirms the intended 110-point macOS sidebar, 20-point content padding, compact white cards, amber debt semantics, explicit selection state, and no clipping or horizontal overflow. On iOS, the reference card hierarchy, rounded surfaces, system navigation, and single custom bottom bar are preserved.
