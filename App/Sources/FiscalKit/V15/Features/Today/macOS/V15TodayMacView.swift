import SwiftUI

#if os(macOS)

/// The live macOS root is `V151MacWorkspace`. This gallery/read-only facts
/// surface deliberately has no generic attention queue.
public struct V15TodayMacView: View {
    @State private var model: V15TodayReadModel
    private let initialScopeType: String?

    public init(services: V15Services, offlineSnapshotAt: Date? = nil, initialScopeType: String? = nil) {
        _model = State(initialValue: V15TodayReadModel(services: services, offlineSnapshotProvider: { offlineSnapshotAt ?? services.offlineSnapshotAt }))
        self.initialScopeType = initialScopeType
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: V15Spacing.md) {
                HStack { Text("今日概览").font(V15Typography.cardTitle); Spacer(); Button("重新读取") { Task { await model.refresh() } } }
                switch model.factsPhase {
                case .idle, .loading: V15LoadingSkeleton()
                case .failed(let failure), .requiresReload(let failure): V15ServiceErrorState(message: failure.message) { Task { await model.refresh() } }
                case .loaded:
                    if let facts = model.facts {
                        V15Section("未来安排", detail: "已录入或已排期的事实") {
                            if facts.knownFutureEvents.isEmpty { Text("当前窗口没有已知未来事项。").font(V15Typography.secondary) }
                            else { ForEach(facts.knownFutureEvents) { event in Text("\(event.date) · \(event.title)").font(V15Typography.body) } }
                        }
                        V15Section("统计范围") { Text("\(facts.window.dateFrom) 至 \(facts.window.dateTo) · \(facts.meta.currency)").font(V15Typography.secondary) }
                    }
                }
            }
            .padding(V15Spacing.md)
        }
        .frame(minWidth: 720, minHeight: 540)
        .accessibilityIdentifier("v15.f2c.today.macos")
        .task { await model.refresh(); if let initialScopeType { await model.openScope(type: initialScopeType) } }
    }
}

enum V15TodayMacRefreshPolicy {
    static func scopeTypeToReopen(currentScopeType: String?) -> String? {
        switch currentScopeType {
        case "cash_accounts", "credit_cycles", "reimbursement_outstanding", "completeness_issues": currentScopeType
        default: nil
        }
    }
}

#endif
