# Fiscal P12 QA Checklist

Date: 2026-07-16

## Source and mapping

- [x] HZ LinoFinance source inventory and dependencies audited read-only.
- [x] User-approved accounts, period, timezone, opening balances, categories, reimbursement aliases, orphan repayment and cash-flow treatment are frozen.
- [x] USD, investment, deleted-module, voided and cross-boundary aggregates are excluded completely and reported.
- [ ] User decides the five confirmed Huabei entries attached to a voided legacy cycle.
- [ ] User decides the category for the unlinked `5月报销` income.

## Tooling and shadow verification

- [x] Source connection is forced to repeatable-read/read-only with a timeout and secret-safe DSN handling.
- [x] Exact decimal-to-fen conversion, Shanghai noon mapping and unknown-enum fail-closed behavior pass.
- [x] Migration runs/object provenance, stable idempotency and changed-hash conflicts pass PostgreSQL tests.
- [x] Business writes use Fiscal domain invariants and reimbursement income is not duplicated.
- [x] Local real-source shadow apply and identical rerun pass.
- [x] Account, credit, transaction, reimbursement and natural-month reconciliation pass with zero mismatches.
- [ ] HZ PostgreSQL 16 shadow drill passes using the release artifact and protected runbook.

## Production and release

- [ ] Both old LinoFinance and Fiscal receive verified pre-apply backups.
- [ ] Fiscal writes are stopped/exclusively locked and the source manifest is reverified immediately before apply.
- [ ] Production apply and idempotent no-op recheck pass.
- [ ] Production reconciliation and dual-client verification pass.
- [ ] Carried P11 v1.0 operational gates are complete.
- [ ] User accepts P12 and v1.0 release/tag.
