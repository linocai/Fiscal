import SwiftUI

public enum V15StateCopy {
    public static let unknownReason = "当前状态无法继续此操作，请检查所需信息后再试。"
    public static let preview = "预览 · 尚未提交"
    public static let archive = "归档 · 只读"
    public static let conflict = "服务器数据已变化 · 本次预览已作废，未做任何修改。"
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
        HStack(alignment: .top, spacing: V15Spacing.sm) {
            RoundedRectangle(cornerRadius: 2).fill(marker).frame(width: 4).accessibilityHidden(true)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(V15Spacing.md)
        .background(background, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: V15Radius.control, topTrailingRadius: V15Radius.control))
        .overlay { UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: V15Radius.control, topTrailingRadius: V15Radius.control).stroke(marker.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])) }
    }
}

public struct V15LoadingSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            RoundedRectangle(cornerRadius: 4).fill(V15Palette.ink.color.opacity(0.10)).frame(width: 128, height: 18)
            RoundedRectangle(cornerRadius: 4).fill(V15Palette.ink.color.opacity(0.07)).frame(maxWidth: .infinity).frame(height: 14)
            RoundedRectangle(cornerRadius: 4).fill(V15Palette.ink.color.opacity(0.07)).frame(width: 180, height: 14)
        }
        .padding(V15Spacing.md)
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载")
        .accessibilityAddTraits(.updatesFrequently)
        .animation(reduceMotion ? nil : V15Motion.standard, value: reduceMotion)
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

public struct V15ServiceErrorState: View {
    private let message: String; private let retryIdentifier: String?; private let retry: () -> Void
    public init(message: String, retryIdentifier: String? = nil, retry: @escaping () -> Void) { self.message = message; self.retryIdentifier = retryIdentifier; self.retry = retry }
    public var body: some View {
        V15StateContainer(marker: V15Palette.teal.color, background: V15Palette.selected.color) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Label("暂时无法取得数据", systemImage: V15Symbol.warning).font(V15Typography.cardTitle).foregroundStyle(V15Palette.teal.color)
                Text(message).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                if let retryIdentifier { V15ActionButton("重试", symbol: V15Symbol.retry, action: retry).accessibilityIdentifier(retryIdentifier) }
                else { V15ActionButton("重试", symbol: V15Symbol.retry, action: retry) }
            }
        }.v15StateAccessibility(hasAction: true)
    }
}

public struct V15OfflineReadOnlyBanner: View {
    private let snapshotAt: Date
    public init(snapshotAt: Date) { self.snapshotAt = snapshotAt }
    public var body: some View {
        V15StateContainer(marker: V15Palette.yellow.color, background: V15Palette.provisional.color, dashed: true) {
            VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                Label("离线 · 只读", systemImage: V15Symbol.offline).font(V15Typography.secondary.weight(.semibold))
                Text("显示 \(snapshotLabel) 的快照；无法提交更改。").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            }
        }.v15StateAccessibility(hasAction: false)
    }
    public static func snapshotLabel(for date: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_Hans_CN"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy年M月d日 HH:mm"; return formatter.string(from: date) }
    private var snapshotLabel: String { Self.snapshotLabel(for: snapshotAt) }
}

public struct V15ConflictState: View {
    private let conflict: V15Conflict; private let reload: () -> Void
    public init(conflict: V15Conflict, reload: @escaping () -> Void) { self.conflict = conflict; self.reload = reload }
    public var body: some View {
        V15StateContainer(marker: V15Palette.teal.color, background: V15Palette.selected.color) {
            VStack(alignment: .leading, spacing: V15Spacing.xs) {
                Text("服务器数据已变化").font(V15Typography.cardTitle).foregroundStyle(V15Palette.teal.color)
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                V15ActionButton("取最新数据重新决定", symbol: V15Symbol.conflict, action: reload)
            }
        }.v15StateAccessibility(hasAction: true, label: "版本冲突。\(detail)")
    }
    private var detail: String {
        let versions: String
        if let expected = conflict.expectedVersion, let current = conflict.currentVersion { versions = "你看到的是 v\(expected)，服务器现在是 v\(current)。" } else { versions = "" }
        return "\(versions)\(V15StateCopy.conflict)"
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
        }.v15StateAccessibility(hasAction: true, label: "\(V15StateCopy.preview)。预览结果不是已确认事实。")
    }
}

public struct V15ArchiveReadOnlyState<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(V15Spacing.md)
            .background(V15ArchiveHatch().clipShape(RoundedRectangle(cornerRadius: V15Radius.control)))
            .overlay { RoundedRectangle(cornerRadius: V15Radius.control).stroke(V15Palette.hairline.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            .overlay(alignment: .topTrailing) { Text(V15StateCopy.archive).font(V15Typography.label).padding(.horizontal, V15Spacing.xs).padding(.vertical, V15Spacing.xxs).background(V15Palette.ink.color.opacity(0.10), in: RoundedRectangle(cornerRadius: V15Radius.tag)) }
            .v15StateAccessibility(hasAction: false, label: "归档，只读。历史已保留。")
    }
}

private struct V15ArchiveHatch: View {
    var body: some View {
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
