import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum FiscalColor {
    public static let accent = Color(light: 0x2E68D6, dark: 0x6E9BFF)
    public static let accentDark = Color(light: 0x1E52B8, dark: 0x477CE5)
    public static let text = Color(light: 0x1C2026, dark: 0xF2F4F8)
    public static let secondary = Color(light: 0x5C6675, dark: 0xBCC3CE)
    public static let tertiary = Color(light: 0x8A94A3, dark: 0x929CAA)
    public static let income = Color(light: 0x1F9E6A, dark: 0x4BC890)
    public static let expense = Color(light: 0xD24B4E, dark: 0xFF777A)
    public static let debt = Color(light: 0xC2892B, dark: 0xE5AD52)
    public static let reimbursement = Color(light: 0x2E8E93, dark: 0x58BBC0)
    public static let iOSBackground = Color(light: 0xEEF1F6, dark: 0x101318)
    public static let macBackground = Color(light: 0xF4F6F9, dark: 0x15181E)
    public static let surface = Color(light: 0xFFFFFF, dark: 0x20242C)
    public static let separator = Color(light: 0xDDE1E8, dark: 0x353B46)
}

public extension Color {
    init(light: UInt, dark: UInt) {
#if os(iOS)
        self.init(uiColor: UIColor { traits in UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light) })
#elseif os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
#endif
    }

    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

public struct FiscalCard<Content: View>: View {
    private let radius: CGFloat
    @ViewBuilder private let content: Content

    public init(radius: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(18)
            .background(FiscalColor.surface)
            .clipShape(.rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(FiscalColor.separator.opacity(0.72), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color(hex: 0x1E2846).opacity(0.05), radius: 12, y: 5)
    }
}

public struct FiscalIconTile: View {
    let symbol: String
    let color: Color

    public init(_ symbol: String, color: Color) {
        self.symbol = symbol
        self.color = color
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.12), in: .rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

public struct FiscalActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public enum Role { case primary, secondary, destructive }
    private let role: Role
    public init(_ role: Role = .primary) { self.role = role }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 15)
            .frame(minHeight: 42)
            .background(background.opacity(configuration.isPressed ? 0.72 : 1), in: .rect(cornerRadius: 12))
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: 12).stroke(FiscalColor.accent.opacity(0.22), lineWidth: 0.7)
                }
            }
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
    private var foreground: Color { role == .secondary ? FiscalColor.accent : .white }
    private var background: Color {
        switch role {
        case .primary: FiscalColor.accent
        case .secondary: FiscalColor.accent.opacity(0.07)
        case .destructive: FiscalColor.expense
        }
    }
}

public struct FiscalSwitchToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? FiscalColor.income : FiscalColor.tertiary.opacity(0.3))
                    Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }.frame(width: 44, height: 27)
            }.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: configuration.isOn)
        .accessibilityValue(configuration.isOn ? "开启" : "关闭")
    }
}

#if os(iOS)
private extension UIColor {
    convenience init(hex: UInt) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
#elseif os(macOS)
private extension NSColor {
    convenience init(hex: UInt) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
#endif
