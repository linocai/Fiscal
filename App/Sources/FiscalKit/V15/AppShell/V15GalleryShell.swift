import Foundation
import SwiftUI

/// The parallel shell is intentionally gallery-only through F4. Formal app
/// roots never construct it; the dedicated gallery apps provide the launch
/// surface used by screenshots and accessibility tests.
public struct V15GalleryShell: View {
    private let fixture: V15GalleryFixture
    private let density: V15GalleryDensity
    private let showsFieldErrorSheet: Bool
    private let reducesMotion: Bool
    private let reducesTransparency: Bool
    private let f1ARoute: String?
    private let f1BRoute: String?
    private let f1CRoute: String?
    private let f2BRoute: String?
    private let f2CRoute: String?
    private let f3ARoute: String?
    private let f3B1Route: String?
    private let f3B2Route: String?
    private let f3CRoute: String?
    private let f3DRoute: String?
    private let f3ERoute: String?
    private let f3FRoute: String?
    private let f3GRoute: String?
    private let f4ARoute: String?
    private let f4BRoute: String?
    private let f4CRoute: String?
    private let f1AAppearance: ColorScheme?

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        fixture = .resolve(V15GalleryShell.value(after: "--v15-gallery-fixture", in: arguments))
        density = V15GalleryShell.value(after: "--v15-gallery-density", in: arguments).flatMap(V15GalleryDensity.init(rawValue:)) ?? .comfortable
        showsFieldErrorSheet = arguments.contains("--v15-gallery-sheet-error")
        reducesMotion = arguments.contains("--v15-gallery-reduce-motion")
        reducesTransparency = arguments.contains("--v15-gallery-reduce-transparency")
        f1ARoute = V15GalleryShell.value(after: "--v15-f1a-route", in: arguments)
        f1BRoute = V15GalleryShell.value(after: "--v15-f1b-route", in: arguments)
        f1CRoute = V15GalleryShell.value(after: "--v15-f1c-route", in: arguments)
        f2BRoute = V15GalleryShell.value(after: "--v15-f2b-route", in: arguments)
        f2CRoute = V15GalleryShell.value(after: "--v15-f2c-route", in: arguments)
        f3ARoute = V15GalleryShell.value(after: "--v15-f3a-route", in: arguments)
        f3B1Route = V15GalleryShell.value(after: "--v15-f3b1-route", in: arguments)
        f3B2Route = V15GalleryShell.value(after: "--v15-f3b2-route", in: arguments)
        f3CRoute = V15GalleryShell.value(after: "--v15-f3c-route", in: arguments)
        f3DRoute = V15GalleryShell.value(after: "--v15-f3d-route", in: arguments)
        f3ERoute = V15GalleryShell.value(after: "--v15-f3e-route", in: arguments)
        f3FRoute = V15GalleryShell.value(after: "--v15-f3f-route", in: arguments)
        f3GRoute = V15GalleryShell.value(after: "--v15-f3g-route", in: arguments)
        f4ARoute = V15GalleryShell.value(after: "--v15-f4a-route", in: arguments)
        f4BRoute = V15GalleryShell.value(after: "--v15-f4b-route", in: arguments)
        f4CRoute = V15GalleryShell.value(after: "--v15-f4c-route", in: arguments)
        f1AAppearance = V15GalleryShell.value(after: "--v15-f1a-appearance", in: arguments).flatMap { $0 == "dark" ? .dark : $0 == "light" ? .light : nil }
    }

    public init(
        fixture: V15GalleryFixture,
        density: V15GalleryDensity = .comfortable,
        showsFieldErrorSheet: Bool = false,
        reducesMotion: Bool = false,
        reducesTransparency: Bool = false
    ) {
        self.fixture = fixture
        self.density = density
        self.showsFieldErrorSheet = showsFieldErrorSheet
        self.reducesMotion = reducesMotion
        self.reducesTransparency = reducesTransparency
        f1ARoute = nil
        f1BRoute = nil
        f1CRoute = nil
        f2BRoute = nil
        f2CRoute = nil
        f3ARoute = nil
        f3B1Route = nil
        f3B2Route = nil
        f3CRoute = nil
        f3DRoute = nil
        f3ERoute = nil
        f3FRoute = nil
        f3GRoute = nil
        f4ARoute = nil
        f4BRoute = nil
        f4CRoute = nil
        f1AAppearance = nil
    }

    public var body: some View {
        if let f4CRoute {
            V15F4CGalleryRoute(route: f4CRoute).preferredColorScheme(f1AAppearance)
        } else if let f4BRoute {
            V15F4AGalleryRoute(route: f4BRoute).preferredColorScheme(f1AAppearance)
        } else if let f4ARoute {
            V15F4AGalleryRoute(route: f4ARoute).preferredColorScheme(f1AAppearance)
        } else if let f3GRoute {
            V15F3GGalleryRoute(route: f3GRoute).preferredColorScheme(f1AAppearance)
        } else if let f3FRoute {
            V15F3FGalleryRoute(route: f3FRoute).preferredColorScheme(f1AAppearance)
        } else if let f3ERoute {
            V15F3EGalleryRoute(route: f3ERoute).preferredColorScheme(f1AAppearance)
        } else if let f3DRoute {
            V15F3DGalleryRoute(route: f3DRoute).preferredColorScheme(f1AAppearance)
        } else if let f3CRoute {
            V15F3CGalleryRoute(route: f3CRoute).preferredColorScheme(f1AAppearance)
        } else if let f3B2Route {
            V15F3B2GalleryRoute(route: f3B2Route).preferredColorScheme(f1AAppearance)
        } else if let f3B1Route {
            V15F3B1GalleryRoute(route: f3B1Route).preferredColorScheme(f1AAppearance)
        } else if let f3ARoute {
            V15F3AGalleryRoute(route: f3ARoute).preferredColorScheme(f1AAppearance)
        } else if let f2CRoute {
            V15F2CGalleryRoute(route: f2CRoute).preferredColorScheme(f1AAppearance)
        } else if let f2BRoute {
            V15F2BGalleryRoute(route: f2BRoute).preferredColorScheme(f1AAppearance)
        } else if let f1CRoute {
            V15F1CGalleryRoute(route: f1CRoute).preferredColorScheme(f1AAppearance)
        } else if let f1BRoute {
            V15F1BGalleryRoute(route: f1BRoute)
                .preferredColorScheme(f1AAppearance)
        } else if let f1ARoute {
            V15F1AGalleryRoute(route: f1ARoute)
                .preferredColorScheme(f1AAppearance)
        } else {
            V15GalleryView(
                fixture: fixture,
                density: density,
                showsFieldErrorSheet: showsFieldErrorSheet,
                reducesMotion: reducesMotion,
                reducesTransparency: reducesTransparency
            )
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(arguments.index(after: index)) else { return nil }
        return arguments[arguments.index(after: index)]
    }
}

@MainActor private struct V15F4CGalleryRoute: View {
    let route: String
    private let services: V15Services
    @State private var model: V15ArchiveModel
    init(route: String) {
        self.route = route
        let services = V15F4CFixtures.services(route: route)
        self.services = services
        _model = State(initialValue: .init(services: services, offlineSnapshotAt: route == "archive-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil))
    }
    var body: some View {
#if os(macOS)
        V15DataSecurityMacView(model: model, saver: V15F4CFixtures.saver(route: route))
            .task { startSnapshotTransferIfNeeded() }
#else
        V15DataSecurityView(model: model)
#endif
    }

    private func startSnapshotTransferIfNeeded() {
        guard ["archive-loading", "archive-error", "archive-unknown"].contains(route), model.phase == .idle else { return }
        model.password = "gallery-synthetic-password"
        model.passwordConfirmation = "gallery-synthetic-password"
        model.beginExport()
        model.confirmExport()
    }
}

@MainActor private struct V15F4AGalleryRoute: View {
    let route: String
    private let services: V15Services
    init(route: String) {
        self.route = route
        services = V15F4AFixtures.services(route: route)
    }
    var body: some View {
#if os(macOS)
        V15ReportingMacView(services: services, offlineSnapshotAt: route == "reports-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, artifactSaver: V15F4AFixtures.artifactSaver(route: route))
#else
        V15ReportingView(services: services, offlineSnapshotAt: route == "reports-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
#endif
    }
}

private struct V15F3GGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F3GFixtures.services(route: route) }
    var body: some View {
#if os(macOS)
        V15StatementImportMacView(services: services, offlineSnapshotAt: route == "statement-import-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialGalleryScenario: route)
#else
        V15StatementImportView(services: services, offlineSnapshotAt: route == "statement-import-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialGalleryScenario: route)
#endif
    }
}

private struct V15F3FGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F3FFixtures.services(route: route) }
    var body: some View {
#if os(macOS)
        V15AIProposalMacView(services: services, offlineSnapshotAt: route == "ai-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialGalleryScenario: route)
#else
        V15AIProposalView(services: services, offlineSnapshotAt: route == "ai-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
#endif
    }
}

private struct V15F3EGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F3EFixtures.services(route: route) }
    var body: some View {
#if os(macOS)
        V15ReconciliationMacView(services: services, offlineSnapshotAt: route == "reconciliation-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialGalleryScenario: route)
#else
        V15ReconciliationView(services: services, offlineSnapshotAt: route == "reconciliation-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
#endif
    }
}

private struct V15F3DGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F3DFixtures.services(route: route) }
    var body: some View {
#if os(macOS)
        V15CashFlowMacView(services: services, offlineSnapshotAt: route == "cash-flow-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialGalleryScenario: route)
#else
        V15CashFlowView(services: services, offlineSnapshotAt: route == "cash-flow-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
#endif
    }
}

private struct V15F3CGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F3CFixtures.services(route: route) }
    var body: some View {
#if os(macOS)
        V15ReimbursementMacView(services: services, offlineSnapshotAt: route == "reimbursements-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialGalleryScenario: route)
#else
        V15ReimbursementView(services: services, offlineSnapshotAt: route == "reimbursements-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
#endif
    }
}

private struct V15F3B2GalleryRoute: View {
    let route: String
    private static let fixtureNow = ISO8601DateFormatter().date(from: "2026-08-15T03:00:00Z")!
    @MainActor private var services: V15Services { V15F3B2Fixtures.services(route: route) }
    var body: some View {
#if os(macOS)
        V15InstallmentMacView(services: services, offlineSnapshotAt: route == "installments-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialGalleryScenario: route, now: { Self.fixtureNow })
#else
        V15InstallmentView(services: services, offlineSnapshotAt: route == "installments-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, now: { Self.fixtureNow })
#endif
    }
}

private struct V15F3B1GalleryRoute: View {
    let route: String
    @State private var offlineRecoveryMarker = F3B1OfflineSnapshotMarker()
    @MainActor private var services: V15Services { V15F3B1Fixtures.services(route: route, offlineSnapshotMarker: route == "credit-unknown-offline-recovery" ? offlineRecoveryMarker : nil) }
    var body: some View {
#if os(macOS)
        if ["credit-expired", "credit-disabled", "credit-conflict", "credit-page-error"].contains(route) { V15CreditMacGalleryEvidence(scenario: route) }
        else if route == "credit-unknown-offline-recovery" { V15CreditMacView(services: services, offlineSnapshotProvider: { offlineRecoveryMarker.snapshotAt }, initialGalleryScenario: route) }
        else { V15CreditMacView(services: services, offlineSnapshotAt: route == "credit-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialGalleryScenario: route) }
#else
        if route == "credit-unknown-offline-recovery" { V15CreditView(services: services, offlineSnapshotProvider: { offlineRecoveryMarker.snapshotAt }, fixtureReconnectAction: { offlineRecoveryMarker.snapshotAt = nil }) }
        else { V15CreditView(services: services, offlineSnapshotAt: route == "credit-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil) }
#endif
}
}

private struct V15F3AGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F3AFixtures.services(route: route) }
    var body: some View {
#if os(macOS)
        if route == "timeline-page-error" { V15FutureTimelineMacPageErrorEvidence() }
        else { V15FutureTimelineMacView(services: services, offlineSnapshotAt: route == "timeline-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialAutoLoadNext: false) }
#else
        V15FutureTimelineView(services: services, offlineSnapshotAt: route == "timeline-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialAutoLoadNext: route == "timeline-page-error")
#endif
    }
}

private struct V15F2CGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F2CFixtures.services(route: route) }
    var body: some View {
#if os(macOS)
        if route.hasPrefix("today") { V15TodayMacView(services: services, offlineSnapshotAt: route == "today-offline" ? V15F2CFixtures.offlineSnapshotAt : nil, initialScopeType: ["today-conflict", "today-scope-error", "today-unknown"].contains(route) ? "cash_accounts" : nil) }
        else { V15EmptyState(title: "无法识别 Today 路由", explanation: "该链接只可用于并行 Today 检查。") }
#else
        V15EmptyState(title: "此路由仅用于 macOS", explanation: "iOS Today 由 F2-B 路由提供。")
#endif
    }
}

private struct V15F2BGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F2BFixtures.services(route: route) }
    var body: some View {
        if route.hasPrefix("today-") || route == "today" {
            V15TodayView(services: services, offlineSnapshotAt: route == "today-offline" ? V15F2BFixtures.offlineSnapshotAt : nil)
        } else {
            V15EmptyState(title: "无法识别 Today 路由", explanation: "该链接只可用于并行 Today 检查。")
        }
    }
}

private struct V15F1CGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F1CFixtures.services(conflict: route == "master-conflict") }
    var body: some View {
        if route == "master" || route == "master-conflict" { V15MasterDataView(services: services) }
        else if route == "master-offline" { V15MasterDataView(services: services, offlineSnapshotAt: Date(timeIntervalSince1970: 1_786_464_000)) }
        else { V15EmptyState(title: "无法识别主数据路由", explanation: "该链接只可用于并行主数据检查。") }
    }
}

private struct V15F1BGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F1BFixtures.services(pageFailure: route == "ledger-page-error") }
    var body: some View {
        // F1-B has one deliberately fixture-only ledger route.  Unknown paths
        // are not deep-linked into the formal app or legacy navigation.
        if route == "ledger" { V15LedgerLibraryView(services: services) }
        else if route == "ledger-detail" { V15LedgerLibraryView(services: services, initialDetailID: V15F1BFixtures.transactionID) }
        else if route == "ledger-offline" { V15LedgerLibraryView(services: services, offlineSnapshotAt: Date(timeIntervalSince1970: 1_786_464_000)) }
        else if route == "ledger-page-error" { V15LedgerLibraryView(services: services) }
        else { V15EmptyState(title: "无法识别账目路由", explanation: "该链接只可用于只读账目检查。") }
    }
}

private struct V15F1AGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F1AFixtures.services() }
    var body: some View {
        Group {
            if route == "bootstrap" { V15BootstrapView(services: services) }
            else { V15RecordView(services: services, prefilled: route == "record-valid", repaymentPrefilled: route == "repayment-valid", occurredOn: V15F1AFixtures.businessDate) }
        }
        .accessibilityIdentifier("v15.f1a.gallery.\(route)")
    }
}
