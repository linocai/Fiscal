# 账户摘要与多账户选择 · 生图提示词

工具：内置 image_gen。两张图分别展示默认状态与点开信用账户后的状态，全部为示例数据。

## 默认状态

Use case: ui-mockup, precise-object-edit.
Edit the supplied Fiscal macOS app screenshot. Preserve the entire main dashboard, all Chinese labels and example values, the window size/proportions, layout, typography, dark forest-teal sidebar, logo and bright yellow navigation selection. Output one sharp complete front-on app window at the same landscape aspect ratio. No device shell, no poster labels.

ONLY redesign the account area of the left sidebar under the navigation. The current pale cream/yellow cash card is rejected: remove it AND the separate unframed credit section below. Replace both with ONE elegant compact unified account-summary card. The sidebar has MANY cash and credit accounts, so NEVER enumerate individual accounts in this permanent sidebar. It must stay the same height regardless of account count.

Card visual: same brand teal hue as sidebar, but a distinctly lighter raised solid teal surface approximately #2D5B52 over sidebar #153B35, fine teal edge #50796E, restrained 12px radius, no shadow, no gradients. Crisp near-white main text and pale-teal secondary labels. NOT cream, beige, pale yellow, mint pastel, blue or a third hue. Keep vivid Fiscal yellow only in logo and selected navigation as in the reference.

The card has a small heading “账户概览”, then exactly TWO equally treated clickable grouped summaries INSIDE this same frame, separated by a fine horizontal line:
Upper group:
“现金与储蓄” with a right-pointing chevron
“¥128,450.38” in strong readable white numerals
“8 个账户 · 当前余额” in smaller readable secondary text
Lower group:
“信用账户” with a right-pointing chevron
“¥32,480.00” in strong readable white numerals
“6 个账户 · 当前欠款” in smaller readable secondary text
At the card bottom show a restrained action “查看全部账户 →”.
No individual bank/account names, NO separate credit content outside the card. Cash balance and credit debt remain clearly labeled and never added together.

The card should be modest in height, about the height of 2 summary rows plus heading/action, with useful breathing room below it before the original sidebar footer. Keep the original footer “个人账本” and “人民币 CNY”. Preserve the four nav items 总览 / 交易 / 账户 / 分析 above.

All other main-area pixels should remain as close to the input as possible: 账户净额 ¥95,970.38; 资产余额 128,450.38; 信用欠款 32,480.00; 本月收入 28,000.00; 本月支出 6,428.50; 本月净收支 +21,571.50; original expense chart, upcoming payments and three recent transactions. This image shows the DEFAULT resting state; no popup is open. Financial values are synthetic demo values. Clear sharp Chinese, no added explanatory prose.

## 选择账户

Use case: ui-mockup, precise-object-edit.
Use the supplied Fiscal macOS screenshot as the exact base. Keep the complete window, brand colors, all existing main-page typography, dashboard data, logo, navigation, and unified teal account-summary card unchanged. This is the SECOND interaction state of the same UI, not a new design.

Show the contextual account picker OPEN after clicking the “信用账户” row in the sidebar card. The permanent sidebar still shows ONLY grouped totals, exactly as the reference: 现金与储蓄 ¥128,450.38 / 8 个账户 · 当前余额, and 信用账户 ¥32,480.00 / 6 个账户 · 当前欠款. No individually enumerated sidebar accounts. Subtly highlight the selected credit group inside the teal card.

Add ONE compact native-style anchored popover immediately to the RIGHT of the sidebar card, overlapping the lower left portion of the main dashboard. Position it so the headline ¥95,970.38 remains unobscured at the top and the sidebar summary remains fully visible. Approximately 380–410 pixels wide in this 1536px full window, max height roughly 440–470 pixels. Opaque soft-white surface, 12px corner radius, very fine teal-gray border and restrained shadow; dark teal text. No full-window dimming, no drawer, no separate application window, no floating abstract demo layout.

The popover must demonstrate how many accounts are handled without growing the sidebar. Exact content:
Header “信用账户” with secondary count “6 个账户”, and small close × at upper right.
A compact rounded search field with magnifying glass and placeholder “搜索信用账户”.
A selectable row “全部信用账户” and a small checkmark.
Then a bounded SCROLLABLE account list. Each row contains a small simple card outline icon, account name, smaller trailing card digits under the name, and a right-aligned amount explicitly labelled “当前欠款”. Display these five synthetic visible rows with good readability:
“日常信用卡” / “尾号 1234” / “¥8,480.00”
“旅行信用卡” / “尾号 5678” / “¥6,000.00”
“备用信用卡” / “尾号 9012” / “¥3,000.00”
“购物信用卡” / “尾号 3456” / “¥7,000.00”
“家庭信用卡” / “尾号 7890” / “¥5,000.00”
Indicate more content by a subtle short vertical scrollbar INSIDE only this account-list region (the sixth account is below fold; total 6 accounts includes an unseen ¥3,000.00 debt, totals remain consistent). Do NOT draw all six if it would force height to expand. Footer separated from the scrollable list: “在账户页查看全部 →”.
Do not create nested colored cards inside the popup: these are clean flat rows with faint separators.

Preserve all other regions, including future bills and recent transactions, which remain behind the overlay without rearranging the dashboard. The normal sidebar card must still clearly contain both cash and credit summaries. Keep exact Fiscal palette: deep forest teal sidebar, lighter same-hue teal summary, bright yellow F and current nav. NO cream, beige, pale yellow account card, unrelated blue, marketing captions, callout arrows, or new product features. Sharp Chinese, stable aligned amounts, realistic macOS financial app UI. All numbers are example data.
