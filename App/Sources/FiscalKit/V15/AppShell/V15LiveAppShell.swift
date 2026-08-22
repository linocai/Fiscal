import SwiftUI

/// Formal-app composition.  It owns only the V15 navigation and receives the
/// production `V15Services` boundary from each app target.  Gallery fixtures,
/// routes and transports are deliberately absent from this file.
#if os(iOS)
public struct V15IOSLiveAppShell: View {
    private enum Tab: Hashable { case today, ledger, record, more }
    private enum More: String, CaseIterable, Identifiable {
        case masterData, timeline, credit, installments, reimbursements, cashFlow
        case reconciliation, proposals, statementImport, reports, archive
        var id: String { rawValue }
        var title: String {
            switch self {
            case .masterData: "账户与分类"
            case .timeline: "未来时间线"
            case .credit: "信用账期"
            case .installments: "分期"
            case .reimbursements: "报销"
            case .cashFlow: "现金流"
            case .reconciliation: "核对"
            case .proposals: "AI 待确认"
            case .statementImport: "账单导入"
            case .reports: "报告"
            case .archive: "数据与安全"
            }
        }
        var symbol: String {
            switch self {
            case .masterData: "wallet.bifold"
            case .timeline: "calendar"
            case .credit: "creditcard"
            case .installments: "rectangle.3.group"
            case .reimbursements: "doc.text"
            case .cashFlow: "arrow.up.arrow.down"
            case .reconciliation: "checkmark.circle"
            case .proposals: "sparkles"
            case .statementImport: "doc.text.viewfinder"
            case .reports: "chart.bar"
            case .archive: "lock.document"
            }
        }
    }

    private let services: V15Services
    private let bootstrapAccessKey: String?
    @State private var selectedTab: Tab = .today
    @State private var isAvailable = false
    @State private var prepared = false

    public init(services: V15Services, bootstrapAccessKey: String? = nil) {
        self.services = services
        self.bootstrapAccessKey = bootstrapAccessKey
    }

    public var body: some View {
        Group {
            if !prepared {
                ProgressView("正在准备安全连接…")
                    .accessibilityIdentifier("v15.live.bootstrap.preparing")
            } else if !isAvailable {
                V15BootstrapView(services: services, onAvailable: { isAvailable = true })
            } else {
                TabView(selection: $selectedTab) {
                    V15TodayView(services: services)
                        .tabItem { Label("今日", systemImage: "sun.max") }.tag(Tab.today)
                    V15LedgerLibraryView(services: services)
                        .tabItem { Label("账目", systemImage: "list.bullet.rectangle") }.tag(Tab.ledger)
                    V15RecordView(services: services)
                        .tabItem { Label("录入", systemImage: "plus.circle") }.tag(Tab.record)
                    more
                        .tabItem { Label("更多", systemImage: "square.grid.2x2") }.tag(Tab.more)
                }
            }
        }
        .background(V15Palette.paper.color)
        .accessibilityElement(children: .contain)
        .task {
            guard !prepared else { return }
            _ = try? await services.session.saveBootstrapAccessKeyIfPresent(bootstrapAccessKey)
            prepared = true
        }
    }

    private var more: some View {
        NavigationStack {
            List(More.allCases) { destination in
                NavigationLink(value: destination) {
                    Label(destination.title, systemImage: destination.symbol)
                }
                .accessibilityIdentifier("v15.live.more.\(destination.rawValue)")
            }
            .navigationTitle("更多")
            .navigationDestination(for: More.self) { destination in
                destinationView(destination)
            }
        }
    }

    @ViewBuilder private func destinationView(_ destination: More) -> some View {
        switch destination {
        case .masterData: V15MasterDataView(services: services)
        case .timeline: V15FutureTimelineView(services: services)
        case .credit: V15CreditView(services: services)
        case .installments: V15InstallmentView(services: services)
        case .reimbursements: V15ReimbursementView(services: services)
        case .cashFlow: V15CashFlowView(services: services)
        case .reconciliation: V15ReconciliationView(services: services)
        case .proposals: V15AIProposalView(services: services)
        case .statementImport: V15StatementImportView(services: services)
        case .reports: V15ReportingView(services: services)
        case .archive: V15DataSecurityView(services: services)
        }
    }
}
#endif

#if os(macOS)
public struct V15MacLiveAppShell: View {
    private enum Destination: String, CaseIterable, Identifiable {
        case today, ledger, record, masterData, timeline, credit, installments
        case reimbursements, cashFlow, reconciliation, proposals, statementImport, reports, archive
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: "Today 焦点"; case .ledger: "账目库"; case .record: "录入"
            case .masterData: "账户与分类"; case .timeline: "未来时间线"; case .credit: "信用账期"
            case .installments: "分期"; case .reimbursements: "报销"; case .cashFlow: "现金流"
            case .reconciliation: "核对"; case .proposals: "AI 待确认"; case .statementImport: "账单导入"
            case .reports: "报告"; case .archive: "数据与安全"
            }
        }
        var symbol: String {
            switch self {
            case .today: "sun.max"; case .ledger: "list.bullet.rectangle"; case .record: "plus.circle"
            case .masterData: "wallet.bifold"; case .timeline: "calendar"; case .credit: "creditcard"
            case .installments: "rectangle.3.group"; case .reimbursements: "doc.text"; case .cashFlow: "arrow.up.arrow.down"
            case .reconciliation: "checkmark.circle"; case .proposals: "sparkles"; case .statementImport: "doc.text.viewfinder"
            case .reports: "chart.bar"; case .archive: "lock.document"
            }
        }
    }

    private let services: V15Services
    private let bootstrapAccessKey: String?
    @State private var selection: Destination? = .today
    @State private var isAvailable = false
    @State private var prepared = false

    public init(services: V15Services, bootstrapAccessKey: String? = nil) {
        self.services = services
        self.bootstrapAccessKey = bootstrapAccessKey
    }

    public var body: some View {
        Group {
            if !prepared {
                ProgressView("正在准备安全连接…")
                    .accessibilityIdentifier("v15.live.bootstrap.preparing")
            } else if !isAvailable {
                V15BootstrapView(services: services, onAvailable: { isAvailable = true })
            } else {
                NavigationSplitView {
                    List(Destination.allCases, selection: $selection) { destination in
                        Label(destination.title, systemImage: destination.symbol).tag(destination)
                    }
                    .navigationTitle("Fiscal")
                    .accessibilityIdentifier("v15.live.mac.sidebar")
                } detail: {
                    if let selection { destinationView(selection) }
                    else { V15EmptyState(title: "选择一个事实视图", explanation: "从侧栏进入需要的业务领域。") }
                }
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(V15Palette.paper.color)
        .accessibilityElement(children: .contain)
        .task {
            guard !prepared else { return }
            _ = try? await services.session.saveBootstrapAccessKeyIfPresent(bootstrapAccessKey)
            prepared = true
        }
    }

    @ViewBuilder private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .today: V15TodayMacView(services: services)
        case .ledger: V15LedgerLibraryView(services: services)
        case .record: V15RecordView(services: services)
        case .masterData: V15MasterDataView(services: services)
        case .timeline: V15FutureTimelineMacView(services: services)
        case .credit: V15CreditMacView(services: services)
        case .installments: V15InstallmentMacView(services: services)
        case .reimbursements: V15ReimbursementMacView(services: services)
        case .cashFlow: V15CashFlowMacView(services: services)
        case .reconciliation: V15ReconciliationMacView(services: services)
        case .proposals: V15AIProposalMacView(services: services)
        case .statementImport: V15StatementImportMacView(services: services)
        case .reports: V15ReportingMacView(services: services)
        case .archive: V15DataSecurityMacView(services: services)
        }
    }
}
#endif
