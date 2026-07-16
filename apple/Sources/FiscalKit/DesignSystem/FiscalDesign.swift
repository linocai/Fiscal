import SwiftUI

public enum FiscalColor {
    public static let accent = Color(hex: 0x2E68D6)
    public static let accentDark = Color(hex: 0x1E52B8)
    public static let text = Color(hex: 0x1C2026)
    public static let secondary = Color(hex: 0x5C6675)
    public static let tertiary = Color(hex: 0x8A94A3)
    public static let income = Color(hex: 0x1F9E6A)
    public static let expense = Color(hex: 0xD24B4E)
    public static let debt = Color(hex: 0xC2892B)
    public static let reimbursement = Color(hex: 0x2E8E93)
    public static let iOSBackground = Color(hex: 0xEEF1F6)
    public static let macBackground = Color(hex: 0xF4F6F9)
}

public extension Color {
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
            .background(.white)
            .clipShape(.rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(.black.opacity(0.055), lineWidth: 0.5)
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
    }
}

public extension View {
    func fiscalMonospacedNumbers() -> some View { monospacedDigit() }
}

public struct FiscalActionButtonStyle: ButtonStyle {
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
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
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
        .animation(.easeOut(duration: 0.2), value: configuration.isOn)
        .accessibilityValue(configuration.isOn ? "开启" : "关闭")
    }
}
