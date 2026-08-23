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

/// Fiscal v1.5 has three visual signals only: confirmed facts, a required
/// decision, and a provisional result. Do not add feature-specific colors.
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
    public static let receipt = selected
    public static let primaryButtonText = V15ColorToken(lightHex: 0xFFFFFF, darkHex: 0x08201F)
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
    public static let surfaceTitle = Font.system(.title, design: .default, weight: .bold)
    public static let cardTitle = Font.system(.title3, design: .default, weight: .semibold)
    public static let body = Font.system(.body, design: .default, weight: .regular)
    public static let secondary = Font.system(.callout, design: .default, weight: .regular)
    public static let label = Font.system(.caption2, design: .default, weight: .semibold)
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
            .fixedSize(horizontal: true, vertical: false)
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
