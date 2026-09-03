import SwiftUI

public enum V15ButtonKind: Sendable, Equatable { case primary, secondary, destructive, quiet }

public enum V15FieldKeyboard: Sendable, Equatable {
    case standard
    case decimal
    case integer
}

public enum V15InterfaceFamily: Sendable, Equatable {
    case iPhone, mac

    public static var current: Self {
#if os(iOS)
        .iPhone
#else
        .mac
#endif
    }
}

public struct V15ButtonVisualSpec: Sendable, Equatable {
    public let foreground: V15ColorToken
    public let background: V15ColorToken?
    public let border: V15ColorToken?
    public let foregroundOpacity: Double
    public let backgroundOpacity: Double

    public static func resolve(
        kind: V15ButtonKind,
        isEnabled: Bool,
        interface: V15InterfaceFamily = .current
    ) -> V15ButtonVisualSpec {
        guard isEnabled else {
            return .init(foreground: V15Palette.ink, background: V15Palette.ink, border: V15Palette.hairline, foregroundOpacity: 0.35, backgroundOpacity: 0.08)
        }
        switch kind {
        case .primary: return .init(foreground: V15Palette.primaryButtonText, background: V15Palette.teal, border: nil, foregroundOpacity: 1, backgroundOpacity: 1)
        case .secondary:
            return .init(
                foreground: V15Palette.teal,
                background: V15Palette.selected,
                border: interface == .mac ? V15Palette.teal : nil,
                foregroundOpacity: 1,
                backgroundOpacity: 1
            )
        case .destructive:
            return .init(foreground: V15Palette.danger, background: V15Palette.dangerSurface, border: interface == .mac ? V15Palette.danger : nil, foregroundOpacity: 1, backgroundOpacity: 1)
        case .quiet: return .init(foreground: V15Palette.teal, background: nil, border: nil, foregroundOpacity: 1, backgroundOpacity: 1)
        }
    }
}

public struct V15ActionButton: View {
    private let title: String
    private let symbol: String?
    private let kind: V15ButtonKind
    private let disabledReasons: [V15DisabledReason]
    private let showsDisabledReasons: Bool
    private let disabledReasonAccessibilityIdentifier: String?
    private let controlAccessibilityIdentifier: String?
    private let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(_ title: String, symbol: String? = nil, kind: V15ButtonKind = .primary, disabledReason: V15DisabledReason? = nil, showsDisabledReasons: Bool = true, disabledReasonAccessibilityIdentifier: String? = nil, accessibilityIdentifier: String? = nil, action: @escaping () -> Void) {
        self.init(title, symbol: symbol, kind: kind, disabledReasons: disabledReason.map { [$0] } ?? [], showsDisabledReasons: showsDisabledReasons, disabledReasonAccessibilityIdentifier: disabledReasonAccessibilityIdentifier, accessibilityIdentifier: accessibilityIdentifier, action: action)
    }

    public init(_ title: String, symbol: String? = nil, kind: V15ButtonKind = .primary, disabledReasons: [V15DisabledReason], showsDisabledReasons: Bool = true, disabledReasonAccessibilityIdentifier: String? = nil, accessibilityIdentifier: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.kind = kind; self.disabledReasons = disabledReasons; self.showsDisabledReasons = showsDisabledReasons; self.disabledReasonAccessibilityIdentifier = disabledReasonAccessibilityIdentifier; self.controlAccessibilityIdentifier = accessibilityIdentifier; self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Group {
                if let controlAccessibilityIdentifier {
                    actionControl.accessibilityIdentifier(controlAccessibilityIdentifier)
                } else {
                    actionControl
                }
            }
            if showsDisabledReasons {
                if let disabledReasonAccessibilityIdentifier {
                    V15DisabledReasonList(reasons: disabledReasons)
                        .accessibilityIdentifier(disabledReasonAccessibilityIdentifier)
                } else {
                    V15DisabledReasonList(reasons: disabledReasons)
                }
            }
        }
    }

    private var actionControl: some View {
        Button(action: action) {
            Label { Text(title).multilineTextAlignment(.center) } icon: {
                if let symbol { Image(systemName: symbol) }
            }
            // A desktop action is an action, not a full-width row. iOS keeps
            // its larger target and full-width affordance where appropriate.
            .frame(maxWidth: buttonExpands ? .infinity : nil)
        }
        .buttonStyle(V15ButtonStyle(kind: kind, reduceMotion: reduceMotion, dark: colorScheme == .dark))
        .disabled(!disabledReasons.isEmpty)
        .v15KeyboardFocusable()
        .v15ActionAccessibility(label: title, hint: disabledReasons.isEmpty ? nil : disabledReasons.map(V15Accessibility.safeReason).joined(separator: "；"))
    }

    private var buttonExpands: Bool {
#if os(macOS)
        false
#else
        kind != .quiet
#endif
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
    private let keyboard: V15FieldKeyboard

    public init(_ title: String, text: Binding<String>, prompt: String = "", issues: [V15FieldIssue] = [], axis: Axis = .horizontal, keyboard: V15FieldKeyboard = .standard) {
        self.title = title; _text = text; self.prompt = prompt; self.issues = issues; self.axis = axis; self.keyboard = keyboard
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text(title).font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.ink.color)
            inputField
                .font(V15Typography.body)
                .textFieldStyle(.plain)
                .padding(V15Spacing.sm)
                .background(fieldBackground, in: RoundedRectangle(cornerRadius: V15Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: V15Radius.control)
                        .stroke(issues.isEmpty ? V15Palette.hairline.color : issueColor, lineWidth: issues.isEmpty ? 1 : 1.5)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel(title)
                .accessibilityValue(text)
                .accessibilityHint(issues.isEmpty ? "" : issues.map(\.message).joined(separator: "；"))
            V15FieldIssues(issues: issues)
        }
    }

    @ViewBuilder private var inputField: some View {
#if os(iOS)
        switch keyboard {
        case .standard:
            TextField(prompt, text: $text, axis: axis)
        case .decimal:
            TextField(prompt, text: $text, axis: axis).keyboardType(.decimalPad)
        case .integer:
            TextField(prompt, text: $text, axis: axis).keyboardType(.numberPad)
        }
#else
        TextField(prompt, text: $text, axis: axis)
#endif
    }

    private var issueColor: Color { V15Palette.danger.color }
    private var fieldBackground: Color {
#if os(iOS)
        V15Palette.surfaceRaised.color
#else
        V15Palette.paper.color
#endif
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
                        .foregroundStyle(issueColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("需要修改：\(issues.map(\.message).joined(separator: "；"))")
        }
    }

    private var issueColor: Color { V15Palette.danger.color }
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
        .background(V15Palette.surfaceRaised.color, in: RoundedRectangle(cornerRadius: V15Radius.control, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.control, style: .continuous).stroke(V15Palette.hairline.color.opacity(0.82), lineWidth: 1) }
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
            .padding(.horizontal, pickerHorizontalPadding)
            .padding(.vertical, V15Spacing.xs)
            .background(pickerBackground, in: RoundedRectangle(cornerRadius: V15Radius.control, style: .continuous))
            .v15PlatformHitArea()
            .accessibilityLabel(title)
    }

    private var pickerHorizontalPadding: CGFloat {
#if os(iOS)
        V15Spacing.sm
#else
        0
#endif
    }

    private var pickerBackground: Color {
#if os(iOS)
        V15Palette.card.color
#else
        .clear
#endif
    }
}

public struct V15LedgerRow: View {
    public enum Marker: Sendable, Equatable { case ordinary, decision, provisional, archive }
    private let title: String
    private let detail: String
    private let amountMinor: Int64
    private let amount: V15MoneyPresentation
    private let marker: Marker
    private let action: (() -> Void)?

    public init(title: String, detail: String, amountMinor: Int64, direction: V15MoneyDirection, marker: Marker = .ordinary, action: (() -> Void)? = nil) {
        self.title = title; self.detail = detail; self.amountMinor = amountMinor; self.amount = .init(minorUnits: amountMinor, direction: direction, includeCurrency: false); self.marker = marker; self.action = action
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder private var row: some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: V15Spacing.sm) {
                markerShape.frame(width: 4, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: V15Spacing.xs) {
                    metadata
                    V15MoneyText(minorUnits: amountMinor, direction: amount.direction, includeCurrency: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, V15Spacing.md)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: V15Accessibility.macVisibleRowHeight)
            .background(marker == .archive ? V15Palette.card.color.opacity(0.45) : .clear)
        } else {
            compactRow
        }
    }

    private var compactRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: V15Spacing.sm) {
            markerShape.frame(width: 4, height: 24).accessibilityHidden(true)
            metadata
            Spacer(minLength: V15Spacing.sm)
            Text(amount.text).font(V15Typography.money).monospacedDigit().lineLimit(1).fixedSize(horizontal: true, vertical: false).foregroundStyle(amountColor)
        }
        .padding(.horizontal, V15Spacing.md)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: V15Accessibility.macVisibleRowHeight)
        .background(marker == .archive ? V15Palette.card.color.opacity(0.45) : .clear)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Text(title).font(V15Typography.body).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
        }
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
#if os(iOS)
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                Spacer()
                if let detail { Text(detail).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.54)) }
            }
            VStack(alignment: .leading, spacing: V15Spacing.sm) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(V15Spacing.md)
                .v15IOSCard()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
#else
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
#endif
    }
}

public struct V15InspectorAction: View {
    private let title: String
    private let detail: String?
    private let kind: V15ButtonKind
    private let disabledReason: V15DisabledReason?
    private let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    public init(_ title: String, detail: String? = nil, kind: V15ButtonKind = .quiet, disabledReason: V15DisabledReason? = nil, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.kind = kind; self.disabledReason = disabledReason; self.action = action
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(V15ButtonStyle(kind: kind, reduceMotion: reduceMotion, dark: colorScheme == .dark))
            .disabled(disabledReason != nil)
            .v15KeyboardFocusable()
            .v15ActionAccessibility(label: title, hint: disabledReason.map(V15Accessibility.safeReason) ?? detail)
            V15DisabledReasonList(reasons: disabledReason.map { [$0] } ?? [])
        }
    }
}
