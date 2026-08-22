# Handoff: Fiscal — 个人财务 App (iOS + macOS)

## Overview
Fiscal is a single-user personal-finance app prototype for iOS and macOS ("OS 26" visual language). Both platforms share **one ledger** (accounts, transactions, categories) and present it through platform-appropriate navigation. Core jobs, in priority order: (1) record a transaction fast, (2) see how much money I have now, (3) see my transaction flow, (4) see what money is coming in / going out in the future. AI-assisted entry (screenshot OCR + Shortcuts text) proposes transactions that are auto-recorded when high-confidence & low-risk, otherwise queued for confirmation.

## About the Design Files
The file in this bundle (`Fiscal Prototype.dc.html`) is a **design reference created in HTML** — a working prototype showing intended look and behavior. It is **not production code to copy directly**. The task is to **recreate these designs in the target codebase's environment** using its established patterns and libraries:
- iOS → SwiftUI (recommended) or the app's existing UIKit/React Native stack.
- macOS → SwiftUI/AppKit, or the existing desktop stack (Electron/React, Catalyst, etc.).
- If no environment exists yet, pick the most appropriate native framework per platform and implement there.

`support.js` is only the prototype runtime — **do not port it**. It exists so the HTML opens in a browser.

## Fidelity
**High-fidelity (hifi).** Final colors, typography, spacing, radii, shadows, and interactions are all specified below and present in the HTML. Recreate the UI to match, using the codebase's native components (system nav bars, tab bars, toggles, lists) where they map cleanly — match the *values*, not necessarily the exact DOM structure.

---

## Platforms & Global Layout

### Shared shell (prototype only)
The prototype shows a device switcher (iOS / macOS pill) on a gradient desk background. In a real build each platform is its own app; ignore the switcher and the desk gradient.

### Color & type system (shared)
- **Font stack:** `-apple-system, "SF Pro Text", "SF Pro Display", "PingFang SC", "Segoe UI", system-ui, sans-serif`. Use SF Pro + PingFang SC (Chinese) — i.e. system fonts.
- **Numbers:** always `font-variant-numeric: tabular-nums`. Negatives use ASCII hyphen `-`, not U+2212.
- Headings are heavy: weights 700–760, negative letter-spacing (-0.5 to -1.2px) at large sizes.

---

## Design Tokens

### Colors
**Brand / accent** (user-tweakable; default first): `#2E68D6` (blue) · alt `#3C7C8C` · `#4C6EAE`
- accent-dark (gradients/pressed): shade of accent ≈ `#1E52B8` for default
- accent-soft (tinted fill): accent @ 12% alpha
- accent-border: accent @ 24% alpha

**Text**
- Primary `#1C2026`
- Secondary `#5C6675`
- Tertiary `#8A94A3`
- Muted / placeholder `#98A2B0`

**Semantic**
- Income / refund / positive `#1F9E6A` (green)
- Expense / negative `#D24B4E` (red)
- Credit / debt / due (amber) `#C2892B`
- Reimbursement / teal accent `#2E8E93`

**Category colors** (icon + tinted chip bg @ ~13% alpha)
- 餐饮 diner `#C0784A` · 交通 transit `#4E85B8` · 购物 shopping `#9B78B5` · 居住 housing `#4F9A86` · 娱乐 fun `#BE6E8C` · 医疗 medical `#C05A5A` · 通讯 telecom `#5F84B0` · 数码 digital `#77809F` · 工资 salary `#3E9C74` · 报销回款 reimb `#2E8E93`

**Surfaces**
- iOS screen bg `#EEF1F6`; cards `#FFFFFF`
- macOS canvas bg `#F4F6F9`; cards `#FFFFFF`
- macOS sidebar / iOS bars: translucent glass (see Glass)
- Hairline dividers: `rgba(60,70,90,.06–.09)`
- Card border: `.5px solid rgba(60,70,90,.06–.08)`

**Glass** (user-tweakable intensity 克制/适中/明显; default 适中)
- iOS bars: `background: rgba(255,255,255,.5)`, `backdrop-filter: blur(32px) saturate(200%)`, border `.5px rgba(255,255,255,.8)`, inset highlight `inset 0 1px 1.5px rgba(255,255,255,.95)`
- macOS sidebar: `background: rgba(226,233,246,~.45)`, `backdrop-filter: blur(50px) saturate(200%)`

### Spacing
Screen padding: iOS 16px horizontal; macOS content 20–22px. Card padding 15–20px. Gaps between cards 12px (iOS) / 14–16px (mac). Row vertical padding 9–14px.

### Radius
- Large cards: iOS 18–22px, macOS 14–16px
- Inner list/chips: 8–11px
- Icon tiles: 8–12px
- iOS tab-bar pill: 31px; record/AI sheet top corners: 28px
- Toggles: 13px (track), knob 22px circle

### Shadow
- iOS card: `0 1px 2px rgba(30,40,70,.05), 0 6px 16px rgba(30,40,70,.05)`
- macOS card: `0 1px 2px rgba(30,40,70,.04)`
- Floating (tab bar / FAB): `0 14px 40px rgba(20,30,50,.17)` / FAB `0 6px 18px rgba(46,104,214,.42)`
- Toast: `0 12px 34px rgba(16,24,44,.3)`

### Icons
Line icons, `viewBox 0 0 24 24`, `fill:none`, `stroke` = color, `stroke-width` 1.5–2.4, round caps/joins. Set: sparkles, chevronR, chevronL, house, list, plus, chart, ellipsis, camera, funnel, search, check, xmark, undo, gear (proper cog), wallet, card, receipt, doc, scan, shield, fork, car, bag, film, cross, bubble, monitor, briefcase, uturn, flow (two vertical arrows up/down = cash in/out). Recreate with the platform's SF Symbols equivalents where possible (e.g. gear→`gearshape`, flow→`arrow.up.arrow.down`, sparkles→`sparkles`).

---

## Data Model (shared ledger)

**Account**: `{ id, short, name, kind: 'debit'|'cash'|'credit', balance?, used?, limit?, due?, tail }`
Seed: 招行储蓄卡 (debit, ¥38,642.15, tail 6621) · 现金 (cash, ¥520.00) · 招行信用卡 (credit, used ¥6,842.30, limit ¥50,000, due ¥6,842.30, tail 8809) · 中信信用卡 (credit, settled, tail 3352).

**Transaction**: `{ id, date, day(label), title, catId, accountId, type, amount, flags, source }`
- `type`: `expense | income | transfer | credit | repayment | refund`
- `flags`: `{ credit?, installment?, reimbursable?, uncategorized? }`
- `source`: `manual | ai | ocr`
Seed spans 2026-07-01…07-14 (17 txns) incl. credit purchases, an installment (京东数码 ¥3,299, 6期), rent, salary, a repayment, a reimbursement refund, and one uncategorized.

**Category**: `{ id, name, glyph, color, dir: 'in'|'out' }` — 11 categories (see Category colors).

### Accounting rules (口径) — important
Three reporting lenses:
1. **消费 (spend)**: credit-card purchases count as spend; repayments do NOT re-count; transfers excluded. "扣除报销后净支出" subtracts pending reimbursable amounts.
2. **现金流 (cash flow)**: actual in/out of cash & bank accounts; credit-card repayment counts as outflow. Overview shows *this-month* net; the 现金流 tab/section shows *future* scheduled in/out (forecast).
3. **负债 (debt)**: current credit balances + future installment schedule.

**Cash-flow forecast** (used by iOS 现金流 tab + macOS 现金流 section + overview mini): upcoming dated events, sorted ascending:
- 报销回款 · 差旅报销单 +¥601.00 · ~07-18 · 待公司结算 (in)
- 招行信用卡还款 -¥6,842.30 · 07-22 · 本期账单 (out)
- 工资 · 8月 +¥21,500.00 · 08-09 (in)
- 京东分期 · 数码配件(2/6期) -¥566.50 · 08-10 (out)
- 房租 · 8月 -¥5,800.00 · 08-10 (out)
30-day net = +¥8,892.20 (in 22,101 / out 13,208.80).

---

## iOS Screens

Device: 390×844, safe-area top status bar (9:41 + signal/wifi/battery) always on top; dynamic island pill centered. Bottom: floating glass **tab bar pill** with 4 tabs + a center **+ FAB**. Home indicator bar at bottom.

**Tab bar order:** 总览 · 流水 · **[ + ]** · 现金流 · 更多.
- FAB: 52×52, radius 16, accent→accent-dark gradient, white + glyph, **vertically centered in the pill** (not raised). Opens the Record sheet.
- Tab item: 56px wide, icon 25px + 10px label; active = accent, inactive = `#9098A4`.

### 1. 总览 (Overview)
Scroll, padding-top 56px, bottom 128px.
- **Header row**: eyebrow `2026 年 7 月 · 本月` (12.5px, `#8A94A3`, 640) + title `总览` (32px, 740). Right: 40px round glass button with sparkles icon + red badge "1" → opens AI 待确认 sheet.
- **本月消费 card** (radius 22, white): label `本月消费` + `7月1日–14日 · 消费口径`; big amount 36px/760 `#1C2026`; `较上月 ↓ 8.2%`. Then category breakdown: up to 4 rows, each = 40px name + progress bar (7px, category color, rounded) + right amount. Bar width = amt/maxCat.
- **账户 card** (was two stat cards): header `可用余额` + right link `账户` (accent) → 更多. Big number = total available (debit+cash) `¥39,162.15` (33px/750) + `净资产 ¥{assets-debt}`. Then per-account rows: 32px icon tile, name + meta (`尾号 6621` / `现金` / `额度 ¥50,000.00`), right balance (credit shown as `-¥used` amber, else `#1C2026`).
- **本月现金流 card** (tappable → 现金流 tab): teal `flow` icon tile; title `本月现金流`; sub `流入 {in} · 流出 {out}`; right net amount colored (green/red).
- **待归类 banner** (only if uncategorized>0): amber tinted `rgba(194,137,43,.09)`, border `rgba(194,137,43,.22)`; question icon + `{n} 笔待归类 · 未计入消费统计` + `去处理`.
- **最近流水**: section title `最近流水` + `全部` link → 流水. Card lists latest 4 txns: 36px icon tile, title + `{category · account}` with inline tags (信用/分期/可报销/待归类/AI), right amount colored. Hairline between rows starts at left:62px.

### 2. 流水 (Transactions)
- Title `流水` (32px). Horizontal filter chips (scroll): 全部 / 支出 / 收入 / 转账·还款. Active = accent fill white text; inactive = white, `#5C6675`, `.5px` border.
- Transactions grouped by day label (今天 / 昨天 / 7月N日), each group a white card of rows (same row anatomy as overview recent). Tapping a row = (prototype) selects it.

### 3. 现金流 (Cash flow — future)
- Title `现金流`. **未来 30 天净现金流 card**: label + big net colored (34px/750) + `预计流入`/`预计流出` pair.
- Section `未来将要发生`: white card listing forecast events (see forecast data): 36px icon tile (category/semantic color), title + `{date} · {note}`, right amount colored (+green / -red). Hairline from left:60px.

### 4. 更多 (More)
- Title `更多`. White card, list rows → each pushes a **drill-down detail** (slide-in from right, `fSlide` 0.32s; status bar + island stay above). Row: 32px colored icon tile + label + right detail text + chevron.
  - 账户 → **Accounts detail**: 可用余额 card + all account rows.
  - 信用账期与分期 → **Credit detail**: 招行卡 (本期应还 30px amber, 账单周期, 还款日, 去还款/部分还款 buttons) + 本期消费明细 list + 分期计划 card + 中信卡 (已结清).
  - 报销 → **Reimbursement detail**: 应报销/已回款/待回款 stat trio + 67% progress + 关联垫付 list + 回款记录 list + "下一笔预计 ¥601 待公司结算".
  - 消费报表 → **Spend report**: 消费口径 total + 扣除报销后 + 待回款报销 + 分类构成 bars.
  - 负债报表 → **Debt report**: 当前信用负债 + 各账期 (招行 未还 / 中信 已结清) + 分期未来应还 (8月…11-12月).
  - AI 待确认 (badge 1) → opens the AI proposal sheet (not a push).
  - 分类设置 → **Categories**: list of all 11 categories (34px icon, name, 收入/支出 tag) + `新建分类` accent button.
  - 其他设置 → **Settings**: same controls as macOS Settings (see below), grouped 账户与同步 / 记账偏好 / AI 自动记账.
- Detail nav bar: 92px tall, glass, `< 更多` back (accent) bottom-left, centered title.
- Below the list: a sync status card (green dot `已同步` + "数据保存在个人 VPS · 仅本设备密钥访问").

### Record sheet (记一笔) — opened by FAB
Bottom sheet 92% height, radius 28 top, `fUp` slide. Grabber; 取消 / `记一笔` / 保存. Type chips (支出/收入/转账/信用消费/还款). Big amount display `¥0.00` colored by type. **拍照 / 截图识别** row (accent-soft) → starts AI OCR flow. Category grid (4-col, circular icon chips). Account + 可报销 toggle rows. Numeric keypad (1–9, ., 0, ⌫). Save validates amount>0, prepends txn, toasts `已记一笔 · ¥{amt}`.

### AI flows
- **OCR/scan** (from record sheet): scanning state → proposal → confirm writes txn (source ocr/ai). Undo available briefly.
- **AI 待确认 sheet** (from overview badge / 更多): list of proposals with source tag, confidence %, merchant/category/account/date, amount; low-confidence shows amber warning, auto-eligible shows green "满足自动记账条件 · 低风险 < ¥1,000"; actions 确认记账 / 编辑 / 忽略.

---

## macOS Screens

Window 940×700, radius 16, traffic-light dots top-left. **Left icon sidebar** 110px (centered glass, big glyph buttons; active = accent→accent-dark gradient tile with glow `0 7px 16px accent@42%` + inset highlight, white icon; inactive `#6B7484`). **Top bar**: section title left, right = search box only (220px). Content scrolls.

**Sidebar order:** 总览 · 流水 · 账户 · 现金流 · 报销 · 报表 · AI 待确认 (badge) · 设置.

### 总览 (Overview)
- 4 stat cards (repeat(4,1fr)): 本月消费 · 现金流净额 · 信用应还 · 报销待回款 (each: 12px label, 26px/730 value, 11.5px sub).
- Two-column (1.7fr / 1fr): **最近流水** table (columns 日期/摘要/分类/账户/金额, right-aligned amounts) with "在「流水」中查看全部" link; right column = **账户概览** card + **现金流** card (header + `查看全部` → 现金流 section, nearest 2 forecast rows).

### 流水 (Transactions)
Left: filter chips (全部/支出/收入/信用消费/还款/转账) + count; sticky table header; rows selectable (selected row = accent @10% bg). Right **inspector** 256px: icon+title+source, big amount, tags, type/category/account/date rows, relation note (e.g. 关联分期 / 计入本期账单), 编辑/删除 buttons.

### 账户 (Accounts)
3 summary cards (总资产/总负债/净值). Grid of account cards (2-col): icon tile (debit = accent gradient, credit = amber tint), name, tail; balance label + amount; **credit cards** additionally show 额度/已用 % bar, 本期应还 / 还款日 / 账单日, and an installment note. (Credit detail lives here — there is no separate 信用 section.)

### 现金流 (Cash flow — future)
Two-column (1.55fr/1fr): left = **未来现金流** card, list of forecast events (36px icon, title, `{date} · {note}`, 流入/流出 pill, right amount colored). Right = **未来 30 天净现金流** summary (big net + 预计流入/流出) + **关于现金流** explainer.

### 报销 (Reimbursement)
Two-column: left = claim card (应报销/已回款/待回款 + progress + 付款主体 table + 关联垫付 list). Right = 回款记录 + 支出口径 (原始消费 vs 扣除报销后净支出, with note that reimbursements aren't double-counted as income).

### 报表 (Reports)
Segmented 消费/现金流/负债. 消费 = total + 扣除报销后净支出 + 待回款 + 分类构成 bars. 现金流 = net + 流入/流出 + 按账户 table. 负债 = 当前负债 + 各账期应还 + 分期未来应还.

### AI 待确认
Header + count. List of proposal cards (source tag, confidence %, icon, merchant, type·category·account·date, amount; amber warning or green auto-eligible note; 确认记账/编辑/忽略).

### 设置 (Settings)
Max-width 660 column, grouped cards with section labels:
- **账户与同步**: 个人账本 avatar row + 云端优先 badge; 同步方式 `个人 VPS · Shanghai`; 同步状态 green dot `已同步 · 刚刚`; **端到端加密** toggle.
- **记账偏好**: 默认账户 (招行储蓄卡); **默认类型** segmented (支出/收入); 记账币种 (CNY ¥); **保存后停留在记一笔** toggle.
- **AI 自动记账**: **启用自动记账** toggle; when on → **自动记账上限** segmented (¥500/¥1,000/¥2,000) + **最低置信度** segmented (85%/90%/95%); **识别来源 · 截图 OCR** toggle; **识别来源 · 快捷指令文本** toggle; footnote: below threshold/confidence → falls to AI 待确认.
- **分类与统计**: 管理分类 (11 个分类); 统计口径 (消费·现金流·负债).
- **数据**: 导出流水 CSV; 导出账单 PDF; 清空本地缓存 (2.4 MB). Separate **退出登录** card (red).
- Toggle spec: track 42×26 radius 13, ON `#1F9E6A` / OFF `rgba(60,70,90,.22)`, white 22px knob, 0.2s bg transition. Segmented: option 6×13px pad, radius 8, ON accent fill white / OFF white `#5C6675` `.5px` border.

---

## Interactions & Behavior
- **Nav**: iOS tab switch = swap content; 更多 items push a full-screen detail (right-slide `fSlide`, back returns). macOS sidebar switches sections.
- **Record**: validates amount; prepends to ledger; success toast (auto-dismiss ~2.4s). If "保存后停留" is on, keep the sheet open for the next entry.
- **AI auto-record**: proposals ≥ min-confidence AND ≤ cap → auto-write; else queue in AI 待确认. Confirm writes to ledger with `source: ai/ocr`; brief Undo removes it.
- **Toggles/segmented** in Settings mutate settings state live and re-render dependent copy (e.g. auto-record sub-rows collapse when disabled).
- **Animations**: sheets `fUp` 0.34s cubic-bezier(.32,.72,0,1); detail push `fSlide` 0.32s same easing; toast `fToast`; fades `fFade` 0.22s. Respect reduce-motion.
- **Hit targets** ≥ 44px on iOS.

## State Management
- `platform` (prototype only), per-platform current tab/section.
- `ledger`: `txns[]` (mutable — record/AI append), `accounts[]`, `cats{}` (static seed).
- `recordForm`: `{ type, amount, accountId, catId, note, reimbursable }`.
- AI flow: `aiOpen, aiStep(0 idle/1 scanning/2 proposal/3 done), addedId, aiUndone`.
- `settings`: `{ encrypt, stayAfterSave, autoAI, aiCap, aiConf, srcOCR, srcShortcut, defaultType }`.
- iOS `moreStack`: which 更多 detail is pushed (null = list).
- Derived per render: month spend, inflow/outflow, net cash, credit due, uncategorized count, category breakdown, cash-flow forecast, report aggregates — compute from the ledger, do not store.
- Data fetching: prototype is local seed. Real app should sync to the user's private backend ("VPS"), end-to-end encrypted; treat OCR/Shortcuts inputs as untrusted proposals, never auto-authoritative above the configured thresholds.

## Assets
No raster images. All iconography is inline line-SVG (list above) — map to SF Symbols or your icon set. No third-party brand assets.

## Files
- `Fiscal Prototype.dc.html` — the full prototype (both platforms, all screens, all flows). Open in a browser to interact. All markup is inline-styled; logic (state, ledger, derived values, handlers) is in the `<script>` class at the bottom. Search the file for a screen's Chinese title to jump to its markup.
- `support.js` — prototype runtime only; **do not port**.
