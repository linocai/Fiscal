import SwiftUI

public enum V15ButtonKind: Sendable, Equatable { case primary, secondary, destructive, quiet }

public struct V15ButtonVisualSpec: Sendable, Equatable {
    public let foreground: V15ColorToken
    public let background: V15ColorToken?
    public let border: V15ColorToken?
    public let foregroundOpacity: Double
    public let backgroundOpacity: Double

    public static func resolve(kind: V15ButtonKind, isEnabled: Bool) -> V15ButtonVisualSpec {
        guard isEnabled else {
            return .init(foreground: V15Palette.ink, background: V15Palette.ink, border: V15Palette.hairline, foregroundOpacity: 0.35, backgroundOpacity: 0.08)
        }
        switch kind {
        case .primary: return .init(foreground: V15Palette.primaryButtonText, background: V15Palette.teal, border: nil, foregroundOpacity: 1, backgroundOpacity: 1)
        case .secondary: return .init(foreground: V15Palette.teal, background: V15Palette.selected, border: V15Palette.teal, foregroundOpacity: 1, backgroundOpacity: 1)
        case .destructive: return .init(foreground: V15Palette.ink, background: V15Palette.provisional, border: V15Palette.gold, foregroundOpacity: 1, backgroundOpacity: 1)
        case .quiet: return .init(foreground: V15Palette.teal, background: nil, border: nil, foregroundOpacity: 1, backgroundOpacity: 1)
        }
    }
}

public struct V15ActionButton: View {
    private let title: String
    private let symbol: String?
    private let kind: V15ButtonKind
    private let disabledReasons: [V15DisabledReason]
    private let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(_ title: String, symbol: String? = nil, kind: V15ButtonKind = .primary, disabledReason: V15DisabledReason? = nil, action: @escaping () -> Void) {
        self.init(title, symbol: symbol, kind: kind, disabledReasons: disabledReason.map { [$0] } ?? [], action: action)
    }

    public init(_ title: String, symbol: String? = nil, kind: V15ButtonKind = .primary, disabledReasons: [V15DisabledReason], action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.kind = kind; self.disabledReasons = disabledReasons; self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Button(action: action) {
                Label { Text(title).multilineTextAlignment(.center) } icon: {
                    if let symbol { Image(systemName: symbol) }
                }
                .frame(maxWidth: kind == .quiet ? nil : .infinity)
            }
            .buttonStyle(V15ButtonStyle(kind: kind, reduceMotion: reduceMotion, dark: colorScheme == .dark))
            .disabled(!disabledReasons.isEmpty)
            .v15KeyboardFocusable()
            .v15ActionAccessibility(label: title, hint: disabledReasons.isEmpty ? nil : disabledReasons.map(V15Accessibility.safeReason).joined(separator: "；"))
            V15DisabledReasonList(reasons: disabledReasons)
        }
    }
}

private struct V15ButtonStyle: ButtonStyle {
    let kind: V15ButtonKind
    let reduceMotion: Bool
    let dark: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(V15Typography.body.weight(.semibold))
            .foregroundStyle(spec.foreground.color.opacity(spec.foregroundOpacity))
            .padding(.horizontal, V15Spacing.md)
            .padding(.vertical, buttonVerticalPadding)
            .frame(minHeight: buttonHeight)
            .background((spec.background?.color ?? .clear).opacity(spec.backgroundOpacity * (configuration.isPressed && isEnabled ? 0.76 : 1)), in: RoundedRectangle(cornerRadius: V15Radius.control))
            .overlay { border }
            .contentShape(RoundedRectangle(cornerRadius: V15Radius.control))
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: V15Motion.pressDuration), value: configuration.isPressed)
    }

    private var spec: V15ButtonVisualSpec { .resolve(kind: kind, isEnabled: isEnabled) }
    private var buttonHeight: CGFloat {
#if os(macOS)
        34
#else
        V15Accessibility.minimumTouchTarget
#endif
    }
    private var buttonVerticalPadding: CGFloat {
#if os(macOS)
        5
#else
        V15Spacing.xs
#endif
    }
    @ViewBuilder private var border: some View {
        if let border = spec.border {
            RoundedRectangle(cornerRadius: V15Radius.control).stroke(border.color.opacity(isEnabled ? 0.40 : 0.35), lineWidth: 1)
        } else {
            EmptyView()
        }
    }
}

private struct V15DisabledReasonList: View {
    let reasons: [V15DisabledReason]
    var body: some View {
        if !reasons.isEmpty {
            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    Text(V15Accessibility.safeReason(reason)).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("不可用原因：\(reasons.map(V15Accessibility.safeReason).joined(separator: "；"))")
        }
    }
}

public struct V15Field: View {
    private let title: String
    private let prompt: String
    @Binding private var text: String
    private let issues: [V15FieldIssue]
    private let axis: Axis

    public init(_ title: String, text: Binding<String>, prompt: String = "", issues: [V15FieldIssue] = [], axis: Axis = .horizontal) {
        self.title = title; _text = text; self.prompt = prompt; self.issues = issues; self.axis = axis
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text(title).font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.ink.color)
            TextField(prompt, text: $text, axis: axis)
                .font(V15Typography.body)
                .textFieldStyle(.plain)
                .padding(V15Spacing.sm)
                .background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
                .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(issues.isEmpty ? V15Palette.hairline.color : V15Palette.teal.color, lineWidth: issues.isEmpty ? 1 : 1.5) }
                .accessibilityLabel(title)
                .accessibilityValue(text)
                .accessibilityHint(issues.isEmpty ? "" : issues.map(\.message).joined(separator: "；"))
            V15FieldIssues(issues: issues)
        }
    }
}

public struct V15FieldIssues: View {
    private let issues: [V15FieldIssue]
    public init(issues: [V15FieldIssue]) { self.issues = issues }
    public var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: V15Symbol.warning)
                        .font(V15Typography.secondary.weight(.medium))
                        .foregroundStyle(V15Palette.teal.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("需要修改：\(issues.map(\.message).joined(separator: "；"))")
        }
    }
}

public struct V15SearchField: View {
    @Binding private var text: String
    public init(text: Binding<String>) { _text = text }
    public var body: some View {
        HStack(spacing: V15Spacing.xs) {
            Image(systemName: V15Symbol.search).accessibilityHidden(true)
            TextField("搜索账目", text: $text)
                .textFieldStyle(.plain)
                .font(V15Typography.body)
        }
        .padding(V15Spacing.sm)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: V15Radius.control))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("搜索账目")
    }
}

public struct V15PickerRow<Selection: Hashable, Content: View>: View {
    private let title: String
    @Binding private var selection: Selection
    private let content: Content
    public init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        self.title = title; _selection = selection; self.content = content()
    }
    public var body: some View {
        Picker(title, selection: $selection) { content }
            .pickerStyle(.menu)
            .font(V15Typography.body)
            .padding(.vertical, V15Spacing.xs)
            .v15PlatformHitArea()
            .accessibilityLabel(title)
    }
}

public struct V15LedgerRow: View {
    public enum Marker: Sendable, Equatable { case ordinary, decision, provisional, archive }
    private let title: String
    private let detail: String
    private let amount: V15MoneyPresentation
    private let marker: Marker
    private let action: (() -> Void)?

    public init(title: String, detail: String, amountMinor: Int64, direction: V15MoneyDirection, marker: Marker = .ordinary, action: (() -> Void)? = nil) {
        self.title = title; self.detail = detail; self.amount = .init(minorUnits: amountMinor, direction: direction, includeCurrency: false); self.marker = marker; self.action = action
    }
    public var body: some View {
        Group {
            if let action { Button(action: action) { row }.buttonStyle(.plain) } else { row }
        }
        .v15PlatformHitArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(markerLabel)，\(title)，\(detail)，\(amount.text)")
        .accessibilityAddTraits(action == nil ? .isStaticText : .isButton)
    }
    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: V15Spacing.sm) {
            markerShape.frame(width: 4, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                Text(title).font(V15Typography.body).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: V15Spacing.sm)
            Text(amount.text).font(V15Typography.money).monospacedDigit().lineLimit(1).fixedSize(horizontal: true, vertical: false).foregroundStyle(amountColor)
        }
        .padding(.horizontal, V15Spacing.md)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: V15Accessibility.macVisibleRowHeight)
        .background(marker == .archive ? V15Palette.card.color.opacity(0.45) : .clear)
    }
    @ViewBuilder private var markerShape: some View {
        switch marker {
        case .ordinary: Color.clear
        case .decision: V15Palette.teal.color
        case .provisional: V15Palette.yellow.color
        case .archive: Rectangle().strokeBorder(V15Palette.ink.color.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
    }
    private var markerLabel: String { switch marker { case .ordinary: "已确认"; case .decision: "需要决定"; case .provisional: "未定"; case .archive: "归档，只读" } }
    private var amountColor: Color { switch amount.direction { case .inflow: V15Palette.teal.color; case .outflow: V15Palette.gold.color; case .balance: V15Palette.ink.color; case .neutral: V15Palette.ink.color.opacity(0.66) } }
    private var verticalPadding: CGFloat {
#if os(macOS)
        4
#else
        V15Spacing.xs
#endif
    }
}

public struct V15Section<Content: View>: View {
    private let title: String; private let detail: String?; private let content: Content
    public init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.detail = detail; self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                Spacer()
                if let detail { Text(detail).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.66)) }
            }
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

public struct V15InspectorAction: View {
    private let title: String
    private let detail: String?
    private let disabledReason: V15DisabledReason?
    private let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    public init(_ title: String, detail: String? = nil, disabledReason: V15DisabledReason? = nil, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.disabledReason = disabledReason; self.action = action
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Button(action: action) {
                HStack(alignment: .top, spacing: V15Spacing.sm) {
                    VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                        Text(title).font(V15Typography.body.weight(.semibold)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        if let detail {
                            Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                        }
                    }
                    Spacer(minLength: V15Spacing.xs)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                }
            }
            .buttonStyle(V15ButtonStyle(kind: .quiet, reduceMotion: reduceMotion, dark: colorScheme == .dark))
            .disabled(disabledReason != nil)
            .v15KeyboardFocusable()
            .v15ActionAccessibility(label: title, hint: disabledReason.map(V15Accessibility.safeReason) ?? detail)
            V15DisabledReasonList(reasons: disabledReason.map { [$0] } ?? [])
        }
    }
}
