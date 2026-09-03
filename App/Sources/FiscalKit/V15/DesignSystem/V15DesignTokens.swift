import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Explicit design values keep the visual language testable without asking a
/// View test to inspect an environment-resolved `Color`.
public struct V15ColorToken: Sendable, Equatable {
    public let lightHex: UInt
    public let darkHex: UInt

    public init(lightHex: UInt, darkHex: UInt) {
        self.lightHex = lightHex
        self.darkHex = darkHex
    }

    public var color: Color { Color(v15Light: lightHex, dark: darkHex) }
}

/// Fiscal keeps one restrained brand palette and a separate safety semantic.
/// Errors and destructive actions must never borrow the brand or warning hue.
public enum V15Palette {
    public static let paper = V15ColorToken(lightHex: 0xFFFFFF, darkHex: 0x0F1615)
    public static let card = V15ColorToken(lightHex: 0xF8F7F3, darkHex: 0x1A2423)
    public static let canvas = V15ColorToken(lightHex: 0xF4F2EC, darkHex: 0x0B1110)
    public static let ink = V15ColorToken(lightHex: 0x14201F, darkHex: 0xE8EFED)
    public static let teal = V15ColorToken(lightHex: 0x0C5A5B, darkHex: 0x4FB3AC)
    public static let yellow = V15ColorToken(lightHex: 0xFCD668, darkHex: 0xB99333)
    public static let gold = V15ColorToken(lightHex: 0x8A6A12, darkHex: 0xD9A93C)
    public static let hairline = V15ColorToken(lightHex: 0xE8E6E1, darkHex: 0x2A3534)
    public static let selected = V15ColorToken(lightHex: 0xE9F2F0, darkHex: 0x122A29)
    public static let provisional = V15ColorToken(lightHex: 0xFFF8E4, darkHex: 0x241F12)
    public static let danger = V15ColorToken(lightHex: 0xB4232C, darkHex: 0xFF7A82)
    public static let dangerSurface = V15ColorToken(lightHex: 0xFFF0F1, darkHex: 0x2B1618)
    public static let receipt = selected
    public static let primaryButtonText = V15ColorToken(lightHex: 0xFFFFFF, darkHex: 0x08201F)
    /// A quiet desktop sidebar is intentionally distinct from content paper.
    /// It lets selection carry the navigation signal instead of turning every
    /// module into a large coloured button.
    public static let sidebar = V15ColorToken(lightHex: 0xEFEEE8, darkHex: 0x111A19)
    public static let surfaceRaised = V15ColorToken(lightHex: 0xFCFBF8, darkHex: 0x202B2A)
}

public enum V15Spacing {
#if os(macOS)
    public static let xxs: CGFloat = 3
    public static let xs: CGFloat = 6
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let section: CGFloat = 24
#else
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 28
    public static let section: CGFloat = 34
#endif
}

public enum V15Radius {
#if os(macOS)
    public static let tag: CGFloat = 4
    public static let control: CGFloat = 6
    public static let card: CGFloat = 8
    public static let decisionCard: CGFloat = 10
#else
    public static let tag: CGFloat = 5
    public static let control: CGFloat = 10
    public static let card: CGFloat = 14
    public static let decisionCard: CGFloat = 16
#endif
}

public enum V15Elevation {
    public static let lightCardShadowOpacity = 0.035
    public static let lightCardShadowRadius: CGFloat = 8
    public static let lightCardShadowY: CGFloat = 3
    /// Dark surfaces use luminance steps, never shadows.
    public static let darkCardShadowOpacity = 0.0
}

public enum V15Motion {
    public static let pressDuration = 0.14
    public static let stateDuration = 0.20
    public static let receiptDuration = 0.18
    public static let standard = Animation.easeOut(duration: stateDuration)
}

public enum V15Typography {
#if os(macOS)
    public static let surfaceTitle = Font.system(size: 26, weight: .bold, design: .rounded)
    public static let cardTitle = Font.system(.title3, design: .default, weight: .semibold)
    public static let body = Font.system(.body, design: .default, weight: .regular)
    public static let secondary = Font.system(.callout, design: .default, weight: .regular)
    public static let label = Font.system(size: 11, weight: .semibold, design: .default)
    public static let money = Font.system(.body, design: .monospaced, weight: .semibold)
    public static let moneyLarge = Font.system(.title, design: .monospaced, weight: .semibold)
#else
    public static let surfaceTitle = Font.system(.largeTitle, design: .default, weight: .bold)
    public static let cardTitle = Font.system(.title2, design: .default, weight: .semibold)
    public static let body = Font.system(.body, design: .default, weight: .regular)
    public static let secondary = Font.system(.subheadline, design: .default, weight: .regular)
    public static let label = Font.system(.caption2, design: .default, weight: .semibold)
    public static let money = Font.system(.body, design: .monospaced, weight: .semibold)
    public static let moneyLarge = Font.system(.title, design: .monospaced, weight: .semibold)
#endif
}

/// Shared desktop sizing contracts. Feature pages use these values rather
/// than independently pinning a narrow column in a wide application window.
public enum V15MacLayout {
    public static let minimumWindowWidth: CGFloat = 1_000
    public static let minimumWindowHeight: CGFloat = 680
    public static let sidebarWidth: CGFloat = 224
    /// At the supported minimum window width navigation becomes an icon rail,
    /// leaving enough room for a complete three-pane workbench.
    public static let compactSidebarWidth: CGFloat = 76
    public static let inspectorWidth: CGFloat = 344
    public static let compactInspectorWidth: CGFloat = 292
    public static let contentPadding: CGFloat = 24
    public static let toolbarHeight: CGFloat = 56

    public static let compactAIWidths: (spine: CGFloat, detail: CGFloat, inspector: CGFloat) = (210, 390, 290)
    public static let compactStatementImportWidths: (evidence: CGFloat, rows: CGFloat, inspector: CGFloat) = (190, 400, 290)
    public static let compactReimbursementWidths: (spine: CGFloat, detail: CGFloat, inspector: CGFloat) = (220, 390, 300)
    public static let compactInstallmentWidths: (spine: CGFloat, schedule: CGFloat, inspector: CGFloat) = (210, 380, 300)

    public static var compactModuleAvailableWidth: CGFloat {
        minimumWindowWidth - compactSidebarWidth - 1
    }
    public static var widestCompactModuleMinimumWidth: CGFloat {
        let reimbursement = compactReimbursementWidths.spine + compactReimbursementWidths.detail + compactReimbursementWidths.inspector + 2
        let ai = compactAIWidths.spine + compactAIWidths.detail + compactAIWidths.inspector + 2
        let statement = compactStatementImportWidths.evidence + compactStatementImportWidths.rows + compactStatementImportWidths.inspector + 2
        let installment = compactInstallmentWidths.spine + compactInstallmentWidths.schedule + compactInstallmentWidths.inspector + 2
        return max(reimbursement, ai, statement, installment)
    }
}

/// The supported iPhone canvas is intentionally narrow and portrait-only.
/// These values are data, not one-off view guesses, so Gallery and unit tests
/// can keep every screen honest as the shared UI evolves.
public enum V15IOSLayout {
    public static let compactWidth: CGFloat = 375
    public static let regularWidth: CGFloat = 393
    public static let largeWidth: CGFloat = 430
    public static let contentPadding: CGFloat = 16
    public static let compactContentPadding: CGFloat = 14
    public static let bottomBarMinimumHeight: CGFloat = 72
    public static let floatingActionDiameter: CGFloat = 58
    /// Keeps the last scrollable action above the centre floating record button.
    public static let floatingActionContentClearance: CGFloat = 16
    public static let cardCornerRadius: CGFloat = 18

    public static func contentPadding(for width: CGFloat) -> CGFloat {
        width <= compactWidth ? compactContentPadding : contentPadding
    }
}

#if os(macOS)
public extension View {
    /// Gives standalone macOS pages a stable desktop canvas without affecting
    /// their iOS counterpart. The page itself remains responsible for its
    /// columns; it no longer needs a hard coded centred max width.
    func v15MacWorkspaceCanvas() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(V15Palette.paper.color)
    }

    func v15MacPanel() -> some View {
        self
            .background(V15Palette.surfaceRaised.color, in: RoundedRectangle(cornerRadius: V15Radius.card))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.card).stroke(V15Palette.hairline.color.opacity(0.9), lineWidth: 1) }
    }
}
#else
// Several feature files are compiled into both platform frameworks even when
// their live route is macOS-only. Keep the desktop visual modifiers as no-ops
// on iOS so this upgrade cannot alter its existing information architecture.
public extension View {
    func v15MacWorkspaceCanvas() -> some View { self }
    func v15MacPanel() -> some View { self }
}
#endif

#if os(iOS)
private struct V15IOSCardModifier: ViewModifier {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                selected ? V15Palette.selected.color : V15Palette.surfaceRaised.color,
                in: RoundedRectangle(cornerRadius: V15IOSLayout.cardCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: V15IOSLayout.cardCornerRadius, style: .continuous)
                    .stroke(selected ? V15Palette.teal.color.opacity(0.34) : V15Palette.hairline.color.opacity(0.82), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: colorScheme == .light ? Color.black.opacity(0.045) : .clear,
                radius: 12,
                y: 5
            )
    }
}

public extension View {
    func v15IOSScreenCanvas() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(V15Palette.canvas.color.ignoresSafeArea())
    }

    func v15IOSCard(selected: Bool = false) -> some View {
        modifier(V15IOSCardModifier(selected: selected))
    }
}
#else
public extension View {
    func v15IOSScreenCanvas() -> some View { self }
    func v15IOSCard(selected: Bool = false) -> some View { self }
}
#endif

public enum V15Symbol {
    /// SF Symbols only. A symbol describes the action/object, while the nearby
    /// text supplies its financial meaning; never use an emoji as a status icon.
    public static let retry = "arrow.clockwise"
    public static let offline = "wifi.slash"
    public static let conflict = "arrow.triangle.2.circlepath"
    public static let archive = "archivebox"
    public static let receipt = "checkmark.circle.fill"
    public static let warning = "exclamationmark.circle"
    public static let search = "magnifyingglass"
}

public enum V15MoneyDirection: Sendable, Equatable {
    case inflow
    case outflow
    case balance
    case neutral
}

public struct V15MoneyPresentation: Sendable, Equatable {
    public let text: String
    public let direction: V15MoneyDirection
    public let isTabular: Bool
    public let neverWraps: Bool

    public init(minorUnits: Int64, direction: V15MoneyDirection, includeCurrency: Bool = true) {
        self.direction = direction
        self.isTabular = true
        self.neverWraps = true
        let absolute = minorUnits == Int64.min ? UInt64(Int64.max) + 1 : UInt64(Swift.abs(minorUnits))
        let whole = absolute / 100
        let fraction = absolute % 100
        let number = "\(Self.grouped(whole)).\(String(format: "%02llu", fraction))"
        let sign: String
        switch direction {
        case .inflow: sign = "+"
        case .outflow: sign = "−"
        case .balance, .neutral: sign = ""
        }
        text = "\(sign)\(includeCurrency ? "¥" : "")\(number)"
    }

    private static func grouped(_ value: UInt64) -> String {
        let digits = String(value)
        var end = digits.endIndex
        var chunks: [String] = []
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            chunks.append(String(digits[start..<end]))
            end = start
        }
        return chunks.reversed().joined(separator: ",")
    }
}

/// Keeps a local optimistic amount visibly separate from the last value
/// confirmed by the server. A pending value is never presented as ledger fact.
public struct V15MoneyTruthPresentation: Sendable, Equatable {
    public let displayed: V15MoneyPresentation
    public let confirmed: V15MoneyPresentation
    public let pendingCount: Int

    public init(displayedMinorUnits: Int64, confirmedMinorUnits: Int64, pendingCount: Int, direction: V15MoneyDirection, includeCurrency: Bool = true) {
        displayed = .init(minorUnits: displayedMinorUnits, direction: direction, includeCurrency: includeCurrency)
        confirmed = .init(minorUnits: confirmedMinorUnits, direction: direction, includeCurrency: includeCurrency)
        self.pendingCount = max(0, pendingCount)
    }

    public var hasPendingValue: Bool { pendingCount > 0 }
    public var pendingLabel: String? { hasPendingValue ? "含 \(pendingCount) 项未同步" : nil }
}

public struct V15MoneyText: View {
    private let presentation: V15MoneyPresentation
    private let font: Font

    public init(minorUnits: Int64, direction: V15MoneyDirection, includeCurrency: Bool = true, font: Font = V15Typography.money) {
        presentation = .init(minorUnits: minorUnits, direction: direction, includeCurrency: includeCurrency)
        self.font = font
    }

    public var body: some View {
        Text(presentation.text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
#if os(iOS)
            .minimumScaleFactor(0.68)
            .allowsTightening(true)
#else
            .fixedSize(horizontal: true, vertical: false)
#endif
            .accessibilityLabel(accessibilityText)
    }

    private var color: Color {
        switch presentation.direction {
        case .inflow: V15Palette.teal.color
        case .outflow: V15Palette.gold.color
        case .balance: V15Palette.ink.color
        case .neutral: V15Palette.ink.color.opacity(0.66)
        }
    }

    private var accessibilityText: String {
        switch presentation.direction {
        case .inflow: "流入 \(presentation.text)"
        case .outflow: "流出 \(presentation.text)"
        case .balance: "余额 \(presentation.text)"
        case .neutral: presentation.text
        }
    }
}

public extension Color {
    init(v15Light light: UInt, dark: UInt) {
#if os(iOS)
        self.init(uiColor: UIColor { traits in
            UIColor(v15Hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
#elseif os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(v15Hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
#else
        self.init(.sRGB, red: Double((light >> 16) & 0xFF) / 255, green: Double((light >> 8) & 0xFF) / 255, blue: Double(light & 0xFF) / 255, opacity: 1)
#endif
    }
}

#if os(iOS)
private extension UIColor {
    convenience init(v15Hex value: UInt) {
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
#elseif os(macOS)
private extension NSColor {
    convenience init(v15Hex value: UInt) {
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
#endif
