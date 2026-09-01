import SwiftUI

/// A deterministic, offline-only gallery of the state language shared by the
/// two V15 shells. It is deliberately not a feature route: fixture IDs are
/// stable evidence handles for tests, screenshots, and accessibility review.
public enum V15GalleryFixture: String, CaseIterable, Identifiable, Sendable {
    case loading
    case empty
    case serviceError = "service-error"
    case fieldInvalid = "field-invalid"
    case disabledReasons = "disabled-reasons"
    case offlineReadOnly = "offline-readonly"
    case conflict
    case preview
    case archiveReadOnly = "archive-readonly"
    case successReceipt = "success-receipt"
    case partialProgress = "partial-progress"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .loading: "正在加载"
        case .empty: "没有待处理事项"
        case .serviceError: "读取失败"
        case .fieldInvalid: "填写内容需要修正"
        case .disabledReasons: "暂不能提交"
        case .offlineReadOnly: "离线数据"
        case .conflict: "需要重新决定"
        case .preview: "预览尚未提交"
        case .archiveReadOnly: "归档项"
        case .successReceipt: "已保存"
        case .partialProgress: "部分完成"
        }
    }

    public var accessibilitySummary: String {
        switch self {
        case .loading: "正在加载决策数据"
        case .empty: "没有待处理事项"
        case .serviceError: "暂时无法加载，可以重试"
        case .fieldInvalid: "录入内容有误，需要修正金额"
        case .disabledReasons: "提交不可用，原因已显示"
        case .offlineReadOnly: "离线时只可查看，无法提交更改"
        case .conflict: "数据已变化，需要读取最新内容后重新决定"
        case .preview: "预览尚未提交，确认前不会修改数据"
        case .archiveReadOnly: "归档项只读，可以恢复"
        case .successReceipt: "操作已保存，结果可查看"
        case .partialProgress: "部分完成，仍有剩余项"
        }
    }

    public static func resolve(_ rawValue: String?) -> V15GalleryFixture {
        guard let rawValue else { return .preview }
        return V15GalleryFixture(rawValue: rawValue) ?? .preview
    }
}

public enum V15GalleryDensity: String, Sendable {
    case compact
    case comfortable
}

public struct V15GalleryView: View {
    @State private var selection: V15GalleryFixture
    @State private var retryCount = 0
    @State private var editorShown: Bool
    private let density: V15GalleryDensity
    private let reducesMotion: Bool
    private let reducesTransparency: Bool

    public init(
        fixture: V15GalleryFixture = .preview,
        density: V15GalleryDensity = .comfortable,
        showsFieldErrorSheet: Bool = false,
        reducesMotion: Bool = false,
        reducesTransparency: Bool = false
    ) {
        _selection = State(initialValue: fixture)
        _editorShown = State(initialValue: showsFieldErrorSheet)
        self.density = density
        self.reducesMotion = reducesMotion
        self.reducesTransparency = reducesTransparency
    }

    public var body: some View {
#if os(iOS)
        iOSBody
#elseif os(macOS)
        macOSBody
#else
        EmptyView()
#endif
    }

#if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    V15GalleryIOSHeader(selection: $selection)
                    V15GalleryDecisionCard(fixture: selection, retryCount: retryCount, retry: retry, showEditor: { editorShown = true }, reducesMotion: reducesMotion, reducesTransparency: reducesTransparency)
                    V15GalleryEvidenceNote(fixture: selection)
                }
                .padding(V15Spacing.md)
                .frame(maxWidth: 620, alignment: .leading)
            }
            .background(V15Palette.paper.color)
            .navigationTitle("V15 状态画廊")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(isPresented: $editorShown) {
            V15GalleryFieldErrorSheet()
                .presentationDetents([.medium, .large])
        }
        .accessibilityIdentifier("v15.gallery.ios")
    }
#endif

#if os(macOS)
    private var macOSBody: some View {
        HStack(spacing: 0) {
            V15GalleryMacIndex(selection: $selection, density: density)
                .frame(width: density == .compact ? 226 : 260)
            Divider()
            V15GalleryMacSpine(selection: selection, density: density, retryCount: retryCount, retry: retry, showEditor: { editorShown = true }, reducesMotion: reducesMotion, reducesTransparency: reducesTransparency)
                .frame(minWidth: density == .compact ? 360 : 460, maxWidth: .infinity)
            Divider()
            V15GalleryMacInspector(fixture: selection)
                .frame(width: density == .compact ? 258 : 318)
        }
        .background(V15Palette.paper.color)
        .sheet(isPresented: $editorShown) { V15GalleryFieldErrorSheet().frame(minWidth: 440, minHeight: 360) }
        .accessibilityIdentifier("v15.gallery.macos")
    }
#endif

    private func retry() { retryCount += 1 }
}

private struct V15GalleryIOSHeader: View {
    @Binding var selection: V15GalleryFixture
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text("今日先看需要你决定的事")
                .font(V15Typography.cardTitle)
                .foregroundStyle(V15Palette.ink.color)
            Text("离线示例 · 不连接网络 · 选择一种状态查看它在 iPhone 上的显示效果。")
                .font(V15Typography.secondary)
                .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
            Picker("状态", selection: $selection) {
                ForEach(V15GalleryFixture.allCases) { fixture in Text(fixture.title).tag(fixture) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("v15.gallery.fixture-picker")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct V15GalleryDecisionCard: View {
    let fixture: V15GalleryFixture
    let retryCount: Int
    let retry: () -> Void
    let showEditor: () -> Void
    let reducesMotion: Bool
    let reducesTransparency: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let effectiveReducesMotion = reducesMotion || reduceMotion
        let effectiveReducesTransparency = reducesTransparency || reduceTransparency
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            V15GalleryDecisionHeader(fixture: fixture, dynamicTypeSize: dynamicTypeSize)
            V15GalleryStateSurface(fixture: fixture, retryCount: retryCount, retry: retry, showEditor: showEditor)
                .accessibilitySortPriority(80)
            V15GalleryPagination()
                .accessibilitySortPriority(10)
            if effectiveReducesMotion || effectiveReducesTransparency {
                Text("辅助功能：\(effectiveReducesMotion ? "减少动态效果" : "标准动态效果") · \(effectiveReducesTransparency ? "实色表面" : "标准表面")")
                    .font(V15Typography.secondary)
                    .foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("v15.gallery.rendering-mode")
                    .accessibilityValue("motion=\(effectiveReducesMotion ? "reduced" : "standard");transparency=\(effectiveReducesTransparency ? "reduced" : "standard")")
                    .accessibilitySortPriority(0)
            }
        }
        .padding(V15Spacing.md)
        .background(effectiveReducesTransparency ? V15Palette.card.color : V15Palette.card.color.opacity(0.96), in: RoundedRectangle(cornerRadius: V15Radius.decisionCard))
        .overlay { RoundedRectangle(cornerRadius: V15Radius.decisionCard).stroke(V15Palette.hairline.color, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v15.gallery.decision-card")
        .accessibilityLabel("决策卡。\(fixture.accessibilitySummary)")
        .accessibilityValue("motion=\(effectiveReducesMotion ? "reduced" : "standard");transparency=\(effectiveReducesTransparency ? "reduced" : "standard")")
        .accessibilityHint(effectiveReducesMotion ? "减少动态效果已启用。" : "")
        .transaction { transaction in if effectiveReducesMotion { transaction.animation = nil } }
    }
}

/// iPhone has materially less horizontal room than the card's tabular CNY
/// amount. The wide option is deliberately rejected below 520pt; the fallback
/// keeps a natural title block and moves money to its own right-aligned row.
private struct V15GalleryDecisionHeader: View {
    let fixture: V15GalleryFixture
    let dynamicTypeSize: DynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                wide.frame(minWidth: 520)
                stacked
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xxs) {
            Text("本日决策")
                .font(V15Typography.label)
                .foregroundStyle(V15Palette.teal.color)
            Text(fixture.title)
                .font(V15Typography.cardTitle)
                .foregroundStyle(V15Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .accessibilityIdentifier("v15.gallery.order.title")
                .accessibilitySortPriority(100)
        }
    }

    private var amount: some View {
        V15MoneyText(minorUnits: 9_223_372_036_854_775, direction: .outflow, font: V15Typography.money)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("v15.gallery.order.amount")
            .accessibilitySortPriority(90)
    }

    private var wide: some View {
        HStack(alignment: .center, spacing: V15Spacing.sm) {
            title
            Spacer(minLength: V15Spacing.sm)
            amount
        }
        .accessibilityElement(children: .contain)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            title
            HStack {
                Spacer(minLength: 0)
                amount
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct V15GalleryMacIndex: View {
    @Binding var selection: V15GalleryFixture
    let density: V15GalleryDensity
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.xs) {
            Text("状态索引").font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color).padding(.top, V15Spacing.lg)
            Text("离线示例").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            Divider().padding(.vertical, V15Spacing.xs)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: density == .compact ? 0 : V15Spacing.xxs) {
                    ForEach(V15GalleryFixture.allCases) { fixture in
                        Button { selection = fixture } label: {
                            HStack(spacing: V15Spacing.xs) {
                                Circle().fill(marker(for: fixture)).frame(width: 7, height: 7).accessibilityHidden(true)
                                Text(fixture.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(V15Typography.secondary)
                            .padding(.horizontal, V15Spacing.xs)
                            .background(selection == fixture ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: V15Radius.tag))
                        }
                        .buttonStyle(.plain)
                        .v15PlatformHitArea()
                        .v15KeyboardFocusable()
                        .accessibilityLabel("状态：\(fixture.title)")
                        .accessibilityAddTraits(selection == fixture ? .isSelected : [])
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, V15Spacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("状态索引，当前\(selection.title)")
    }

    private func marker(for fixture: V15GalleryFixture) -> Color {
        switch fixture {
        case .preview, .fieldInvalid, .disabledReasons, .offlineReadOnly, .conflict: V15Palette.yellow.color
        case .serviceError: V15Palette.gold.color
        case .successReceipt, .partialProgress: V15Palette.teal.color
        default: V15Palette.ink.color.opacity(0.40)
        }
    }
}

private struct V15GalleryMacSpine: View {
    let selection: V15GalleryFixture
    let density: V15GalleryDensity
    let retryCount: Int
    let retry: () -> Void
    let showEditor: () -> Void
    let reducesMotion: Bool
    let reducesTransparency: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density == .compact ? V15Spacing.sm : V15Spacing.lg) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: V15Spacing.xxs) {
                        Text("账目").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
                        Text("2026 年 8 月 15 日 · 桌面显示效果")
                            .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
                    }
                    Spacer(minLength: V15Spacing.sm)
                    Text(density == .compact ? "紧凑" : "舒适").font(V15Typography.label).padding(.horizontal, V15Spacing.xs).padding(.vertical, V15Spacing.xxs).background(V15Palette.selected.color, in: Capsule())
                }
                V15GallerySpineRow(title: "本月流水", detail: selection.title, amount: -3_280_40, selected: true)
                V15GallerySpineRow(title: "已确认", detail: "午餐 · 已记账", amount: -4_500, selected: false)
                V15GalleryStateSurface(fixture: selection, retryCount: retryCount, retry: retry, showEditor: showEditor)
                V15GallerySpineRow(title: "下一页", detail: "分页边界 · 没有更多隐藏结果", amount: 0, selected: false)
            }
            .padding(density == .compact ? V15Spacing.md : V15Spacing.xl)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("账目，\(selection.accessibilitySummary)")
        .accessibilityHint(reducesMotion ? "减少动态效果已启用。" : "")
        .transaction { transaction in if reducesMotion { transaction.animation = nil } }
    }
}

private struct V15GallerySpineRow: View {
    let title: String
    let detail: String
    let amount: Int64
    let selected: Bool
    var body: some View {
        HStack(spacing: V15Spacing.sm) {
            RoundedRectangle(cornerRadius: 1).fill(selected ? V15Palette.teal.color : V15Palette.hairline.color).frame(width: 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.ink.color)
                Text(detail).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).lineLimit(2)
            }
            Spacer(minLength: V15Spacing.sm)
            V15MoneyText(minorUnits: amount, direction: amount < 0 ? .outflow : .neutral)
        }
        .padding(.horizontal, V15Spacing.xs)
        .background(selected ? V15Palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: V15Radius.tag))
        .v15PlatformHitArea()
        .accessibilityElement(children: .combine)
    }
}

private struct V15GalleryMacInspector: View {
    let fixture: V15GalleryFixture
    var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.md) {
            Text("详情").font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color)
            Text(fixture.title).font(V15Typography.secondary.weight(.semibold)).foregroundStyle(V15Palette.teal.color)
            Divider()
            V15InspectorPair(label: "数据来源", value: "示例数据")
            V15InspectorPair(label: "保存", value: "示例不会联网")
            V15InspectorPair(label: "键盘", value: "Tab 聚焦 · Return 执行")
            Spacer(minLength: 0)
            Text("这里用于预览不同状态下的界面与操作。")
                .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(V15Spacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("详情。\(fixture.accessibilitySummary)")
    }
}

private struct V15InspectorPair: View {
    let label: String
    let value: String
    var body: some View { VStack(alignment: .leading, spacing: 2) { Text(label).font(V15Typography.label).foregroundStyle(V15Palette.ink.color.opacity(0.66)); Text(value).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true) } }
}

private struct V15GalleryStateSurface: View {
    let fixture: V15GalleryFixture
    let retryCount: Int
    let retry: () -> Void
    let showEditor: () -> Void
    @State private var amount = "12345678901234.56"

    var body: some View {
        Group {
            switch fixture {
            case .loading:
                V15LoadingSkeleton(layout: .decisionCard)
            case .empty:
                V15EmptyState(title: "这个筛选下没有事项", explanation: "没有需要处理的已知未来事项。空态不会伪装成加载失败。")
            case .serviceError:
                V15ServiceErrorState(message: "暂时无法读取最新数据。已保留上次确认的本地显示，尚未提交任何更改。", retry: retry)
                    .accessibilityValue(retryCount == 0 ? "尚未重试" : "已重试 \(retryCount) 次")
                    .accessibilityIdentifier("v15.gallery.order.action.retry")
            case .fieldInvalid:
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    V15Field("报销金额", text: $amount, prompt: "0.00", issues: [V15FixtureLibrary.fieldInvalid.fieldIssues[0]])
                    V15ActionButton("在录入面板中查看错误", symbol: "rectangle.and.pencil.and.ellipsis", kind: .secondary, action: showEditor)
                }
            case .disabledReasons:
                V15ActionButton("提交报销", symbol: "arrow.right.circle", disabledReasons: [
                    .init(code: "account_loading", message: "收款账户仍在加载。", fieldPath: "destination_account_id"),
                    .init(code: "preview_missing", message: "请先查看预览；输入变化后需要重新预览。", fieldPath: nil)
                ], action: {})
                .accessibilityIdentifier("v15.gallery.order.disabled-reasons")
                .accessibilityValue("收款账户仍在加载。请先查看预览；输入变化后需要重新预览。")
            case .offlineReadOnly:
                VStack(alignment: .leading, spacing: V15Spacing.md) {
                    V15OfflineReadOnlyBanner(snapshotAt: Date(timeIntervalSince1970: 1_786_809_540), pendingCount: 3)
                    V15MoneyTruthState("账户价值", displayedMinorUnits: 10_468_055, confirmedMinorUnits: 10_452_055, pendingCount: 3)
                }
            case .conflict:
                V15ConflictState(conflict: V15FixtureLibrary.conflict.conflict!, changes: [
                    .init(field: "本次还款金额", previousValue: "¥3,280.40", currentValue: "¥1,280.40"),
                    .init(field: "账期设置", previousValue: "修改前", currentValue: "最新")
                ], reload: retry)
                    .accessibilityIdentifier("v15.gallery.order.action.reload")
                    .accessibilityValue(retryCount == 0 ? "尚未取最新数据" : "已取最新数据 \(retryCount) 次")
            case .preview:
                V15PreviewState(version: "账期调整预览") {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        Text("信用账期将重排").font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color)
                        Text("还款日将从 9 月 5 日调整为 9 月 10 日；确认前不会修改。")
                            .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                        V15ActionButton("确认账期调整", action: {})
                            .accessibilityIdentifier("v15.gallery.order.action.confirm")
                            .accessibilitySortPriority(60)
                    }
                }
            case .archiveReadOnly:
                V15ArchiveReadOnlyState(restore: {}) {
                    VStack(alignment: .leading, spacing: V15Spacing.xs) {
                        Text("已归档的旧报销单").font(V15Typography.cardTitle).foregroundStyle(V15Palette.ink.color)
                        Text("归档不是删除。历史金额与来源保持只读，可恢复后再继续处理。")
                            .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .successReceipt:
                V15SuccessReceiptState(title: "到账已保存", detail: "余额和到账记录将在刷新后显示最新结果。")
            case .partialProgress:
                V15PartialProgressState(succeeded: "已确认 8 条账单记录", currentState: "2 条仍需选择分类", remaining: "修正后再确认剩余内容；未处理的内容没有记到账目。")
            }
        }
        .accessibilityIdentifier("v15.gallery.state.\(fixture.id)")
    }
}

private struct V15GalleryPagination: View {
    var body: some View {
        HStack {
            Text("第 1 页 / 1 页").font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            Spacer()
            V15ActionButton("没有更多结果", symbol: "chevron.right", kind: .quiet, disabledReason: .init(code: "end_of_cursor", message: "已经显示全部内容。", fieldPath: nil), action: {})
                .frame(maxWidth: 210)
                .accessibilityIdentifier("v15.gallery.order.pagination")
                .accessibilityValue("已经显示全部内容。")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct V15GalleryEvidenceNote: View {
    let fixture: V15GalleryFixture
    var body: some View {
        Text("支持浅色、深色和较大字体。长文字会自动换行，金额保持清晰易读。")
            .font(V15Typography.secondary)
            .foregroundStyle(V15Palette.ink.color.opacity(0.66))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("显示说明。\(fixture.accessibilitySummary)")
    }
}

private struct V15GalleryFieldErrorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var amount = "12.345"
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: V15Spacing.lg) {
                    Text("登记到账").font(V15Typography.surfaceTitle).foregroundStyle(V15Palette.ink.color)
                    V15ServiceErrorState(message: "金额格式无效，请在当前页面修改后重试。", retry: {})
                    V15Field("到账金额", text: $amount, prompt: "0.00", issues: [V15FixtureLibrary.fieldInvalid.fieldIssues[0]])
                    V15ActionButton("保存", disabledReason: .init(code: "amount_invalid", message: "请将到账金额修正为最多两位小数。", fieldPath: "amount_minor"), action: {})
                }
                .padding(V15Spacing.lg)
            }
            .background(V15Palette.paper.color)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", action: { dismiss() }) } }
        }
        .accessibilityIdentifier("v15.gallery.field-error-sheet")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("登记到账录入面板。错误会在当前面板内显示。")
    }
}
