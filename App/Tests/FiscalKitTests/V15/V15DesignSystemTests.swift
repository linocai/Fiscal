import Foundation
import Testing

@testable import FiscalKit

@Suite("V15 design-system contracts")
struct V15DesignSystemTests {
    @Test("light and dark tokens preserve the approved semantic palette")
    func paletteValues() {
        #expect(V15Palette.paper == .init(lightHex: 0xFFFFFF, darkHex: 0x0F1615))
        #expect(V15Palette.card == .init(lightHex: 0xF8F7F3, darkHex: 0x1A2423))
        #expect(V15Palette.ink == .init(lightHex: 0x14201F, darkHex: 0xE8EFED))
        #expect(V15Palette.teal == .init(lightHex: 0x0C5A5B, darkHex: 0x4FB3AC))
        #expect(V15Palette.yellow == .init(lightHex: 0xFCD668, darkHex: 0xB99333))
        #expect(V15Palette.gold == .init(lightHex: 0x8A6A12, darkHex: 0xD9A93C))
        #expect(V15Palette.provisional == .init(lightHex: 0xFFF8E4, darkHex: 0x241F12))
        #expect(V15Palette.receipt == .init(lightHex: 0xE9F2F0, darkHex: 0x122A29))
    }

    @Test("money presentation is minor-unit, tabular and non-wrapping")
    func moneySemantics() {
        let inflow = V15MoneyPresentation(minorUnits: 1_234, direction: .inflow)
        let outflow = V15MoneyPresentation(minorUnits: -1_234, direction: .outflow, includeCurrency: false)
        let balance = V15MoneyPresentation(minorUnits: -100, direction: .balance)
        #expect(inflow.text == "+¥12.34" && inflow.isTabular && inflow.neverWraps)
        #expect(outflow.text == "−12.34")
        #expect(balance.text == "¥1.00")
        #expect(V15MoneyPresentation(minorUnits: Int64.min, direction: .outflow).text == "−¥92,233,720,368,547,758.08")
        let optimistic = V15MoneyTruthPresentation(displayedMinorUnits: 12_300, confirmedMinorUnits: 10_000, pendingCount: 3, direction: .balance)
        #expect(optimistic.hasPendingValue)
        #expect(optimistic.pendingLabel == "含 3 项未同步")
        #expect(optimistic.displayed.text == "¥123.00")
        #expect(optimistic.confirmed.text == "¥100.00")
        #expect(!V15MoneyTruthPresentation(displayedMinorUnits: 100, confirmedMinorUnits: 100, pendingCount: -1, direction: .neutral).hasPendingValue)
    }

    @Test("platform dimensions and AX5 yielding order protect content")
    func accessibilitySpecifications() {
        #expect(V15Accessibility.minimumTouchTarget == 44)
        #expect(V15Accessibility.macVisibleRowHeight == 28)
        #expect(V15Accessibility.macHitInset == 4)
        #expect(V15Accessibility.largeTextYieldOrder.last == "金额不缩小、不换行、不截断")
    }

    @Test("unknown and missing disabled reasons always have an explanation")
    func disabledReasons() {
        #expect(V15Accessibility.safeReason(.unknownCapability) == "当前版本不支持此操作。")
        #expect(V15Accessibility.safeReason(nil).contains("不可用"))
        #expect(V15StateCopy.unknownReason.contains("无法继续"))
        let disabled = V15ButtonVisualSpec.resolve(kind: .primary, isEnabled: false)
        let enabled = V15ButtonVisualSpec.resolve(kind: .primary, isEnabled: true)
        #expect(disabled.foregroundOpacity == 0.35 && disabled.backgroundOpacity == 0.08)
        #expect(disabled.foreground == V15Palette.ink && disabled.background == V15Palette.ink)
        #expect(enabled.background == V15Palette.teal && enabled.foreground == V15Palette.primaryButtonText)
    }

    @Test("state vocabulary preserves preview, conflict, archive and display-only honesty")
    func stateCopy() {
        #expect(V15StateCopy.preview == "预览 · 尚未提交")
        #expect(V15StateCopy.archive == "归档 · 只读")
        #expect(V15StateCopy.displayOnly == "暂时无法识别 · 仅供查看")
        #expect(V15StateCopy.conflict.contains("未做任何修改"))
        #expect(V15Motion.receiptDuration > 0)
        #expect(V15PresentationStatus(serverStatus: "future_server_state") == .unknown)
        #expect(V15PresentationStatus(serverStatus: "future_server_state").safeLabel.contains("无法识别"))
        #expect(V15AccessibilityCopy.reload == "取最新数据重新决定")
        #expect(V15StateAccessibilityPolicy.behavior(hasAction: false) == .combinesStaticText)
        #expect(V15StateAccessibilityPolicy.behavior(hasAction: true) == .containsInteractiveChildren)
    }
}
