import SwiftUI
import Charts

/// Shared page grammar for the native workspaces and their secondary flows.
/// The business views keep ownership of commands, validation and navigation.
public struct V22PageHeader: View {
    private let title: String
    private let symbol: String
    private let subtitle: String?

    public init(_ title: String, symbol: String, subtitle: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(V15Palette.teal.color)
                .frame(width: 44, height: 44)
                .background(V15Palette.selected.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(V15Palette.ink.color)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(V15Typography.secondary)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.64))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}

public struct V22FormSection<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let content: Content

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(V15Typography.cardTitle.weight(.semibold))
                    .foregroundStyle(V15Palette.ink.color)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(V15Typography.secondary)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .v22FormSurface()
    }
}

public struct V22FlowProgress: View {
    private let steps: [String]
    private let current: Int

    public init(_ steps: [String], current: Int) {
        self.steps = steps
        self.current = current
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                VStack(alignment: .leading, spacing: 8) {
                    Capsule()
                        .fill(index <= current ? V15Palette.teal.color : V15Palette.hairline.color)
                        .frame(height: 3)
                    Text("\(index + 1)  \(title)")
                        .font(V15Typography.secondary.weight(index == current ? .semibold : .regular))
                        .foregroundStyle(V15Palette.ink.color.opacity(index == current ? 1 : 0.56))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(steps.indices.contains(current) ? "第 \(current + 1) 步，共 \(steps.count) 步：\(steps[current])" : "")
    }
}

public struct V22Metric: View {
    private let title: String
    private let minorUnits: Int64?
    private let direction: V15MoneyDirection

    public init(_ title: String, minorUnits: Int64?, direction: V15MoneyDirection = .balance) {
        self.title = title
        self.minorUnits = minorUnits
        self.direction = direction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.62))
            V15MoneyText(minorUnits: minorUnits, direction: direction, font: .title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Plots only the daily amounts provided by the selected report. A bar is an
/// observed day, so absent days are never filled by a decorative curve.
public struct V22SpendingTrend: View {
    public struct Point: Identifiable {
        public var id: String { date }
        public let date: String
        public let amountMinor: Int64

        public init(date: String, amountMinor: Int64) {
            self.date = date
            self.amountMinor = amountMinor
        }
    }

    private let points: [Point]
    private let title: String
    private let height: CGFloat

    public init(points: [Point], title: String = "每日实际支出", height: CGFloat = 168) {
        self.points = points
        self.title = title
        self.height = height
    }

    private var dateLabels: [String] {
        let step = max(1, points.count / 5)
        return points.enumerated().compactMap { index, point in
            index.isMultiple(of: step) || index == points.count - 1 ? point.date : nil
        }
    }

    public var body: some View {
        if points.isEmpty {
            Text("当前期间暂无每日数据")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.62))
                .padding(.vertical, 8)
                .accessibilityIdentifier("v22.report.daily-empty")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(V15Typography.secondary.weight(.semibold))
                    Spacer()
                    Text("元").font(V15Typography.label)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.52))
                }
                Chart(points) { point in
                    BarMark(
                        x: .value("日期", point.date),
                        y: .value("金额（元）", Double(point.amountMinor) / 100)
                    )
                    .foregroundStyle(V15Palette.teal.color.gradient)
                    .cornerRadius(3)
                    .accessibilityLabel(point.date)
                    .accessibilityValue(V15MoneyPresentation(minorUnits: point.amountMinor, direction: .balance, includeCurrency: true).text)
                }
                .chartXAxis {
                    AxisMarks(values: dateLabels) { value in
                        AxisValueLabel {
                            if let date = value.as(String.self) {
                                Text(String(date.suffix(5))).font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(V15Palette.hairline.color.opacity(0.65))
                        AxisValueLabel()
                    }
                }
                .frame(height: height)
                .accessibilityLabel(title)
                .accessibilityIdentifier("v22.report.daily-trend")
            }
            .padding(.top, 8)
        }
    }
}

#if os(macOS)
import AppKit

/// An AppKit field owns its first responder inside NSPopover. This avoids
/// SwiftUI focus transfer back to the split view while the results change.
private struct V22AccountSearchInput: NSViewRepresentable {
    @Binding var query: String
    let move: (Int) -> Void
    let submit: () -> Void
    let close: () -> Void

    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.isBordered = false
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "搜索账户、机构或尾号"
        field.setAccessibilityIdentifier("v22.account-picker.search")
        field.setAccessibilityLabel("搜索账户、机构或尾号")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: SearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
    }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class SearchField: NSTextField {
        private var didRequestFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { didRequestFocus = false; return }
            guard !didRequestFocus else { return }
            didRequestFocus = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: V22AccountSearchInput
        init(parent: V22AccountSearchInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.query = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.close()
            default: return false
            }
            return true
        }
    }
}

public struct V22AccountPicker: View {
    private let title: String
    private let accounts: [V15AccountResponse]
    private let onSelect: (UUID) -> Void
    private let onManage: () -> Void
    private let onClose: () -> Void
    @State private var query = ""
    @State private var highlightedID: UUID?

    public init(title: String, accounts: [V15AccountResponse], onSelect: @escaping (UUID) -> Void, onManage: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.title = title
        self.accounts = accounts
        self.onSelect = onSelect
        self.onManage = onManage
        self.onClose = onClose
    }

    private var matches: [V15AccountResponse] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return accounts }
        return accounts.filter {
            $0.name.localizedCaseInsensitiveContains(term)
                || ($0.institution?.localizedCaseInsensitiveContains(term) ?? false)
                || ($0.lastFour?.contains(term) ?? false)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(V15Typography.cardTitle)
                Spacer()
                Text("\(accounts.count) 个账户")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.56))
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(V15Palette.ink.color.opacity(0.52))
                V22AccountSearchInput(query: $query, move: moveHighlight, submit: openHighlighted, close: onClose)
                    .frame(height: 20)
            }
            .padding(11)
            .background(V15Palette.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 12))
            Group {
            if matches.isEmpty {
                V15EmptyState(
                    title: accounts.isEmpty ? "还没有账户" : "没有匹配账户",
                    explanation: accounts.isEmpty ? "在账户管理中添加账户。" : "试试账户名称、机构或卡号尾号。"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(matches) { account in
                                accountRow(account).id(account.id)
                            }
                        }
                    }
                    .frame(maxHeight: 310)
                    .onChange(of: highlightedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            }
            // Keep the popover anchor and first responder stable as search
            // moves between populated and empty results.
            .frame(height: CGFloat(min(max(accounts.count, 2) * 64, 310)))
            Divider()
            HStack {
                Text("↑↓ 选择 · 回车打开")
                    .font(V15Typography.label)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.48))
                Spacer()
                Button("管理全部账户", action: onManage)
                    .buttonStyle(.plain).foregroundStyle(V15Palette.teal.color)
                    .accessibilityIdentifier("v22.account-picker.manage")
            }
        }
        .padding(18)
        .frame(width: 370)
        .v22PageCanvas()
        .onAppear { highlightedID = matches.first?.id }
        .onChange(of: query) { _, _ in highlightedID = matches.first?.id }
        .onChange(of: accounts.map(\.id)) { _, _ in
            if !matches.contains(where: { $0.id == highlightedID }) { highlightedID = matches.first?.id }
        }
    }

    private func accountRow(_ account: V15AccountResponse) -> some View {
        Button { onSelect(account.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: account.kind == .credit ? "creditcard" : "building.columns")
                    .foregroundStyle(V15Palette.teal.color)
                    .frame(width: 32, height: 32)
                    .background(V15Palette.selected.color, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.name).font(V15Typography.body.weight(.semibold)).lineLimit(2)
                    Text(accountSubtitle(account))
                        .font(V15Typography.label)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.56)).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(V15MoneyPresentation(minorUnits: account.currentBalanceMinor, direction: direction(account), includeCurrency: true).text)
                    .font(V15Typography.money).monospacedDigit()
                    .foregroundStyle(V15Palette.ink.color)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(highlightedID == account.id ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(highlightedID == account.id ? "已选" : "")
        .accessibilityIdentifier("v152.mac.sidebar.popover.account.\(account.id.uuidString)")
    }

    private func direction(_ account: V15AccountResponse) -> V15MoneyDirection {
        if account.kind == .credit { return account.currentBalanceMinor < 0 ? .neutral : .outflow }
        return .balance
    }

    private func accountSubtitle(_ account: V15AccountResponse) -> String {
        let meaning = account.kind == .credit ? (account.currentBalanceMinor < 0 ? "信用溢缴" : "当前欠款") : "当前余额"
        return [account.institution, account.lastFour.map { "尾号 \($0)" }, meaning]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func moveHighlight(_ offset: Int) {
        let values = matches
        guard !values.isEmpty else { highlightedID = nil; return }
        let current = values.firstIndex(where: { $0.id == highlightedID }) ?? (offset > 0 ? -1 : values.count)
        highlightedID = values[min(max(current + offset, 0), values.count - 1)].id
    }

    private func openHighlighted() {
        guard let id = highlightedID, matches.contains(where: { $0.id == id }) else { return }
        onSelect(id)
    }
}
#endif

extension View {
    public func v22CompactNavigationTitle() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    public func v22PageCanvas() -> some View {
        self
            .font(V15Typography.body)
            .foregroundStyle(V15Palette.ink.color)
            .tint(V15Palette.teal.color)
            .background(V15Palette.paper.color)
    }

    public func v22FormSurface() -> some View {
        self
            .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(V15Palette.hairline.color.opacity(0.65), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
    }
}
