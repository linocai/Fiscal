import Foundation
import Observation

public enum V15ReportArtifactSaveResult: Sendable { case saved, cancelled }

/// The model owns artifact lifetime; the platform owns only the native handoff.
public protocol V15ReportArtifactSaving: Sendable {
    func save(temporaryURL: URL, suggestedFilename: String) async throws -> V15ReportArtifactSaveResult
}

/// A report owner freezes period, server revision and the only safe aggregate
/// filter. Nothing in this model derives totals or turns an absent ID into an
/// unfiltered ledger query.
@MainActor @Observable
public final class V15ReportingModel {
    public enum Phase: Equatable { case idle, loading, loaded, empty, failed(V15Failure), requiresReload(V15Failure) }
    public enum PagePhase: Equatable { case idle, loading, failed(V15Failure) }
    public enum ExportPhase: Equatable { case idle, confirming(V15ReportArtifactFormat), transferring(V15ReportArtifactFormat), ready(V15ReportArtifact), saving(V15ReportArtifact), saveFailed(V15ReportArtifact, V15Failure), completed(V15ReportArtifact), failed(V15Failure), requiresReload(V15Failure) }
    public enum Lens: String, CaseIterable, Sendable {
        case overview, spending, cashFlow, debt
        // Kept as model-compatible values for existing deep links/tests; the
        // product surface exposes only the four lenses above.
        case categories, merchants, accounts, sources, completeness
        public static var allCases: [Lens] { [.overview, .spending, .cashFlow, .debt] }
    }
    public enum SpendingMeasure: String, CaseIterable, Sendable {
        case grossConsumption, merchantRefund, netConsumption, expectedReimbursement, receivedReimbursement, personalExpected, personalRealized
    }
    public struct ReportOwner: Equatable, Sendable { public let period: V15ReportPeriod; public let revision: Int64?; public let filter: V15ReportDrillFilter?; public let generation: UInt64 }
    public struct ExportOwner: Equatable, Sendable { public let period: V15ReportPeriod; public let format: V15ReportArtifactFormat; public let expectedRevision: Int64; public let generation: UInt64 }

    public private(set) var phase: Phase = .idle
    public private(set) var pagePhase: PagePhase = .idle
    public private(set) var selectedPeriod: V15ReportPeriod
    public private(set) var lens: Lens = .overview
    public private(set) var spendingMeasure: SpendingMeasure = .personalRealized
    public private(set) var report: V15PeriodReport?
    public private(set) var drillItems: [V15PeriodReportDrillDown.Item] = []
    public private(set) var drillCapability: V15ReportDrillCapability?
    public private(set) var disabledReason: String?
    public private(set) var drillPhase: PagePhase = .idle
    public private(set) var drillFailure: V15Failure?
    public private(set) var pageFailure: V15Failure?
    public private(set) var selectedDrillLabel: String?
    public private(set) var owner: ReportOwner
    public private(set) var exportPhase: ExportPhase = .idle
    public private(set) var exportOwner: ExportOwner?
    public private(set) var exportURL: URL?
    private let services: V15Services
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?
    private var generation: UInt64 = 0
    private var nextCursor: String?
    private var needsFreshReload = false
    private var exportGeneration: UInt64 = 0
    private var exportReloadGate: V15Failure?

    public init(services: V15Services, initialPeriod: V15ReportPeriod = .month(V15ReportMonth("2026-08")!), offlineSnapshotAt: Date? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil) {
        self.services = services; self.selectedPeriod = initialPeriod
        self.offlineSnapshotProvider = offlineSnapshotProvider ?? { offlineSnapshotAt ?? services.offlineSnapshotAt }
        owner = .init(period: initialPeriod, revision: nil, filter: nil, generation: 0)
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var hasNextPage: Bool { nextCursor != nil }
    public var isPaging: Bool { if case .loading = pagePhase { true } else { false } }
    public var periodLabel: String { selectedPeriod.rawValue }
    public var canDrill: Bool { if case .enabled = drillCapability { true } else { false } }
    public var exportDisabledReason: String? {
        if exportReloadGate != nil { return "报表数据已更新；请读取最新内容后重新决定。" }
        if isOffline { return "离线时不能导出；请恢复连接并刷新报表。" }
        guard (phase == .loaded || phase == .empty), let report, report.meta.dataRevision >= 0 else { return "请先读取当前正式报表后再导出。" }
        if case .transferring = exportPhase { return "正在导出当前报表。" }
        return nil
    }

    public func beginExport(_ format: V15ReportArtifactFormat) {
        guard exportDisabledReason == nil, let report else { return }
        invalidateExport(removeFile: true)
        exportPhase = .confirming(format)
        exportOwner = .init(period: selectedPeriod, format: format, expectedRevision: report.meta.dataRevision, generation: exportGeneration)
    }
    public func cancelExport() { invalidateExport(removeFile: true) }
    /// A stale export is a persistent decision gate: presentation dismissal
    /// cannot make the old report revision eligible for another request.
    public func dismissExport() { invalidateExport(removeFile: true) }
    public func exportConfirmed() async {
        guard case .confirming(let format) = exportPhase, let captured = exportOwner, captured.format == format,
              captured.period == selectedPeriod, captured.expectedRevision == report?.meta.dataRevision, !isOffline else { return }
        exportPhase = .transferring(format)
        do {
            let artifact: V15ReportArtifact
            switch captured.period { case .month(let period): artifact = try await services.reports.monthlyArtifact(period, format: format, expectedDataRevision: captured.expectedRevision); case .year(let period): artifact = try await services.reports.yearlyArtifact(period, format: format, expectedDataRevision: captured.expectedRevision) }
            guard exportOwner == captured, exportGeneration == captured.generation, artifact.dataRevision == captured.expectedRevision else { return }
            let url = try Self.writeTemporary(artifact)
            guard exportOwner == captured, exportGeneration == captured.generation else { removeTemporary(url); return }
            exportURL = url; exportPhase = .ready(artifact)
        } catch let failure as V15Failure {
            guard exportOwner == captured, exportGeneration == captured.generation else { return }
            if failure.kind == .conflict || failure.kind == .responseUnknown {
                exportReloadGate = failure
                invalidateExport(removeFile: true)
            }
            else { exportPhase = failure.kind == .cancelled ? .idle : .failed(failure) }
        } catch {
            guard exportOwner == captured, exportGeneration == captured.generation else { return }
            exportPhase = .failed(.init(kind: .transport, message: "无法安全保存导出文件。"))
        }
    }

    public func saveReadyArtifact(using saver: any V15ReportArtifactSaving) async {
        guard case .ready(let artifact) = exportPhase, let url = exportURL,
              url.lastPathComponent == artifact.filename else { return }
        let captured = exportOwner
        exportPhase = .saving(artifact)
        do {
            let result = try await saver.save(temporaryURL: url, suggestedFilename: artifact.filename)
            guard exportOwner == captured, exportURL == url else { return }
            switch result {
            case .saved:
                removeTemporary(url); exportURL = nil; exportOwner = nil; exportPhase = .completed(artifact)
            case .cancelled:
                invalidateExport(removeFile: true)
            }
        } catch {
            guard exportOwner == captured, exportURL == url else { return }
            exportPhase = .saveFailed(artifact, .init(kind: .transport, code: "report_save_failed", message: "无法保存导出文件。"))
        }
    }

    public func retrySave(using saver: any V15ReportArtifactSaving) async {
        guard case .saveFailed(let artifact, _) = exportPhase, exportURL?.lastPathComponent == artifact.filename else { return }
        exportPhase = .ready(artifact)
        await saveReadyArtifact(using: saver)
    }

    public func load() async { await reload(fresh: needsFreshReload) }
    public func reloadFresh() async { await reload(fresh: true) }
    public func selectLens(_ lens: Lens) {
        guard self.lens != lens else { return }
        self.lens = lens
        invalidateDrillForPresentationChange()
    }
    public func selectSpendingMeasure(_ measure: SpendingMeasure) {
        guard spendingMeasure != measure else { return }
        spendingMeasure = measure
        invalidateDrillForPresentationChange()
    }

    public func spendingAmount(in summary: V15PeriodReport.Summary) -> Int64 {
        spendingAmount(spendingMeasure, in: summary)
    }

    public func spendingAmount(_ measure: SpendingMeasure, in summary: V15PeriodReport.Summary) -> Int64 {
        switch measure {
        case .grossConsumption: summary.grossConsumptionMinor
        case .merchantRefund: summary.merchantRefundMinor
        case .netConsumption: summary.netConsumptionMinor
        case .expectedReimbursement: summary.expectedReimbursementMinor
        case .receivedReimbursement: summary.receivedReimbursementMinor
        case .personalExpected: summary.personalExpectedMinor
        case .personalRealized: summary.personalRealizedMinor
        }
    }

    public func categoryAmount(_ category: V15PeriodReport.Category, for measure: SpendingMeasure) -> Int64? {
        switch measure {
        case .grossConsumption: category.grossConsumptionMinor
        case .merchantRefund: category.merchantRefundMinor
        case .netConsumption: category.netConsumptionMinor
        case .expectedReimbursement: category.expectedReimbursementMinor
        case .receivedReimbursement: category.receivedReimbursementMinor
        case .personalExpected: category.personalExpectedMinor
        case .personalRealized: category.personalRealizedMinor
        }
    }

    public func selectPeriod(_ period: V15ReportPeriod) async {
        guard period != selectedPeriod else { return }
        selectedPeriod = period
        await reload(fresh: false)
    }

    public func movePeriod(by amount: Int) async {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var local = calendar; local.timeZone = timeZone
        let formatter = DateFormatter(); formatter.calendar = local; formatter.timeZone = timeZone
        switch selectedPeriod {
        case .month(let month):
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: "\(month.rawValue)-01"), let next = local.date(byAdding: .month, value: amount, to: date) else { return }
            formatter.dateFormat = "yyyy-MM"; guard let result = V15ReportMonth(formatter.string(from: next)) else { return }; await selectPeriod(.month(result))
        case .year(let year):
            guard let number = Int(year.rawValue), let result = V15ReportYear(String(number + amount)) else { return }; await selectPeriod(.year(result))
        }
    }

    public func togglePeriodKind() async {
        switch selectedPeriod {
        case .month(let month): await selectPeriod(.year(V15ReportYear(String(month.rawValue.prefix(4)))!))
        case .year(let year): await selectPeriod(.month(V15ReportMonth("\(year.rawValue)-01")!))
        }
    }

    public func openDrill(capability: V15ReportDrillCapability, label: String) async {
        guard let owner = beginDrill(capability: capability, label: label) else { return }
        await loadDrill(owner: owner)
    }

    /// Establishes the immutable report owner synchronously so platform views
    /// can present their inspector before the first page returns.
    public func beginDrill(capability: V15ReportDrillCapability, label: String) -> ReportOwner? {
        guard case .enabled(let filter) = capability else { if case .disabled(let reason) = capability { disabledReason = reason }; return nil }
        guard let report else { return nil }
        disabledReason = nil; selectedDrillLabel = label; drillItems = []; nextCursor = nil; drillFailure = nil; drillPhase = .idle; pageFailure = nil; pagePhase = .idle
        let newOwner = ReportOwner(period: selectedPeriod, revision: report.meta.dataRevision, filter: filter, generation: generation)
        owner = newOwner; drillCapability = capability
        return newOwner
    }

    public func loadDrill(owner: ReportOwner) async {
        guard owner == self.owner, owner.generation == generation else { return }
        drillPhase = .loading; drillFailure = nil
        await readDrill(cursor: nil, appending: false, owner: owner)
    }

    public func dismissDrill() { invalidateDrillForPresentationChange() }
    public func showDisabledReason(_ capability: V15ReportDrillCapability) { if case .disabled(let reason) = capability { disabledReason = reason } }

    public func loadNextPage() async {
        guard let cursor = nextCursor, !isPaging, let revision = owner.revision, let filter = owner.filter, owner.period == selectedPeriod else { return }
        let captured = ReportOwner(period: selectedPeriod, revision: revision, filter: filter, generation: owner.generation)
        pagePhase = .loading; pageFailure = nil
        await readDrill(cursor: cursor, appending: true, owner: captured)
    }
    public func retryNextPage() async { await loadNextPage() }

    /// A first-page retry must preserve the immutable period/revision/filter
    /// owner. Retrying the next cursor here would be a silent no-op and could
    /// not prove that the first request remains revision-bound.
    public func retryCurrentDrill() async {
        let captured = owner
        guard captured.revision != nil, captured.filter != nil, captured.period == selectedPeriod, captured.generation == generation else { return }
        await loadDrill(owner: captured)
    }

    private func reload(fresh: Bool) async {
        invalidateExport(removeFile: true)
        generation &+= 1
        let current = generation
        needsFreshReload = false; report = nil; drillItems = []; nextCursor = nil; selectedDrillLabel = nil; drillCapability = nil; disabledReason = nil; drillFailure = nil; drillPhase = .idle; pageFailure = nil; pagePhase = .idle
        owner = .init(period: selectedPeriod, revision: nil, filter: nil, generation: current)
        phase = .loading
        do {
            let result: V15PeriodReport
            switch selectedPeriod { case .month(let month): result = try await services.reports.monthly(month, readCachePolicy: fresh ? .reloadIgnoringCache : .standard); case .year(let year): result = try await services.reports.yearly(year, readCachePolicy: fresh ? .reloadIgnoringCache : .standard) }
            guard current == generation, valid(result, for: selectedPeriod) else { if current == generation { phase = .failed(.init(kind: .decoding, code: "invalid_period_report", message: "报表内容与当前期间不一致，请重新读取。")) }; return }
            report = result; owner = .init(period: selectedPeriod, revision: result.meta.dataRevision, filter: nil, generation: current)
            if fresh { exportReloadGate = nil; exportPhase = .idle }
            phase = rowsAreEmpty(result) ? .empty : .loaded
        } catch let failure as V15Failure {
            guard current == generation else { return }
            if failure.kind == .conflict { takeConflict(failure, current) } else { phase = failure.kind == .cancelled ? .idle : .failed(failure) }
        } catch { guard current == generation else { return }; phase = .failed(.init(kind: .transport, message: "报表读取失败。")) }
    }

    private func readDrill(cursor: String?, appending: Bool, owner captured: ReportOwner) async {
        guard let revision = captured.revision, let filter = captured.filter else { return }
        do {
            let page = try await services.reports.periodDrillDown(period: captured.period, expectedRevision: revision, filter: filter, cursor: cursor, limit: 50)
            guard captured == owner, captured.generation == generation, page.meta.dataRevision == revision, page.dimension == .ledger, pageMatches(page, filter: filter) else { if captured == owner { takeConflict(.init(kind: .conflict, code: "period_report_changed", message: "报表数据已经更新。"), captured.generation) }; return }
            drillItems = appending ? drillItems + page.items : page.items
            nextCursor = page.nextCursor
            if appending { pagePhase = .idle; pageFailure = nil }
            else { drillPhase = .idle; drillFailure = nil }
        } catch let failure as V15Failure {
            guard captured == owner, captured.generation == generation else { return }
            if failure.kind == .conflict { takeConflict(failure, captured.generation) }
            else if appending { pagePhase = failure.kind == .cancelled ? .idle : .failed(failure); pageFailure = failure.kind == .cancelled ? nil : failure }
            else { drillPhase = failure.kind == .cancelled ? .idle : .failed(failure); drillFailure = failure.kind == .cancelled ? nil : failure; drillItems = [] }
        } catch { guard captured == owner, captured.generation == generation else { return }; let failure = V15Failure(kind: .transport, message: appending ? "下一页报表明细读取失败。" : "报表明细读取失败。"); if appending { pagePhase = .failed(failure); pageFailure = failure } else { drillPhase = .failed(failure); drillFailure = failure; drillItems = [] } }
    }

    private func takeConflict(_ failure: V15Failure, _ current: UInt64) {
        guard current == generation else { return }
        needsFreshReload = true; report = nil; drillItems = []; nextCursor = nil; drillFailure = nil; drillPhase = .idle; pageFailure = nil; pagePhase = .idle; selectedDrillLabel = nil; drillCapability = nil
        owner = .init(period: selectedPeriod, revision: nil, filter: nil, generation: current); phase = .requiresReload(failure)
    }
    private func valid(_ report: V15PeriodReport, for period: V15ReportPeriod) -> Bool { report.meta.periodKind == period.kind && report.meta.period == period.rawValue && report.meta.timezone == "Asia/Shanghai" && report.meta.currency == "CNY" && report.meta.reportSchemaVersion == "2" && report.meta.dataRevision >= 0 }
    private func invalidateDrillForPresentationChange() {
        invalidateExport(removeFile: true)
        generation &+= 1
        owner = .init(period: selectedPeriod, revision: report?.meta.dataRevision, filter: nil, generation: generation)
        drillItems = []; nextCursor = nil; selectedDrillLabel = nil; drillCapability = nil; disabledReason = nil
        drillFailure = nil; drillPhase = .idle; pageFailure = nil; pagePhase = .idle
    }
    private func invalidateExport(removeFile: Bool) {
        exportGeneration &+= 1
        if removeFile, let exportURL { removeTemporary(exportURL) }
        exportURL = nil; exportOwner = nil
        exportPhase = exportReloadGate.map(ExportPhase.requiresReload) ?? .idle
    }
    private static func writeTemporary(_ artifact: V15ReportArtifact) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FiscalV15Exports", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(artifact.filename, isDirectory: false)
        try artifact.data.write(to: url, options: .atomic)
        return url
    }
    private func removeTemporary(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    private func rowsAreEmpty(_ report: V15PeriodReport) -> Bool {
        let completeness = report.completeness
        let summary = report.summary
        let hasSummaryFact = [
            summary.incomeMinor, summary.grossConsumptionMinor, summary.merchantRefundMinor,
            summary.netConsumptionMinor, summary.expectedReimbursementMinor, summary.receivedReimbursementMinor,
            summary.personalExpectedMinor, summary.personalRealizedMinor, summary.netIncomeExpenseMinor,
            summary.cashInflowMinor, summary.cashOutflowMinor, summary.cashNetMinor,
            summary.internalTransferInflowMinor, summary.internalTransferOutflowMinor,
            summary.creditDebtAtPeriodEndMinor, summary.reimbursementOutstandingAtPeriodEndMinor
        ].contains(where: { $0 != 0 })
        return !hasSummaryFact && report.accounts.isEmpty && report.categories.isEmpty && report.merchants.isEmpty && report.sources.isEmpty && (report.knownFutureEvents?.isEmpty ?? true) && (report.debtCycles?.isEmpty ?? true) && (report.installments?.isEmpty ?? true)
            && completeness.unresolvedImportCount == 0 && completeness.failedImportCount == 0
            && completeness.uncategorizedTransactionCount == 0 && completeness.openReconciliationDifferenceCount == 0
    }
    private func pageMatches(_ page: V15PeriodReportDrillDown, filter: V15ReportDrillFilter) -> Bool { switch filter { case .category(let id): page.categoryID == id && page.accountID == nil && page.merchantID == nil && page.source == nil; case .account(let id): page.accountID == id && page.categoryID == nil && page.merchantID == nil && page.source == nil; case .merchant(let id): page.merchantID == id && page.categoryID == nil && page.accountID == nil && page.source == nil; case .source(let source): page.source == source && page.categoryID == nil && page.accountID == nil && page.merchantID == nil } }
}
