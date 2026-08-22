# P4 QA Checklist

## Contract and scope

- [x] P4 contract frozen before implementation.
- [x] Scope limited to credit purchases, credit cycles, and repayments; installments remain P5.
- [x] iOS/macOS 26 minimum and latest stable Swift toolchain retained.
- [x] Opening debt requires explicit as-of/due dates and is never assigned a fabricated deadline.

## Backend

- [x] Credit cycle migration, constraints, models, and calendar derivation implemented.
- [x] Credit purchases and repayments extend the unified ledger and posting trigger.
- [x] Opening debt, available credit, over-limit, cycle amounts, and status are server-derived.
- [x] Full/partial repayment, edit, void, restore, idempotency, concurrency, and rollback pass.
- [x] Credit purchases count as expense; repayments do not duplicate income/expense.
- [x] Ruff, Pyright, default tests, real PostgreSQL tests, Alembic checks, and offline SQL pass.

## Apple shared layer

- [x] Integer-money credit DTOs, repository actors, and observable models implemented.
- [x] Credit purchase/repayment editor validation and exact payload tests pass.
- [x] Loading, empty, offline, unauthorized, conflict, overpayment, over-limit, and opening-configuration states work without fixture fallback.

## iOS

- [x] More → Credit cycles uses the real API and preserves the single custom bottom bar.
- [x] Credit summary and cycle detail show due, repaid, remaining, status, and traceable transactions.
- [x] Full and partial repayment use explicit payment account and target cycle.
- [x] Global record sheet creates and completely edits credit purchases and repayments.

## macOS

- [x] Accounts uses reference-style asset/debt/net-worth metrics and modern account cards.
- [x] Credit cards show limit usage, current due, statement date, and due date.
- [x] Credit account selection exposes cycle history/detail and repayment actions.
- [x] 940×700 layout has no clipping or horizontal overflow.

## Evidence and acceptance

- [x] Real API integration run recorded in `results.md`.
- [x] iOS credit summary, cycle detail, and repayment screenshots captured.
- [x] macOS accounts, credit detail, and repayment-action evidence captured.
- [ ] User accepts P4 credit debt and repayment behavior before P5 begins.
