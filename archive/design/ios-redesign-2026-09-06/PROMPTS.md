# Fiscal iOS 生图提示词 · 2026-09-06

工具：内置 image_gen。设计预览，全部为示例数据；不代表已完成 SwiftUI 实现。

## 三个主要页面与底部导航

Use case: ui-mockup.
Create ONE high fidelity iOS design review image containing THREE complete iPhone screens side by side: Fiscal 总览, 交易, 账户. All are the same coherent app on iPhone 16/17 with iOS 26-era proportions, portrait screens about 393x852pt. Landscape canvas approximately 1800x1350 or similar with enough resolution for crisp Chinese. Show straight-on screens, only very thin understated device edges and a Dynamic Island/status bar. No tilted phones, no decorative scene, no marketing headings, no captions between screens. All three full screens including home indicators and bottom controls must fit completely.

Input reference is the APPROVED Fiscal MAC interface and is ONLY a BRAND / TYPOGRAPHY / FINANCIAL HIERARCHY reference. Do not put a Mac sidebar or desktop columns on iPhone. Translate the same deep forest teal (#153B35), slightly brighter teal (#2D5B52), clear near-white reading surface, and true brand yellow (#F5C93F) to a light, refined MOBILE layout. White and light neutral reading surfaces dominate. Teal typography, restrained teal mini icons, no beige/cream/yellow large cards, no unrelated blue/purple. Borrow the simplicity and focused content prioritization of Dime and the sophisticated iOS 26 navigation surface of modern finance apps. This should feel buildable in SwiftUI, spacious but information-rich, not Apple Settings or an admin dashboard.

THE MOST IMPORTANT PART IS THE NEW BOTTOM NAVIGATION:
Identical geometry and tab order on ALL THREE screens.
Near the bottom safe area, a refined floating navigation capsule sits LEFT, containing exactly FOUR peer destinations in order:
house icon + “总览”, transaction-list icon + “交易”, wallet icon + “账户”, chart icon + “分析”.
Every icon has a readable Chinese text label underneath it. NEVER omit labels.
The capsule is softly frosted near-white, high opacity with only a subtle thin highlight and very restrained shadow. Around 268pt wide x 60pt high within a 393pt phone, all four equal-width tap targets. Its selected destination has a neat soft TEAL-tinted capsule behind its icon AND label, with deep teal active icon/text. Unselected icons are thin charcoal/gray, consistent size and weight. First screen selects 总览, second 交易, third 账户. Avoid garish glass or blur under text.
On the RIGHT of this capsule, with an 8–10pt gap, put a SEPARATE compact bright Fiscal-yellow rounded 64pt x 60pt action button, vertically aligned on the SAME BASELINE, containing a simple pen/receipt icon and the readable label “记一笔” underneath. This is a clearly labeled action, not a fifth page. No bare + glyph. No giant central add button. No upward-protruding button. No vacant middle gap. No duplication of a second bottom toolbar.
Horizontal margins about 16pt. Home indicator underneath in its own bottom safe area. Main scroll content ends above the control area, no overlapping or obscured rows. The bottom dock should be an elegant coherent control zone, NOT five detached circular bubbles. The nav is the visual priority for design scrutiny.

LEFT SCREEN — 总览:
Status 9:41. Compact header with small yellow F brand mark, bold title “总览”, understated date control “9 月”.
On white space: “账户净额”, confidently large “¥95,970.38”. Beneath a slim two-column line: “资产余额 128,450.38” and “信用欠款 32,480.00”.
One restrained light financial panel “本月支出”, “¥6,428.50”, small “收入 ¥28,000.00”, a simple thin deep-teal spending sparkline with only “1 日”, “3 日”, “6 日” axis ticks. No fabricated percentages.
Below: heading “接下来要付” and two clean compact flat rows: “信用卡还款” / “9 月 8 日” / “2,800.00”; “房租” / “9 月 12 日” / “4,500.00”. Small note “预计支付”.
If room, “最近交易”, one row “咖啡与早餐” / “今天 · 餐饮” / “−38.00”. Preserve breathing room above the nav. NO wall of cards.

MIDDLE SCREEN — 交易:
Status 9:41. Header “交易”, compact “9 月” control.
One quiet search field “搜索交易”, small integrated filter glyph. Below two compact filter chips “全部账户” and “全部类型”.
Slim monthly summary labels “支出 6,428.50” and “收入 28,000.00”.
Clean date-grouped transaction list on WHITE, stable right-aligned amounts, small muted teal category icons:
Group “今天 · 9 月 6 日”:
“咖啡与早餐” / “餐饮 · 日常账户” / “−38.00”
“午餐” / “餐饮 · 日常账户” / “−52.00”
“地铁” / “交通 · 日常账户” / “−6.00”
Group “昨天 · 9 月 5 日”:
“九月工资” / “收入 · 工资账户” / “＋28,000.00”
“超市采购” / “日用 · 日常账户” / “−268.50”
“音乐订阅” / “订阅 · 日常账户” / “−15.00”.
No giant form fields, no overly thick horizontal rules, no per-row card borders. Salary amount positive teal.

RIGHT SCREEN — 账户:
Status 9:41. Header “账户”, small quiet “管理”.
Top small label “现金与储蓄”, strong “¥128,450.38”, secondary “8 个账户 · 当前余额”.
A minimal two-option segmented filter: “现金与储蓄 8” selected in soft teal, “信用账户 6” unselected; these are account-type filters, NOT duplicated app navigation.
Search field “搜索账户”.
Flat separated account rows, each account name plus smaller account type and a clearly right-aligned balance:
“日常账户” / “现金” / “28,450.38”
“储蓄账户” / “储蓄” / “50,000.00”
“工资账户” / “储蓄” / “25,000.00”
“备用账户” / “现金” / “10,000.00”
“支付宝” / “电子钱包” / “6,000.00”.
The page scrolls for more accounts; no giant horizontal bank-card carousel, no pretending five visible equals all eight. Account count stays legible. Do NOT add currency conversions, new budgets or investment capabilities.

Typography: precise clean Simplified Chinese, PingFang/SF-like proportions. Headings around 28–30pt, main monetary values about 34–36pt with tabular numerals, body 14–16pt, nav labels 11pt with 44pt+ targets. Restrained corner radii, bright neutral white, calm financial personality. All data is synthetic, not personal financial data. Subtle outside-canvas fine print allowed only once at the very bottom: “Fiscal iOS 设计预览 · 示例数据”.

## 独立记一笔页面

Use case: ui-mockup.
Create ONE sharply rendered complete iPhone 16/17 portrait screen for Fiscal's “记一笔” expense-entry interface, matching the typography, clean white mobile surfaces, dark forest-teal ink, true Fiscal-yellow action color, and subtle rounded controls of the supplied THREE-SCREEN Fiscal iOS preview. The supplied image is a visual style reference, not the layout to copy. Output a single straight-on portrait iPhone screen, slim device border, Dynamic Island, status 9:41, full bottom safe area and home indicator. No angled device, environment, marketing text or additional screen. Large and legible, approximately 1024x2048 portrait.

Design goal: Dime-inspired focused and speedy entry. Amount is the hero. Keep the existing financial fields understandable and accessible. It is an independent full-screen creation flow opened by the yellow “记一笔” action, so DO NOT show the four-tab navigation dock or a second plus button while the numeric keyboard is active. Do NOT copy a Settings form or stack large input cards.

Palette: warm-neutral WHITE (not cream), deep teal #153B35 text, pale neutral-teal control fills and selected category, actual brand yellow #F5C93F for the save action only. No pink/red expense theme, no brown/beige, no blue or gradients. Beautiful crisp simplified Chinese, SF/PingFang-like typography, clear numeric columns and careful spacing.

Layout from top to bottom, all within a 393x852pt logical viewport:
1. Status bar/Dynamic Island.
2. Small close × button top left; centered header “记一笔”; no Save action in the top right.
3. A compact refined transaction-type strip: “支出” selected with soft teal fill and dark-teal text; “收入”; “转账”; small “更多” chevron. These select transaction KIND, not app pages. No loud border.
4. Generous focused central amount zone, largest element on page: small currency “¥” beside “38.00”, around 48–54pt monetary type. Below it a simple editable description “咖啡与早餐” with tiny pencil icon; NOT a big bordered text box.
5. Two compact information rows close to the keypad rather than a huge form:
First row two soft rounded selection controls, left small restaurant icon + “餐饮” + down chevron, right small wallet icon + “日常账户” + down chevron. Both are visibly tappable and similar size.
Second row: small calendar icon + “今天 · 9 月 6 日” + down chevron on left; quiet pencil/text icon + “添加备注” on right.
6. Numeric keypad, full comfortable width, a 3-column 4-row layout. Rows are “1 2 3”, “4 5 6”, “7 8 9”, “. 0 [backspace icon]”. Keys are minimal rounded light-neutral surfaces or subtle separated hit areas, about 50pt high; large readable deep-teal digits, generous touch targets. No alphabet letters, no duplicate keys, no '+/-', no multiplication or calculator operators. Respect decimal-CNY entry.
7. One wide but not huge rounded bright-yellow primary button BELOW the keypad: checkmark icon + exact text “保存支出”. Dark teal text, around 48–52pt logical height. Keep it above the home indicator with proper bottom safety spacing.
8. Native dark home indicator below, no other navigation bars.

Keep the total vertical rhythm practical: don't add an enormous empty gulf above the keypad or make the keyboard occupy the whole screen. All controls and the full save button visible without scrolling in this normal text-size preview. The transaction amount, category and source account must be legible in one glance. No unnecessary labels like technical sync/schema/parser concepts. The sole content is the UI with synthetic example amount. This is a calm, polished real finance app entry screen with the same Fiscal identity as the supplied main-page preview.
