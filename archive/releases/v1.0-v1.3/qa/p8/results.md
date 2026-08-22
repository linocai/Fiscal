# Fiscal P8 QA Results

Date: 2026-07-16

Status: engineering complete; awaiting user visual acceptance. P9 has not started.

## Delivered

- Server-owned text AI provider boundary with strict schema, bounded input/output, stable safe errors, and no client-visible provider secrets.
- Versioned AI settings and proposal state machine covering processing, pending, executed, failed, ignored, and undone.
- Deterministic automatic-execution policy limited to ordinary income/expense, ¥1,000 maximum, and 9,000 bps minimum for every required field.
- Proposal edit/execute/ignore/retry/undo with optimistic concurrency, idempotent replay, and execution through the formal ledger service.
- All five supported proposal drafts: expense, income, transfer, credit purchase, and repayment; repayment selects a real credit cycle.
- iOS dynamic AI badge, compact list/editor, failed retry, and real AI Settings destination while preserving the complete More information architecture.
- macOS dense AI queue/inspector and Fiscal-native AI Settings screen.

## Automated verification

- `uv lock --check`: passed.
- Ruff format/check: passed across 92 files.
- Pyright: 0 errors.
- Alembic upgrade/check/downgrade guard: passed against PostgreSQL.
- Full backend suite: 161 passed, 1 existing Starlette/httpx deprecation warning.
- Generic iOS 26 build: passed.
- macOS 26 Swift test/build: 51 tests across 7 suites passed.
- Authenticated real-API iOS UI test on iPhone 16 Pro / iOS 26.5: 1 passed, 0 failed.
- Snapshot tool build and macOS rendering: passed.

## Visual evidence

- `screenshots/ios-p8-overview-ai-badge.png`
- `screenshots/ios-p8-ai-pending.png`
- `screenshots/ios-p8-ai-edit.png`
- `screenshots/ios-p8-settings-ai.png`
- `screenshots/macos-p8-ai-pending.png`
- `screenshots/macos-p8-ai-inspector.png`
- `screenshots/macos-p8-settings-ai.png`

The iOS evidence comes from the production app connected to an authenticated local PostgreSQL-backed API. The macOS queue and inspector evidence is one complete split-view state captured under both required filenames; the two images are intentionally identical.

## External configuration

No production provider secret is stored in the repository. Until the VPS environment supplies provider URL, model, and API key, the application truthfully reports that AI is not configured and keeps automatic execution disabled.

## Acceptance gate

- [ ] User visually accepts P8 before P9 begins.
