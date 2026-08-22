import SwiftUI

public enum V15Accessibility {
    public static let minimumTouchTarget: CGFloat = 44
    public static let macVisibleRowHeight: CGFloat = 28
    public static let macHitInset: CGFloat = 4

    /// The documented AX5 yielding order; features use this rather than
    /// shrinking or truncating money.
    public static let largeTextYieldOrder = [
        "元信息换行",
        "按钮转纵向",
        "固定高度改为最小高度",
        "图标改为顶对齐",
        "金额不缩小、不换行、不截断"
    ]

    public static func safeReason(_ reason: V15DisabledReason?) -> String {
        guard let message = reason?.message.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return "此操作当前不可用，请检查所需信息后再试。"
        }
        return message
    }
}

public enum V15AccessibilityCopy {
    public static let retry = "重试"
    public static let reload = "取最新数据重新决定"
    public static let restore = "恢复归档项"
}

public enum V15StateAccessibilityBehavior: Sendable, Equatable {
    case combinesStaticText
    case containsInteractiveChildren
}

public enum V15StateAccessibilityPolicy {
    public static func behavior(hasAction: Bool) -> V15StateAccessibilityBehavior {
        hasAction ? .containsInteractiveChildren : .combinesStaticText
    }
}

public extension View {
    func v15ActionAccessibility(label: String, hint: String? = nil) -> some View {
        accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
    }

    func v15CustomAction(_ name: String, action: @escaping () -> Void) -> some View {
        accessibilityAction(named: Text(name), action)
    }

    @ViewBuilder func v15StateAccessibility(hasAction: Bool, label: String? = nil) -> some View {
        if hasAction {
            if let label { accessibilityElement(children: .contain).accessibilityLabel(label) }
            else { accessibilityElement(children: .contain) }
        } else {
            if let label { accessibilityElement(children: .combine).accessibilityLabel(label) }
            else { accessibilityElement(children: .combine) }
        }
    }

    /// A compact macOS row still exposes the required 28px visual rhythm and
    /// an additional 4px vertical hit region.
    @ViewBuilder func v15PlatformHitArea() -> some View {
#if os(iOS)
        frame(minHeight: V15Accessibility.minimumTouchTarget)
#elseif os(macOS)
        padding(.vertical, V15Accessibility.macHitInset)
            .frame(minHeight: V15Accessibility.macVisibleRowHeight + V15Accessibility.macHitInset * 2)
#else
        self
#endif
    }
}

#if os(macOS)
private struct V15KeyboardFocusModifier: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: V15Radius.control)
                    .stroke(V15Palette.teal.color, lineWidth: focused ? 2 : 0)
                    .allowsHitTesting(false)
            }
    }
}
public extension View {
    func v15KeyboardFocusable() -> some View { modifier(V15KeyboardFocusModifier()) }
}
#else
public extension View {
    func v15KeyboardFocusable() -> some View { self }
}
#endif
