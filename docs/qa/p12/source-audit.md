# Fiscal P12 Legacy Source Audit

Date: 2026-07-16

Status: read-only audit complete; one newly discovered legacy-cycle anomaly awaiting decision

## Source inventory

All observations below came from read-only transactions against the HZ `linofinance` PostgreSQL database. No legacy or Fiscal production rows were changed.

| Object | Rows | Initial disposition |
|---|---:|---|
| Accounts | 12 | 7 CNY non-investment candidates; 5 USD/investment excluded |
| Categories | 21 | definitions excluded; values require new manual mapping |
| Financial entries | 133 | 121 confirmed CNY non-investment candidates before semantic review |
| Category lines | 120 | dependencies validated |
| Account movements | 145 | dependencies validated |
| Account adjustments | 33 | investment-only; excluded |
| Credit statement cycles | 25 | reconciliation evidence; not copied directly |
| Installment plans | 0 | nothing to migrate |
| Reimbursement claims | 7 | 6 received and 1 abandoned |
| Cash-flow items | 43 | derived/predicted rows; excluded by default |
| Attachments | 0 | nothing to migrate |

## Candidate accounts

The candidate balance accounts are `农业4873` (CNY 0.00), `工商3495` (CNY 2,815.12) and `杭联0519` (CNY 20,000.00). The user confirmed that all three migrate as Fiscal debit accounts.

The candidate credit accounts are `工商3576` (CNY 3,245.10 liability; statement day 25, due day 12), `白条` (CNY 4,091.34; 1/11), `花呗` (CNY 1,090.47; 1/8) and `车贷` (CNY 15,198.00; 20/22). Their current liabilities exactly match the legacy authoritative cycle balances.

To reproduce those closing liabilities from the selected history, the migration plan derives opening credit liabilities immediately before 2026-05-16 as follows:

| Credit account | Closing liability | Selected charges | Imported repayments | Opening liability |
|---|---:|---:|---:|---:|
| 工商3576 | 3,245.10 | 1,447.43 | 2,539.60 | 4,337.27 |
| 白条 | 4,091.34 | 4,304.44 | 4,216.07 | 4,002.97 |
| 花呗 | 1,090.47 | 1,485.63 | 1,510.93 | 1,115.77 |
| 车贷 | 15,198.00 | 0.00 | 2,533.00 | 17,731.00 |

The CNY 1,410.64 source-less White Bar repayment is intentionally absent from imported repayments and absorbed into White Bar's approved opening-liability treatment. This preserves the closing debt without inventing a cash outflow.

Five additional confirmed Huabei purchases totaling CNY 493.92 have a linked legacy cycle marked `voided`. Those purchases are absent from the legacy current liability, so importing them as credit purchases would overstate Fiscal debt. Shadow planning marks the five complete aggregates `confirmed_entry_on_voided_credit_cycle` and excludes them pending user confirmation. The table uses that shadow decision: eligible Huabei charges are CNY 1,485.63 and its reproducible opening liability is CNY 1,115.77; the closing liability remains CNY 1,090.47 after the CNY 1,510.93 repayment.

`Crypto`, `Funds`, `Stock`, `USDT` and USD credit account `工商5438` are excluded by the P12 product decision. All 33 balance adjustments affect investment accounts and are excluded with them.

For the approved full-history import beginning with the earliest candidate event, the approved opening balances are `农业4873` CNY 0.00, `工商3495` CNY 26,249.49 and `杭联0519` CNY 0.00.

## Candidate ledger history

- The source contains 112 confirmed, single-account, pure-CNY, non-investment entries and 9 confirmed pure-CNY transfers/repayments wholly between candidate accounts.
- The nine transfer aggregates comprise four normal balance-account transfers and five repayments with a recorded paying account.
- Among the 112 single-account entries, `2026-06-03 白条提前还款` for CNY 1,410.64 records only the credit repayment movement and no paying account. It cannot become a valid Fiscal repayment until its source account or alternative treatment is approved.
- Five voided entries remain in the old database for audit and are skipped by default. Four USD entries and all entries touching investments are skipped as complete aggregates.
- Dependency checks found no orphan category lines, categories, movements or accounts; no category/movement amount mismatch; and no invalid CNY converted amount.

The approved business-date range is 2026-05-16 through 2026-07-14 inclusive. Each legacy date maps to 12:00 Asia/Shanghai.

## Categories needing a new map

The old expense labels are `AI专项`, `买衣服`, `健身专项`, `公司自费`, `其他支出`, `吃饭`, `平账`, `意外`, `报销`, `月付`, `游戏`, `猫猫`, `理财`, `生活用品`, `电子产品`, `社交`, `超市`. The old income labels are `工资`, `意外`, `房租`, `报销`.

No old category definition is copied. Ordinary reimbursement-receipt income must be suppressed when the Fiscal reimbursement receipt is generated, avoiding a duplicated inflow. The approved flat mapping is:

| Legacy direction/name | Fiscal category |
|---|---|
| expense / 吃饭 | 餐饮 |
| expense / 超市, 生活用品 | 日用 |
| expense / 买衣服 | 服饰 |
| expense / 猫猫 | 宠物 |
| expense / 社交 | 社交 |
| expense / 游戏 | 娱乐 |
| expense / 电子产品 | 数码 |
| expense / 健身专项 | 健康 |
| expense / 月付 | 固定支出 |
| expense / AI专项 | AI工具 |
| expense / 公司自费, 报销 | 工作垫付 |
| expense / 其他支出, 意外 | 其他支出 |
| expense / 平账 | 平账 |
| expense / 理财 | 理财 |
| income / 工资 | 工资 |
| income / 房租 | 房租 |
| income / 意外 | 其他收入 |
| income / 报销 | generated reimbursement receipt; no ordinary-income duplicate |

## Reimbursements needing confirmation

- Six received claims total CNY 6,487.37. Every one has a source expense, receipt entry, receiving account and cash-flow link, so they can map structurally once parties are approved.
- The user confirmed that payer strings `company`, `公司` and `111` all mean the single party `公司`.
- One CNY 1,441.83 `Claude订阅` claim is `abandoned` and has no receipt. Its source expense migrates, but no active Fiscal reimbursement claim is created.

## Items excluded by default

- All 43 legacy cash-flow rows. Actual rows are derivatives of the ledger and received reimbursements; expected salary/rent rows belong to an old prediction model that Fiscal does not currently implement.
- All future legacy `statement_generated` credit-cycle rows. Fiscal will generate cycles from the approved account rules and use old cycles only for reconciliation.
- All investment/USD data, adjustments, voided entries, old category definitions and deleted-module data.

Every exclusion will appear with its source identity and reason in the dry-run report.
