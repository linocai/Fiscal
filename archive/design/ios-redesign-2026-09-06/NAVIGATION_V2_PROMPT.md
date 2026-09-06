# iOS 导航 v2 · 生图提示词

- 工具：内置 image_gen，编辑模式。
- 输入：`fiscal-ios-main-pages-v1.png`（已查看）。
- 输出：`fiscal-ios-navigation-v2.png`。
- 范围：保留已认可的页面内容，只修正悬浮导航与记一笔入口；生图近似材质，不是原生运行截图。

```text
Use case: precise-object-edit.
Asset type: Fiscal iPhone UI design revision, with an enlarged navigation detail.
Input image 1 is the existing Fiscal three-phone mockup. Edit target: ONLY its LEFT overview phone. Preserve the approved content, brand, typography, financial numbers, hierarchy, chart, transactions and white/light appearance. Do NOT show the middle or right phones.

Primary request: Correct the bottom navigation so it convincingly resembles the refined actual iOS 26 native Liquid Glass TabView, instead of the rejected rounded-rectangle dock and separate yellow square. This is the central purpose of this image.

Composition: a high-resolution landscape design review sheet with ONE complete front-facing iPhone on the left, showing the existing overview, and ONE enlarged exact repeat of that phone's bottom navigation on the right. White or extremely light neutral canvas, generous empty space. The enlarged detail must match the phone navigation exactly, not be another option. Keep the complete phone visible including Dynamic Island and home indicator. Right detail has small Chinese caption "悬浮导航 · 放大细节". A small footer reads "Fiscal iOS · 设计预览 · 示例数据". Avoid promotional headlines or paragraphs.

NAVIGATION — essential:
One continuous full-width floating horizontal optical-glass CAPSULE, four evenly distributed native tab items, ordered "总览", "交易", "账户", "分析". Icon above its label. No fifth item. No separate action next to the bar. On a roughly 393pt phone viewport, capsule is around 357pt wide and 64pt high, sides inset about 18pt, with perfectly semicircular ends (radius half its height). Float approximately 10pt above the home indicator zone. Do not attach a full-width solid footer background or draw a top separator.
Material: current iOS 26 refined neutral Liquid Glass, soft frosted translucency, barely visible continuous optical edge highlight, subtle broad shadow beneath the floating capsule, softly blurred white content and faint gray list separators showing behind it. Clear, light, tasteful. No dark outlines, no metallic rims, no thick border, no candy glass, no exaggerated reflections.
Selected first tab: a smooth HORIZONTAL inner capsule about 80pt by 52pt, fully round ends, tucked 6pt within the outer capsule. Very soft translucent neutral gray selection lens, NOT a mint square or green outlined card. Deep forest teal #153B35 house glyph and label. Other tabs have balanced near-black/gray SF Symbols-like outline glyphs and medium gray labels: list, wallet, bar chart. All labels crisp and readable, identical optical size. No separators, no four individual button backgrounds.
The enlarged view repeats this exact four-item pill at roughly twice scale, over a barely visible blurred excerpt of white transaction content. Show its delicate material and rounded geometry clearly.

CREATE ACTION: Completely REMOVE the old bottom-right yellow square "记一笔". On the phone's existing top-right header, retain a compact "9月" month selector and add a small native round clear-glass compose control to its right, deep teal square.and.pencil style glyph, roughly 36pt diameter. This is the entry to 记一笔. Keep the header uncrowded. Do not put a yellow plus or yellow action block anywhere at the bottom.

Preserve phone main content from reference: yellow Fiscal F logo, 总览, 账户净额 ¥95,970.38, 资产余额 128,450.38, 信用欠款 32,480.00, 本月支出 ¥6,428.50, 收入 ¥28,000.00, thin teal monthly line chart, 接下来要付 with 信用卡还款 2,800.00 and 房租 4,500.00, 最近交易 咖啡与早餐 −38.00. Keep clean white whitespace, thin gray dividers and restrained teal accents. Leave a safe content inset so the bar does not cover the last readable transaction.

Constraints: This is a precise navigation correction, not a redesign of accepted body content. The distinctive yellow logo stays. No cream/beige recoloring. No bright yellow bottom control. No rectangular active tiles. No lifted center action, no notched bar. No new business features. Render readable Simplified Chinese and believable native mobile proportions.
```
