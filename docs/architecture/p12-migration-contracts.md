# Fiscal P12 Migration Contracts

Date: 2026-07-16

Status: frozen for shadow construction; one legacy-cycle anomaly awaiting user decision

## Safety boundary

- The existing HZ `linofinance` database is a read-only source. Audit and export sessions must use a read-only, repeatable transaction with a statement timeout. Migration never changes, repairs or deletes legacy rows.
- Fiscal production remains untouched until the source audit, user decisions, deterministic dry-run, shadow-database apply and reconciliation all pass. A verified backup of both databases is required immediately before production apply.
- USD accounts and rows, investment accounts and rows, voided rows, old category definitions, old independent cash-flow projections and deleted modules are excluded. If an aggregate crosses an excluded boundary, skip the whole aggregate and report it instead of partially importing it.
- Money is converted from exact decimal yuan to integer fen. A non-exact conversion, invalid date, missing dependency, unsupported length or changed source row is a conflict, never a silent truncation or guess.

## Migration unit and provenance

- A migration run has a unique ID, source database fingerprint, immutable source manifest, selected scope, code revision, timestamps and final status.
- Every imported aggregate receives a stable source identity and source-content hash in dedicated migration provenance tables. A rerun with the same hash is a no-op; a changed hash is a reported conflict and never silently overwrites Fiscal data.
- Stable UUIDv5 identifiers may be derived from the source identity, but all business writes still pass through a migration facade that preserves the same ledger, revision, cycle and reimbursement invariants as normal Fiscal services.
- Imported transactions use the explicit `legacy_import` source. The old creation origin remains provenance only; it must not trigger current AI behavior.
- Dry-run and apply produce machine-readable and human-readable inventory, conflict, skip and reconciliation reports with permissions that do not expose credentials.

## Semantic mapping

- Legacy `income` and `expense` entries map to normal ledger transactions. A purchase on a credit account maps to `credit_purchase`; it must bind a valid Fiscal cycle generated from the selected account rules.
- A legacy transfer between included cash/debit accounts maps to `transfer`. A legacy credit repayment maps to `repayment` only when both the paying cash/debit account and credit account are known and the payment can be allocated safely.
- A legacy calendar date becomes a timezone-aware Fiscal occurrence timestamp only after the user approves the timezone/time convention.
- Old categories are not copied. The user approves a new Fiscal category map; unresolved entries remain uncategorized and are reported.
- Reimbursement source expenses and claims migrate as one aggregate. Received claims use Fiscal's receipt service so their cash inflow is generated once; the linked old reimbursement-income entry is not also imported as ordinary income.
- Legacy credit-cycle rows are evidence for reconciliation, not rows to copy. Fiscal regenerates cycles from account rules; future generated legacy cycles are not imported.
- Legacy `cash_flow_items` are derived actuals or old predictions and are not independent ledger truth. They are skipped unless a separate supported planning feature and explicit mapping are approved.

## Execution stages

1. Audit: inventory rows, currencies, dependencies, balances and anomalies without writing either database.
2. Plan: freeze user-selected accounts, period, opening strategy, category map, orphan handling and reimbursement parties.
3. Dry-run: validate and hash every aggregate; emit create/skip/conflict totals and expected reconciliations.
4. Shadow apply: restore/copy the empty Fiscal production schema to an isolated database, execute the exact migration, then run backend and reconciliation suites.
5. Production apply: stop or exclusively lock Fiscal writes, back up both databases, verify source manifest, apply once, reconcile, then reopen clients.
6. Acceptance: compare account balances, credit liabilities/cycles, reimbursements and natural-month reports; retain LinoFinance read-only until Fiscal is stable.

## Frozen selection

- Migrate the three CNY balance accounts `农业4873`, `工商3495` and `杭联0519` as debit accounts, with approved opening balances CNY 0.00, CNY 26,249.49 and CNY 0.00 respectively.
- Migrate CNY credit accounts `工商3576`, `白条`, `花呗` and `车贷`; preserve their approved statement/due rules and reconcile their liabilities against the legacy cycles.
- Select all eligible business dates from 2026-05-16 through 2026-07-14 inclusive. Convert each legacy date to 12:00 Asia/Shanghai before Fiscal stores its UTC instant.
- Treat the source-less `2026-06-03 白条提前还款` CNY 1,410.64 as an opening-liability reconciliation adjustment. Do not invent a paying account or a cash-flow transaction.
- Build new Fiscal categories from the approved map. `平账` and `理财` are dedicated new categories rather than aliases of another category.
- Normalize legacy reimbursement payer strings `company`, `公司` and `111` to the single Fiscal party `公司`. Migrate the abandoned Claude subscription source expense without an active reimbursement claim.
- Do not migrate any of the 43 legacy cash-flow rows. Missing future plans may be re-entered manually after cutover.
- Five confirmed Huabei purchase entries total CNY 493.92 but point at a voided legacy credit cycle and are absent from the current Huabei liability. Shadow planning skips these complete aggregates by default; production apply remains blocked until the user confirms skip or supplies an alternative treatment.
