# Fiscal P8 QA Checklist

Date: 2026-07-16

## Contract and security

- [x] Provider boundary, proposal state machine, automatic-execution allowlist, thresholds, and APIs frozen before implementation.
- [x] Provider key/model/base URL remain server-only and never appear in API responses, proposal rows, or logs.
- [x] Disabled/missing/timeout/429/5xx/invalid provider states fail safely with no ledger side effect.
- [x] Prompt input is bounded and treated only as untrusted data; strict output rejects extra fields, float money, system kinds, and fabricated IDs.
- [x] Content fingerprint is indexed but non-unique; Idempotency-Key/request hash owns retry semantics.

## Backend

- [x] P8 migration creates versioned singleton settings and proposals, expands only trusted `ai_text`, and updates current P5/P6 validators.
- [x] Public transaction API cannot set source; AI execution reuses formal TransactionService and produces ordinary editable ledger rows.
- [x] Processing/pending/executed/failed/ignored/undone transitions enforce row lock and optimistic version.
- [x] Parse/edit/execute/ignore/retry/undo are idempotent where specified and concurrent execution creates one transaction/revision.
- [x] Automatic execution allows only ordinary income/expense at or below ¥1,000 with every required field at or above 9,000 bps.
- [x] User settings may tighten amount/confidence and cannot weaken the server floor/cap or override risk.
- [x] Settings, pending count, newest-first pagination, and stable errors pass authenticated HTTP tests.
- [x] Ruff format/check, Pyright, full PostgreSQL suite, Alembic upgrade/drift/downgrade guards pass.

## Apple

- [x] One shared AIProposalModel owns proposals and authoritative pendingCount across every entry and badge.
- [x] iOS production overview has a dynamic AI badge; More contains AI Pending and real Settings destinations.
- [x] iOS AI/settings surfaces are compact lists with no charts, default Form, or legacy-looking buttons.
- [x] macOS AI and Settings sidebar destinations are real dense Fiscal-native screens with dynamic badge.
- [x] P8 Settings exposes only automatic execution, amount cap, confidence, and true provider readiness; later-phase settings are not presented as implemented controls.
- [x] Execute/undo refreshes transactions/reports and the created AI transaction supports normal editing/voiding.
- [x] DTO, stale-response, idempotency-retention, settings-version, and dynamic-badge tests pass.
- [x] iOS 26 build/real-API UI test and macOS 26 test/build pass under Swift 6.

## Visual evidence

- [x] iOS overview AI badge.
- [x] iOS pending proposal list and editor.
- [x] iOS Settings AI group.
- [x] macOS AI queue/inspector.
- [x] macOS Settings AI group.
- [ ] User accepts P8 before P9 begins.
