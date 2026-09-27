@testable import FiscalKit
import Foundation
import SwiftUI

/// The dedicated gallery app mounts production pages with deterministic services.
public struct V15GalleryShell: View {
    private let f1ARoute: String?
    private let f1CRoute: String?
    private let f3ARoute: String?
    private let f3B1Route: String?
    private let f3B2Route: String?
    private let f3CRoute: String?
    private let f3DRoute: String?
    private let f3FRoute: String?
    private let f4ARoute: String?
    private let f4BRoute: String?
    private let f4CRoute: String?
    private let seedsF4CCredentials: Bool
    private let f1AAppearance: ColorScheme?

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        f1ARoute = V15GalleryShell.value(after: "--v15-f1a-route", in: arguments)
        f1CRoute = V15GalleryShell.value(after: "--v15-f1c-route", in: arguments)
        f3ARoute = V15GalleryShell.value(after: "--v15-f3a-route", in: arguments)
        f3B1Route = V15GalleryShell.value(after: "--v15-f3b1-route", in: arguments)
        f3B2Route = V15GalleryShell.value(after: "--v15-f3b2-route", in: arguments)
        f3CRoute = V15GalleryShell.value(after: "--v15-f3c-route", in: arguments)
        f3DRoute = V15GalleryShell.value(after: "--v15-f3d-route", in: arguments)
        f3FRoute = V15GalleryShell.value(after: "--v15-f3f-route", in: arguments)
        f4ARoute = V15GalleryShell.value(after: "--v15-f4a-route", in: arguments)
        f4BRoute = V15GalleryShell.value(after: "--v15-f4b-route", in: arguments)
        f4CRoute = V15GalleryShell.value(after: "--v15-f4c-route", in: arguments)
        seedsF4CCredentials = arguments.contains("--v15-f4c-seed-credentials")
        f1AAppearance = V15GalleryShell.value(after: "--v15-f1a-appearance", in: arguments).flatMap { $0 == "dark" ? .dark : $0 == "light" ? .light : nil }
    }

    public var body: some View {
        if let f4CRoute {
            V15F4CGalleryRoute(route: f4CRoute, seedsCredentials: seedsF4CCredentials).preferredColorScheme(f1AAppearance)
        } else if let f4BRoute {
            V15F4AGalleryRoute(route: f4BRoute).preferredColorScheme(f1AAppearance)
        } else if let f4ARoute {
            V15F4AGalleryRoute(route: f4ARoute).preferredColorScheme(f1AAppearance)
        } else if let f3FRoute {
            V15F3FGalleryRoute(route: f3FRoute).preferredColorScheme(f1AAppearance)
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
        } else if let f1CRoute {
            V15F1CGalleryRoute(route: f1CRoute).preferredColorScheme(f1AAppearance)
        } else if let f1ARoute {
            V15F1AGalleryRoute(route: f1ARoute)
                .preferredColorScheme(f1AAppearance)
        } else {
#if os(macOS)
            V151MacWorkspace(services: V15F2BFixtures.services(route: "today-root-workspace"))
#else
            V151IOSWorkspace(services: V15F2BFixtures.services(route: "today-root-workspace"))
#endif
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
    init(route: String, seedsCredentials: Bool = false) {
        self.route = route
        let services = V15F4CFixtures.services(route: route)
        self.services = services
        let model = V15ArchiveModel(services: services, offlineSnapshotAt: route == "archive-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
        if seedsCredentials {
            model.password = "synthetic-password-123"
            model.passwordConfirmation = "synthetic-password-123"
        }
        _model = State(initialValue: model)
    }
    var body: some View {
#if os(macOS)
        V15DataSecurityMacView(services: services, model: model, saver: V15F4CFixtures.saver(route: route))
            .task { startSnapshotTransferIfNeeded() }
#else
        V15DataSecurityView(services: services, model: model)
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
    private var initialLens: V15ReportingModel.Lens {
        if route.contains("spending") { return .spending }
        if route.contains("cash-flow") { return .cashFlow }
        if route.contains("debt") { return .debt }
        return .overview
    }
    var body: some View {
#if os(macOS)
        V15ReportingMacView(services: services, offlineSnapshotAt: route == "reports-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialLens: initialLens, artifactSaver: V15F4AFixtures.artifactSaver(route: route))
#else
        V15ReportingView(services: services, offlineSnapshotAt: route == "reports-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialLens: initialLens, initialPeriod: .month(V15ReportMonth("2026-08")!))
#endif
    }
}

private struct V15F3FGalleryRoute: View {
    let route: String
    private let services: V15Services
#if os(macOS)
    @State private var model: V15AIProposalModel
    @State private var prepared = false
    @State private var reviewPresented = false
#endif

    @MainActor init(route: String) {
        self.route = route
        let services = V15F3FFixtures.services(route: route)
        self.services = services
#if os(macOS)
        _model = State(initialValue: V15AIProposalModel(
            services: services,
            offlineSnapshotAt: route == "ai-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil
        ))
#endif
    }

    var body: some View {
#if os(macOS)
        Group {
            if prepared {
                V15AIProposalMacView(model: model, services: services, reviewPresented: reviewPresented)
            } else {
                V15LoadingSkeleton()
            }
        }
        .task { await prepareMacScenario() }
#else
        V15AIProposalView(services: services, offlineSnapshotAt: route == "ai-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
#endif
    }

#if os(macOS)
    @MainActor private func prepareMacScenario() async {
        guard !prepared else { return }
        await model.load()
        if let proposal = model.selectedProposal {
            switch route {
            case "ai-review", "ai-field-error", "ai-conflict", "ai-response-unknown", "ai-response-unknown-read-failure":
                model.openReview(proposal)
                if let categoryID = model.visibleCategories.first?.id { model.categoryID = categoryID }
                reviewPresented = true
                if route != "ai-review" {
                    await model.confirmDraft()
                    if route == "ai-response-unknown-read-failure" { await model.recoverUnknownDirect() }
                }
            case "ai-cash-flow":
                model.openReview(proposal)
                reviewPresented = true
            default:
                break
            }
        }
        if route == "ai-page-error" { await model.loadNextPage() }
        if route == "ai-create-unknown" || route == "ai-create-unknown-settings-transport-after-safe" {
            model.inputText = "午餐 132 元"
            await model.create()
            if route == "ai-create-unknown-settings-transport-after-safe" { await model.load() }
        }
        prepared = true
    }
#endif
}

private struct V15F3DGalleryRoute: View {
    let route: String
    private let services: V15Services
#if os(macOS)
    @State private var model: V15CashFlowModel
#endif

    @MainActor init(route: String) {
        self.route = route
        let services = V15F3DFixtures.services(route: route)
        self.services = services
#if os(macOS)
        _model = State(initialValue: V15CashFlowModel(
            services: services,
            offlineSnapshotAt: route == "cash-flow-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil
        ))
#endif
    }

    var body: some View {
#if os(macOS)
        V15CashFlowMacView(model: model)
            .task { await prepareMacScenario() }
#else
        V15CashFlowView(services: services, offlineSnapshotAt: route == "cash-flow-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
#endif
    }

#if os(macOS)
    @MainActor private func prepareMacScenario() async {
        guard model.phase == .idle else { return }
        await model.load()
        if route.contains("history") {
            await model.setVisibleList(.history)
            if let item = model.history?.items.first { await model.selectItem(item, from: .history) }
        } else if let item = model.active?.items.first {
            await model.selectItem(item)
        }
        if route.contains("conflict"), let item = model.active?.items.first {
            await model.selectItem(item)
            model.openEdit(item)
            model.title = "冲突中的现金流修改"
            await model.update()
        } else if route.contains("unknown"), let item = model.active?.items.first(where: { $0.direction == .transfer && !$0.isSystem }) {
            await model.selectItem(item)
            model.openSettle(item)
            await model.settle()
        } else if route.contains("partial-refresh") {
            model.openCreate()
            model.title = "新建现金流"
            model.amountText = "123.45"
            model.expectedDateText = "2026-08-28"
            await model.create()
        } else if route.contains("create") {
            model.openCreate()
            model.title = "新建现金流"
            model.amountText = route.contains("invalid") ? "12.345" : "123.45"
            model.expectedDateText = "2026-08-28"
        } else if route.contains("settle"), let item = model.active?.items.first(where: { $0.direction == .transfer && !$0.isSystem }) {
            await model.selectItem(item)
            model.openSettle(item)
        } else if route.contains("system"), let item = model.active?.items.first(where: { $0.systemKind == .reimbursement }) {
            await model.selectItem(item)
            model.openEdit(item)
        } else if route.contains("edit"), let item = model.active?.items.first {
            await model.selectItem(item)
            model.openEdit(item)
            model.mutationScope = .thisAndFuture
        }
    }
#endif
}

private struct V15F3CGalleryRoute: View {
    let route: String
    private let services: V15Services
#if os(macOS)
    @State private var model: V15ReimbursementModel
    @State private var receiptReplacementID: UUID?
#endif

    @MainActor init(route: String) {
        self.route = route
        let services = V15F3CFixtures.services(route: route)
        self.services = services
#if os(macOS)
        _model = State(initialValue: V15ReimbursementModel(
            services: services,
            offlineSnapshotAt: route == "reimbursements-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil
        ))
#endif
    }

    var body: some View {
#if os(macOS)
        V15ReimbursementMacView(model: model, initialReceiptReplacementID: receiptReplacementID)
            .task { await prepareMacScenario() }
#else
        V15ReimbursementView(services: services, offlineSnapshotAt: route == "reimbursements-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
#endif
    }

#if os(macOS)
    @MainActor private func prepareMacScenario() async {
        guard model.phase == .idle else { return }
        await model.load()
        switch route {
        case "reimbursements-claim-new":
            await model.openNewClaim()
            model.claimTitle = "八月差旅报销"
            model.counterpartyName = "示例公司"
            if let candidate = model.candidates.first(where: { $0.eligibility.eligible && $0.categoryID == nil }) {
                model.chooseCandidate(candidate)
            }
        case "reimbursements-claim-reasons":
            await model.openNewClaim()
        case "reimbursements-receipt-loading", "reimbursements-receipt-empty", "reimbursements-receipt-retry":
            await model.openReceipt()
        case "reimbursements-invalid-valid":
            await model.openReceipt()
            model.receiptTitle = ""
            model.receiptAmountText = "180.001"
            model.receiptDateText = "9999-12-31"
        case "reimbursements-preview", "reimbursements-conflict":
            await model.openReceipt()
            await model.previewReceipt()
        case "reimbursements-receipt-replace":
            if let receipt = model.receipts.first {
                model.openReceiptReplacement(receipt)
                receiptReplacementID = receipt.id
            }
        case "reimbursements-success", "reimbursements-receipt-refresh-failure", "reimbursements-receipt-unknown":
            await model.openReceipt()
            await model.previewReceipt()
            await model.commitReceipt()
        case "reimbursements-direct-readback":
            await model.performDirectClaim(.void)
        default:
            break
        }
    }
#endif
}

private struct V15F3B2GalleryRoute: View {
    let route: String
    private static let fixtureNow = ISO8601DateFormatter().date(from: "2026-08-15T03:00:00Z")!
    private let services: V15Services
#if os(macOS)
    @State private var scenarioModel: V15InstallmentModel
    @State private var scenarioPrepared = false
#endif

    @MainActor init(route: String) {
        self.route = route
        let services = V15F3B2Fixtures.services(route: route)
        self.services = services
#if os(macOS)
        _scenarioModel = State(initialValue: V15InstallmentModel(
            services: services,
            offlineSnapshotAt: route == "installments-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil,
            now: { Self.fixtureNow }
        ))
#endif
    }

    var body: some View {
#if os(macOS)
        if ["installments-page-error", "installments-update-unknown-confirmed", "installments-command-unknown"].contains(route) {
            Group {
                if scenarioPrepared {
                    V15InstallmentMacView(model: scenarioModel, initialInspector: route == "installments-update-unknown-confirmed" ? .edit : route == "installments-command-unknown" ? .command : .facts)
                } else {
                    V15LoadingSkeleton()
                }
            }
            .task { await prepareMacScenario() }
        } else {
            V15InstallmentMacView(
                services: services,
                offlineSnapshotAt: route == "installments-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil,
                initialPurchaseTransactionID: route == "installments-existing-prefilled" ? V15F3B2Fixtures.purchaseID : nil,
                now: { Self.fixtureNow }
            )
        }
#else
        V15InstallmentView(
            services: services,
            offlineSnapshotAt: route == "installments-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil,
            initialPurchaseTransactionID: route == "installments-existing-prefilled" ? V15F3B2Fixtures.purchaseID : nil,
            now: { Self.fixtureNow }
        )
#endif
    }

#if os(macOS)
    @MainActor private func prepareMacScenario() async {
        guard !scenarioPrepared else { return }
        await scenarioModel.load()
        switch route {
        case "installments-page-error":
            await scenarioModel.loadNextPage()
        case "installments-update-unknown-confirmed":
            if let plan = scenarioModel.plans.first {
                await scenarioModel.selectPlan(plan)
                await scenarioModel.requestPlanPreview()
            }
        case "installments-command-unknown":
            if let plan = scenarioModel.plans.first {
                await scenarioModel.selectPlan(plan)
                await scenarioModel.requestCommandPreview()
            }
        default:
            break
        }
        scenarioPrepared = true
    }
#endif
}

private struct V15F3B1GalleryRoute: View {
    let route: String
    private let services: V15Services
    @State private var offlineRecoveryMarker: F3B1OfflineSnapshotMarker
#if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasBackgrounded = false
#endif
#if os(macOS)
    @State private var scenarioModel: V15CreditModel
    @State private var scenarioPrepared = false
#endif

    @MainActor init(route: String) {
        self.route = route
        let marker = F3B1OfflineSnapshotMarker()
        _offlineRecoveryMarker = State(initialValue: marker)
        let services = V15F3B1Fixtures.services(
            route: route,
            offlineSnapshotMarker: route == "credit-unknown-offline-recovery" ? marker : nil
        )
        self.services = services
#if os(macOS)
        _scenarioModel = State(initialValue: V15CreditModel(services: services))
#endif
    }

    var body: some View {
#if os(macOS)
        if ["credit-expired", "credit-disabled", "credit-conflict", "credit-page-error"].contains(route) {
            Group {
                if scenarioPrepared {
                    if route == "credit-page-error" {
                        V15CreditMacView(model: scenarioModel, services: services)
                    } else {
                        V15CreditScheduleMacSheet(model: scenarioModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .v22PageCanvas()
                    }
                } else {
                    V15LoadingSkeleton()
                }
            }
            .task { await prepareMacScenario() }
        } else if route == "credit-unknown-offline-recovery" {
            V15CreditMacView(services: services, offlineSnapshotProvider: { offlineRecoveryMarker.snapshotAt })
        } else {
            V15CreditMacView(services: services, offlineSnapshotAt: route == "credit-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
        }
#else
        Group {
            if route == "credit-unknown-offline-recovery" {
                V15CreditView(services: services, offlineSnapshotProvider: { offlineRecoveryMarker.snapshotAt })
            } else {
                V15CreditView(services: services, offlineSnapshotAt: route == "credit-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil)
            }
        }
        .onChange(of: scenePhase) { old, new in
            guard route == "credit-unknown-offline-recovery" else { return }
            if old == .active && new != .active { hasBackgrounded = true }
            if new == .active && hasBackgrounded { offlineRecoveryMarker.snapshotAt = nil }
        }
#endif
}

#if os(macOS)
    @MainActor private func prepareMacScenario() async {
        guard !scenarioPrepared else { return }
        await scenarioModel.load()
        if route == "credit-page-error" {
            await scenarioModel.loadNextCycles()
        } else {
            scenarioModel.openScheduleSheet()
            scenarioModel.cycleMode = .statementDayCutoff
            scenarioModel.statementDayText = "25"
            scenarioModel.dueDayText = "10"
            await scenarioModel.requestSchedulePreview()
            if route == "credit-conflict" { await scenarioModel.commitSchedule() }
        }
        scenarioPrepared = true
    }
#endif
}

private struct V15F3AGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F3AFixtures.services(route: route) }
    var body: some View {
#if os(macOS)
        V15FutureTimelineMacView(services: services, offlineSnapshotAt: route == "timeline-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialAutoLoadNext: route == "timeline-page-error")
#else
        V15FutureTimelineView(services: services, offlineSnapshotAt: route == "timeline-offline" ? Date(timeIntervalSince1970: 1_786_464_000) : nil, initialAutoLoadNext: route == "timeline-page-error")
#endif
    }
}

private struct V15F1CGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F1CFixtures.services(conflict: route == "master-conflict") }
    var body: some View {
        if route == "settings" { V15SettingsView(services: services) }
        else if route == "master" || route == "master-conflict" { V15MasterDataView(services: services) }
        else if route == "master-offline" { V15MasterDataView(services: services, offlineSnapshotAt: Date(timeIntervalSince1970: 1_786_464_000)) }
        else { V15EmptyState(title: "无法识别主数据路由", explanation: "该链接只可用于并行主数据检查。") }
    }
}

private struct V15F1AGalleryRoute: View {
    let route: String
    @MainActor private var services: V15Services { V15F1AFixtures.services() }
    @MainActor private func makeRecord() -> V15RecordModel {
        let record = V15RecordModel(services: services, occurredOn: V15F1AFixtures.businessDate)
        if route == "record-valid" {
            record.title = "午餐"; record.amountText = "12.80"
            record.accountID = V15F1AFixtures.accountID; record.categoryID = V15F1AFixtures.categoryID
        } else if route == "repayment-valid" {
            record.kind = .repayment; record.title = "信用卡还款"; record.amountText = "12.80"
            record.accountID = V15F1AFixtures.accountID; record.destinationAccountID = V15F1AFixtures.creditID
            record.creditCycleID = V15F1AFixtures.creditCycleID
        }
        return record
    }
    var body: some View {
        Group {
            if route == "bootstrap" { V15BootstrapView(services: services) }
            else { V15RecordView(model: makeRecord(), services: services) }
        }
        .accessibilityIdentifier("v15.f1a.gallery.\(route)")
    }
}
