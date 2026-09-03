import SwiftUI

public enum V15StateCopy {
    public static let unknownReason = "当前状态无法继续此操作，请检查所需信息后再试。"
    public static let preview = "预览 · 尚未提交"
    public static let archive = "归档 · 只读"
    public static let displayOnly = "暂时无法识别 · 仅供查看"
    public static let conflict = "数据已更新 · 本次预览已作废，未做任何修改。"
}

public enum V15PresentationStatus: Sendable, Equatable {
    case loading, empty, serviceError, fieldInvalid, disabled, offlineReadOnly, conflict, preview, archiveReadOnly, successReceipt, partialProgress, unknown
    public init(serverStatus: String) {
        switch serverStatus {
        case "loading": self = .loading
        case "empty": self = .empty
        case "service_error": self = .serviceError
        case "field_invalid": self = .fieldInvalid
        case "disabled": self = .disabled
        case "offline_read_only": self = .offlineReadOnly
        case "conflict": self = .conflict
        case "preview": self = .preview
        case "archive_read_only": self = .archiveReadOnly
        case "success_receipt": self = .successReceipt
        case "partial_progress": self = .partialProgress
        default: self = .unknown
        }
    }
    public var safeLabel: String { self == .unknown ? "当前状态无法识别，请重新加载后再试。" : "" }
}

private struct V15StateContainer<Content: View>: View {
    let marker: Color
    let background: Color
    let dashed: Bool
    let content: Content
    init(marker: Color, background: Color, dashed: Bool = false, @ViewBuilder content: () -> Content) { self.marker = marker; self.background = background; self.dashed = dashed; self.content = content() }
    var body: some View {
#if os(iOS)
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            HStack(spacing: V15Spacing.xs) {
                Circle().fill(marker).frame(width: 8, height: 8)
                Rectangle().fill(marker.opacity(0.34)).frame(maxWidth: .infinity).frame(height: 1)
            }
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(V15Spacing.md)
        .background(background, in: RoundedRectangle(cornerRadius: V15IOSLayout.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: V15IOSLayout.cardCornerRadius, style: .continuous)
                .stroke(marker.opacity(0.52), style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : []))
        }
#else
        HStack(alignment: .top, spacing: V15Spacing.sm) {
            RoundedRectangle(cornerRadius: 2).fill(marker).frame(width: 4).accessibilityHidden(true)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(V15Spacing.md)
        .background(background, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: V15Radius.control, topTrailingRadius: V15Radius.control))
        .overlay { UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: V15Radius.control, topTrailingRadius: V15Radius.control).stroke(marker.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])) }
#endif
    }
}

public enum V15SkeletonLayout: Sendable, Equatable {
    case compact
    case decisionCard
    case list(rows: Int)
    case inspector
}

public struct V15LoadingSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let layout: V15SkeletonLayout

    public init(layout: V15SkeletonLayout = .compact) { self.layout = layout }

    public var body: some View {
        geometry
        .padding(V15Spacing.md)
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载")
        .accessibilityAddTraits(.updatesFrequently)
        .animation(reduceMotion ? nil : V15Motion.standard, value: reduceMotion)
    }

    @ViewBuilder private var geometry: some View {
        switch layout {
        case .compact:
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                bar(width: 128, height: 18, strong: true)
                flexibleBar(height: 14)
                bar(width: 180, height: 14)
            }
        case .decisionCard:
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        bar(width: 82, height: 11, strong: true)
                        bar(width: 210, height: 22, strong: true)
                    }
                    Spacer(minLength: V15Spacing.sm)
                    bar(width: 96, height: 22, strong: true)
                }
                flexibleBar(height: 15)
                bar(width: 240, height: 15)
                HStack { flexibleBar(height: 44); flexibleBar(height: 44) }
            }
        case .list(let requestedRows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<max(1, requestedRows), id: \.self) { index in
                    HStack(spacing: V15Spacing.sm) {
                        bar(width: 42, height: 13)
                        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                            flexibleBar(height: 15, strong: index == 0)
                            bar(width: 170, height: 12)
                        }
                        bar(width: 78, height: 15, strong: true)
                    }
                    .padding(.vertical, V15Spacing.sm)
                    if index < max(1, requestedRows) - 1 { Rectangle().fill(V15Palette.hairline.color).frame(height: 1) }
                }
            }
        case .inspector:
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                bar(width: 118, height: 22, strong: true)
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                        bar(width: 74, height: 11)
                        flexibleBar(height: 16)
                    }
                }
                flexibleBar(height: 44)
            }
        }
    }

    private func bar(width: CGFloat, height: CGFloat, strong: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(V15Palette.ink.color.opacity(strong ? 0.10 : 0.07))
            .frame(width: width, height: height)
    }

    private func flexibleBar(height: CGFloat, strong: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(V15Palette.ink.color.opacity(strong ? 0.10 : 0.07))
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

public struct V15EmptyState: View {
    private let title: String; private let explanation: String; private let actionTitle: String?; private let action: (() -> Void)?
    public init(title: String, explanation: String, actionTitle: String? = nil, action: (() -> Void)? = nil) { self.title = title; self.explanation = explanation; self.actionTitle = actionTitle; self.action = action }
    public var body: some View {
        VStack(spacing: V15Spacing.sm) {
            Image(systemName: "tray").font(.title2).foregroundStyle(V15Palette.ink.color.opacity(0.66)).accessibilityHidden(true)
            Text(title).font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color).multilineTextAlignment(.center)
            Text(explanation).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action { V15ActionButton(actionTitle, action: action) }
        }
        .frame(maxWidth: .infinity).padding(V15Spacing.xl)
        .v15StateAccessibility(hasAction: action != nil)
    }
}

public enum V15StateSemantic: Sendable, Equatable {
    case deterministicFailure
    case outcomeUnknown
}

/// A testable semantic contract for state colors. A response-unknown write is
/// not a confirmed failure: it must remain visually recoverable and distinct
/// from service errors even when a feature model temporarily stores it inside
/// a generic failure phase.
public struct V15StateVisualSpec: Sendable, Equatable {
    public let semantic: V15StateSemantic
    public let marker: V15ColorToken
    public let background: V15ColorToken
    public let dashed: Bool

    public static var deterministicFailure: Self {
        .init(semantic: .deterministicFailure, marker: V15Palette.danger, background: V15Palette.dangerSurface, dashed: false)
    }

    public static let outcomeUnknown = Self(
        semantic: .outcomeUnknown,
        marker: V15Palette.yellow,
        background: V15Palette.provisional,
        dashed: true
    )

    public static func resolve(_ failure: V15Failure) -> Self {
        failure.kind == .responseUnknown ? .outcomeUnknown : .deterministicFailure
    }
}

public struct V15ServiceErrorState: View {
    private let message: String; private let retryIdentifier: String?; private let retry: () -> Void
    public init(message: String, retryIdentifier: String? = nil, retry: @escaping () -> Void) { self.message = message; self.retryIdentifier = retryIdentifier; self.retry = retry }
    public var body: some View {
        let spec = V15StateVisualSpec.deterministicFailure
        V15StateContainer(marker: spec.marker.color, background: spec.background.color, dashed: spec.dashed) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Label("暂时无法取得数据", systemImage: V15Symbol.warning).font(V15Typography.cardTitle).foregroundStyle(spec.marker.color)
                Text(message).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                if let retryIdentifier { V15ActionButton("重试", symbol: V15Symbol.retry, action: retry).accessibilityIdentifier(retryIdentifier) }
                else { V15ActionButton("重试", symbol: V15Symbol.retry, action: retry) }
            }
        }.v15StateAccessibility(hasAction: true)
    }
}

/// A deterministic operation failure that cannot be retried from inside the
/// message itself. This keeps failures visually distinct from warnings and
/// response-unknown states without inventing a meaningless retry action.
public struct V15ErrorMessageState: View {
    private let title: String
    private let message: String

    public init(title: String = "操作未完成", message: String) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        let spec = V15StateVisualSpec.deterministicFailure
        V15StateContainer(marker: spec.marker.color, background: spec.background.color, dashed: spec.dashed) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Label(title, systemImage: V15Symbol.warning)
                    .font(V15Typography.cardTitle)
                    .foregroundStyle(spec.marker.color)
                Text(message)
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(message)")
    }
}

public struct V15OutcomeUnknownState: View {
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let actionIdentifier: String?
    private let action: (() -> Void)?

    public init(
        title: String = "操作结果暂时不明",
        message: String,
        actionTitle: String? = nil,
        actionIdentifier: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.actionIdentifier = actionIdentifier
        self.action = action
    }

    public var body: some View {
        let spec = V15StateVisualSpec.outcomeUnknown
        V15StateContainer(marker: spec.marker.color, background: spec.background.color, dashed: spec.dashed) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Label(title, systemImage: V15Symbol.warning)
                    .font(V15Typography.cardTitle)
                    .foregroundStyle(V15Palette.gold.color)
                Text(message)
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    if let actionIdentifier {
                        V15ActionButton(
                            actionTitle,
                            symbol: V15Symbol.retry,
                            kind: .secondary,
                            accessibilityIdentifier: actionIdentifier,
                            action: action
                        )
                    } else {
                        V15ActionButton(actionTitle, symbol: V15Symbol.retry, kind: .secondary, action: action)
                    }
                }
            }
        }
        .v15StateAccessibility(hasAction: action != nil, label: "\(title)。\(message)")
    }
}

public struct V15OfflineReadOnlyBanner: View {
    private let snapshotAt: Date
    private let pendingCount: Int
    public init(snapshotAt: Date, pendingCount: Int = 0) { self.snapshotAt = snapshotAt; self.pendingCount = max(0, pendingCount) }
    public var body: some View {
        V15StateContainer(marker: V15Palette.yellow.color, background: V15Palette.provisional.color, dashed: true) {
            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                Label(pendingCount > 0 ? "离线 · \(pendingCount) 项待同步" : "离线 · 只读", systemImage: V15Symbol.offline).font(V15Typography.secondary.weight(.semibold))
                Text("显示 \(snapshotLabel) 保存的数据；当前无法提交更改。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }
        }.v15StateAccessibility(hasAction: false)
    }
    public static func snapshotLabel(for date: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_Hans_CN"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy年M月d日 HH:mm"; return formatter.string(from: date) }
    private var snapshotLabel: String { Self.snapshotLabel(for: snapshotAt) }
}

public struct V15ConflictChange: Identifiable, Sendable, Equatable {
    public let id: String
    public let field: String
    public let previousValue: String
    public let currentValue: String

    public init(id: String? = nil, field: String, previousValue: String, currentValue: String) {
        self.id = id ?? field
        self.field = field
        self.previousValue = previousValue
        self.currentValue = currentValue
    }
}

public struct V15ConflictState: View {
    private let conflict: V15Conflict
    private let changes: [V15ConflictChange]
    private let explanation: String?
    private let reload: () -> Void

    public init(conflict: V15Conflict, changes: [V15ConflictChange] = [], explanation: String? = nil, reload: @escaping () -> Void) {
        self.conflict = conflict
        self.changes = changes
        self.explanation = explanation
        self.reload = reload
    }

    public var body: some View {
        V15StateContainer(marker: V15Palette.yellow.color, background: V15Palette.provisional.color, dashed: true) {
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                Text("数据已更新").font(V15Typography.cardTitle).foregroundStyle(V15Palette.gold.color)
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                if !changes.isEmpty {
                    VStack(alignment: .leading, spacing: V15Spacing.sm) {
                        ForEach(changes) { change in comparison(change) }
                    }
                    .padding(V15Spacing.sm)
                    .background(V15Palette.paper.color.opacity(0.72), in: RoundedRectangle(cornerRadius: V15Radius.control))
                    .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color) }
                }
                Text("未做任何修改。取回最新数据后，原预览会作废并重新计算。")
                    .font(V15Typography.secondary.weight(.semibold))
                    .foregroundStyle(V15Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                V15ActionButton("取最新数据重新决定", symbol: V15Symbol.conflict, action: reload)
            }
        }.v15StateAccessibility(hasAction: true, label: accessibilitySummary)
    }

    private var detail: String {
        let versions: String
        if conflict.expectedVersion != nil, conflict.currentVersion != nil { versions = "你看到的内容已经更新。" } else { versions = "" }
        return "\(versions)\(explanation ?? V15StateCopy.conflict)"
    }

    private func comparison(_ change: V15ConflictChange) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text(change.field).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            V15AdaptiveStack(spacing: V15Spacing.sm) {
                comparisonValue("你看到的值", change.previousValue)
                comparisonValue("最新值", change.currentValue)
            }
        }
    }

    private func comparisonValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Text(label).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.58))
            Text(value).font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilitySummary: String {
        let changesSummary = changes.map { "\($0.field)，原值 \($0.previousValue)，当前值 \($0.currentValue)" }.joined(separator: "；")
        return "数据已更新。\(detail)\(changesSummary.isEmpty ? "" : "；\(changesSummary)")。未做任何修改。"
    }
}

public struct V15PreviewState<Content: View>: View {
    private let version: String?; private let content: Content
    public init(version: String? = nil, @ViewBuilder content: () -> Content) { self.version = version; self.content = content() }
    public var body: some View {
        V15StateContainer(marker: V15Palette.yellow.color, background: V15Palette.provisional.color, dashed: true) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text(version.map { "\(V15StateCopy.preview) · \($0)" } ?? V15StateCopy.preview).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                content
            }
        }.v15StateAccessibility(hasAction: true, label: "\(V15StateCopy.preview)。预览结果尚未确认。")
    }
}

/// A fresh readback is authoritative about the current server record, but it
/// is deliberately not presented as a write preview.  Callers use this when
/// the backend has no preview/token endpoint for the pending decision.
public struct V15ServerFactState: View {
    private let title: String
    private let detail: String

    public init(title: String = "已取得最新数据", detail: String) {
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        V15StateContainer(marker: V15Palette.teal.color, background: V15Palette.selected.color, dashed: false) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text(title).font(V15Typography.label).foregroundStyle(V15Palette.teal.color)
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
            }
        }
        .v15StateAccessibility(hasAction: false, label: "\(title)。\(detail)")
    }
}

/// The backend returned an enum or record the current client intentionally
/// does not interpret. It is visible, readable, and explicitly non-actionable
/// rather than borrowing archive styling.
public struct V15DisplayOnlyState: View {
    private let title: String
    private let detail: String

    public init(title: String = V15StateCopy.displayOnly, detail: String) {
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        V15StateContainer(marker: V15Palette.yellow.color, background: V15Palette.provisional.color, dashed: true) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.72))
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
            }
        }
        .v15StateAccessibility(hasAction: false, label: "\(title)。\(detail)。当前不可操作。")
    }
}

public struct V15ArchiveReadOnlyState<Content: View>: View {
    private let content: Content
    private let restoreTitle: String?
    private let restore: (() -> Void)?

    public init(restoreTitle: String? = nil, restore: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.restoreTitle = restoreTitle
        self.restore = restore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.sm) {
            content
            if let restore {
                V15ActionButton(restoreTitle ?? V15AccessibilityCopy.restore, symbol: V15Symbol.archive, kind: .secondary, action: restore)
            }
        }
            .padding(V15Spacing.md)
            .background(V15ArchiveHatch().clipShape(RoundedRectangle(cornerRadius: V15Radius.control)))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            .overlay(alignment: .topTrailing) { Text(V15StateCopy.archive).font(V15Typography.label).padding(.horizontal, V15Spacing.xs).padding(.vertical, V15Spacing.xxs).background(V15Palette.ink.color.opacity(0.10), in: RoundedRectangle(cornerRadius: V15Radius.tag)) }
            .grayscale(restore == nil ? 0.28 : 0.18)
            .v15StateAccessibility(hasAction: restore != nil, label: "归档，只读。历史已保留。")
    }
}

public struct V15ArchiveHatch: View {
    public init() {}
    public var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(V15Palette.card.color.opacity(0.65)))
            for offset in stride(from: -size.height, through: size.width, by: 10) {
                var line = Path()
                line.move(to: CGPoint(x: offset, y: 0))
                line.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                context.stroke(line, with: .color(V15Palette.ink.color.opacity(0.045)), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

public struct V15MoneyTruthState: View {
    private let title: String
    private let presentation: V15MoneyTruthPresentation
    private let font: Font

    public init(_ title: String, displayedMinorUnits: Int64, confirmedMinorUnits: Int64, pendingCount: Int, direction: V15MoneyDirection = .balance, font: Font = V15Typography.moneyLarge) {
        self.title = title
        presentation = .init(displayedMinorUnits: displayedMinorUnits, confirmedMinorUnits: confirmedMinorUnits, pendingCount: pendingCount, direction: direction)
        self.font = font
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text(title).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            HStack(alignment: .firstTextBaseline, spacing: V15Spacing.sm) {
                V15MoneyTextValue(presentation.displayed, font: font)
                    .overlay(alignment: .bottom) {
                        if presentation.hasPendingValue {
                            Rectangle().stroke(V15Palette.yellow.color, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1).offset(y: 3)
                        }
                    }
                if let pendingLabel = presentation.pendingLabel {
                    Text(pendingLabel).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if presentation.hasPendingValue {
                Text("上次同步值 \(presentation.confirmed.text)")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let pendingLabel = presentation.pendingLabel else { return "\(title)，\(presentation.displayed.text)" }
        return "\(title)，本地显示 \(presentation.displayed.text)，\(pendingLabel)，上次同步值 \(presentation.confirmed.text)"
    }
}

public struct V15ProvisionalMoneyState: View {
    private let title: String
    private let amountMinor: Int64
    private let detail: String

    public init(_ title: String, amountMinor: Int64, detail: String) {
        self.title = title
        self.amountMinor = amountMinor
        self.detail = detail
    }

    public var body: some View {
        V15StateContainer(marker: V15Palette.yellow.color, background: V15Palette.provisional.color, dashed: true) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("\(title) · 尚未发生").font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                V15MoneyText(minorUnits: amountMinor, direction: .neutral, font: V15Typography.moneyLarge)
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .v15StateAccessibility(hasAction: false, label: "\(title)，尚未发生，\(V15MoneyPresentation(minorUnits: amountMinor, direction: .neutral).text)。\(detail)")
    }
}

private struct V15MoneyTextValue: View {
    let presentation: V15MoneyPresentation
    let font: Font
    init(_ presentation: V15MoneyPresentation, font: Font) { self.presentation = presentation; self.font = font }
    var body: some View {
        Text(presentation.text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(presentation.direction == .neutral ? V15Palette.ink.color.opacity(0.66) : V15Palette.ink.color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

public struct V15SuccessReceiptState: View {
    private let title: String; private let detail: String; private let actionTitle: String?; private let action: (() -> Void)?
    public init(title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) { self.title = title; self.detail = detail; self.actionTitle = actionTitle; self.action = action }
    public var body: some View {
        V15StateContainer(marker: V15Palette.teal.color, background: V15Palette.receipt.color) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Label(title, systemImage: V15Symbol.receipt).font(V15Typography.cardTitle).foregroundStyle(V15Palette.teal.color)
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action { V15ActionButton(actionTitle, kind: .secondary, action: action) }
            }
        }.v15StateAccessibility(hasAction: action != nil)
    }
}

public struct V15PartialProgressState: View {
    private let succeeded: String; private let currentState: String; private let remaining: String
    public init(succeeded: String, currentState: String, remaining: String) { self.succeeded = succeeded; self.currentState = currentState; self.remaining = remaining }
    public var body: some View {
        V15StateContainer(marker: V15Palette.teal.color, background: V15Palette.receipt.color) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Label(succeeded, systemImage: V15Symbol.receipt).font(V15Typography.cardTitle).foregroundStyle(V15Palette.teal.color)
                Text("当前状态：\(currentState)\n还剩：\(remaining)").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
            }
        }.v15StateAccessibility(hasAction: false, label: "部分完成。已完成：\(succeeded)。当前状态：\(currentState)。还剩：\(remaining)。")
    }
}
