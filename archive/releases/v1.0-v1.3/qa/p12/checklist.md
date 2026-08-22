# Fiscal P12 QA Checklist

Date: 2026-07-16

## Source and mapping

- [x] HZ LinoFinance source inventory and dependencies audited read-only.
- [x] User-approved accounts, period, timezone, opening balances, categories, reimbursement aliases, orphan repayment and cash-flow treatment are frozen.
- [x] USD, investment, deleted-module, voided and cross-boundary aggregates are excluded completely and reported.
- [x] User approved skipping the five confirmed Huabei entries attached to a voided legacy cycle (CNY 493.92 total).
- [x] User approved dedicated income category `历史报销` for the unlinked `5月报销` income; six linked reimbursement-income rows remain suppressed.

## Tooling and shadow verification

- [x] Source connection is forced to repeatable-read/read-only with a timeout and secret-safe DSN handling.
- [x] Exact decimal-to-fen conversion, Shanghai noon mapping and unknown-enum fail-closed behavior pass.
- [x] Migration runs/object provenance, stable idempotency and changed-hash conflicts pass PostgreSQL tests.
- [x] Business writes use Fiscal domain invariants and reimbursement income is not duplicated.
- [x] Local real-source shadow apply and identical rerun pass.
- [x] Account, credit, transaction, reimbursement and natural-month reconciliation pass with zero mismatches.
- [x] HZ PostgreSQL 16 shadow drill and identical replay pass using the release artifact and protected runbook (148 targets, 152 skips, 38 checks, zero mismatch).

## Production and release

- [x] Both old LinoFinance and Fiscal receive verified pre-apply custom-format backups with SHA-256 manifests.
- [x] Fiscal/LinoFinance writes are stopped, database clients are drained and the source manifest is reverified immediately before apply.
- [x] Production apply has an exact-database, approved-fingerprint, exclusive-connection and pristine-or-replay fail-closed gate.
- [x] Production apply and idempotent no-op recheck pass (148 created, then 0 created / 148 unchanged).
- [x] Production reconciliation and dual-client verification pass; macOS UI still needs one local Keychain “Always Allow” click for the newly ad-hoc-signed build.
- [ ] Carried P11 v1.0 operational gates are complete.
- [ ] User accepts P12 and v1.0 release/tag.
