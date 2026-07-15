# Fiscal P2 QA Checklist

## Scope and persistence

- [x] Only account/category master data was added; no P3/P4 business persistence exists.
- [x] PostgreSQL migration upgrades cleanly and is idempotent at head.
- [x] Money uses integer minor units and all persisted/API invariants match `p2-contracts.md`.
- [x] “待归类” is not stored as an ordinary category.

## Backend

- [x] Account CRUD, archive/restore, order, safe delete, and credit validation pass.
- [x] Category CRUD, two-level hierarchy, order, archive/restore, merge, split, and safe delete pass.
- [x] Name conflicts, hierarchy errors, in-use guards, and version conflicts use stable error codes.
- [x] Every P2 endpoint requires the device token and carries `X-Request-ID`.
- [x] Ruff format/check, strict Pyright, pytest, and Alembic checks pass.

## Apple shared layer

- [x] Both apps use shared Sendable DTOs, repositories, error mapping, and observable feature models.
- [x] Live P2 screens never use preview fixtures.
- [x] Loading, empty, offline, unauthorized, validation, conflict, and unexpected states are distinct.

## iOS 26

- [x] The system `TabView` layer is removed and exactly one bottom navigation bar is visible.
- [x] Accounts and Categories are reachable from More.
- [x] Account and category create/edit/archive/restore/delete flows use the real API.
- [x] Credit-only fields and two-level category rules are clear and validated.
- [x] Merge/split confirmations and long content fit without clipping.

## macOS 26

- [x] Accounts sidebar destination is live and supports dense account management.
- [x] Categories management is live with hierarchy, ordering, aliases, and examples.
- [ ] Final keyboard-focus and user-driven narrow-window inspection is part of visual acceptance.

## Integration and handoff

- [x] Real PostgreSQL and API are used for both apps.
- [x] CRUD changes made through the shared API are visible after refresh on both platforms.
- [x] iOS and macOS screenshots are retained under `docs/qa/p2/screenshots/`.
- [x] All commands and results are recorded in `docs/qa/p2/results.md`.
- [x] `git diff --check` passes and the P2 milestone is committed.
