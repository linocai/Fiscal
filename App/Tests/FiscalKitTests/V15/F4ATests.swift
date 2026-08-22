import Foundation
import Testing
@testable import FiscalKit

@Suite("F4-A report facts and same-revision drill-down")
struct F4ATests {
    @Test("period bounds and forward-compatible report enums are display-only")
    func boundsAndEnums() throws {
        #expect(V15ReportMonth("0001-01") == nil)
        #expect(V15ReportMonth("9999-01") == nil)
        #expect(V15ReportYear("0001") == nil)
        #expect(V15ReportYear("9998") != nil)
        let unknown = try V15FixtureCodec.decoder.decode(V15PeriodReport.self, from: Data(V15F4AFixtures.report(unknown: true).utf8))
        #expect(unknown.meta.periodKind == .unknown("future_period_kind"))
        #expect(unknown.sources.last?.drillCapability == .disabled("此汇总没有可安全定位的明细筛选条件"))
        #expect(unknown.categories.last?.drillCapability == .disabled("此汇总没有可安全定位的明细筛选条件"))
        #expect(unknown.merchants.last?.drillCapability == .disabled("此汇总没有可安全定位的明细筛选条件"))
        let unknownAccount = try V15FixtureCodec.decoder.decode(V15PeriodReport.self, from: Data(V15F4AFixtures.report(unknownAccount: true).utf8))
        #expect(unknownAccount.accounts.first?.accountKind == .unknown("future_report_account_kind"))
        #expect(unknownAccount.accounts.first?.drillCapability == .disabled("此汇总没有可安全定位的明细筛选条件"))
    }

    @MainActor @Test("typed drill item retains Int64 facts and service never forms an unfiltered period query")
    func typedDrillAndWire() async throws {
        let transport = F4ATransport(mode: .normal)
        let service = V15Services(transport: transport).reports
        let month = try #require(V15ReportMonth("2026-08"))
        let page = try await service.periodDrillDown(period: .month(month), expectedRevision: 77, filter: .category(V15F4AFixtures.categoryID), limit: 50)
        #expect(page.items.first?.transactionID == V15F4AFixtures.transactionID)
        #expect(page.items.first?.netConsumptionMinor == 28_000)
        let request = try #require(await transport.allRequests().last)
        #expect(request.path == "reports/period-drill-down")
        #expect(request.query == [
            .init(name: "period_kind", value: "month"), .init(name: "period", value: "2026-08"),
            .init(name: "expected_data_revision", value: "77"), .init(name: "limit", value: "50"),
            .init(name: "category_id", value: V15F4AFixtures.categoryID.uuidString)
        ])
        do {
            _ = try await service.periodDrillDown(period: .month(month), expectedRevision: 77, filter: .source(.unknown("future")), limit: 50)
            Issue.record("unknown source must remain display-only")
        } catch let failure as V15Failure { #expect(failure.code == "unsafe_period_report_filter") }
        #expect(await transport.allRequests().filter { $0.path == "reports/period-drill-down" }.count == 1)
    }

    @MainActor @Test("disabled aggregate rows issue zero drill requests while enabled rows bind period revision filter and paging")
    func capabilityAndOwner() async throws {
        let transport = F4ATransport(mode: .normal)
        let model = V15ReportingModel(services: V15Services(transport: transport))
        await model.load()
        let report = try #require(model.report)
        await model.openDrill(capability: report.categories.last!.drillCapability, label: "未分类")
        #expect(model.disabledReason == "此汇总没有可安全定位的明细筛选条件")
        #expect(await transport.allRequests().filter { $0.path == "reports/period-drill-down" }.isEmpty)
        let firstOwner = try #require(model.beginDrill(capability: report.categories.first!.drillCapability, label: "分类"))
        await model.loadDrill(owner: firstOwner)
        #expect(model.owner.revision == report.meta.dataRevision)
        #expect(model.drillItems.count == 1 && model.hasNextPage)
        await model.loadNextPage()
        #expect(model.drillItems.count == 2 && !model.hasNextPage)
        let drills = await transport.allRequests().filter { $0.path == "reports/period-drill-down" }
        #expect(drills.count == 2)
        #expect(drills.allSatisfy { $0.query.contains(.init(name: "expected_data_revision", value: "77")) && $0.query.contains(.init(name: "category_id", value: V15F4AFixtures.categoryID.uuidString)) })

        model.dismissDrill()
        await model.togglePeriodKind()
        await model.togglePeriodKind()
        let changedPeriodReport = try #require(model.report)
        await model.openDrill(capability: changedPeriodReport.categories.first!.drillCapability, label: "切换后的分类")
        #expect(model.drillItems.count == 1 && model.hasNextPage)
    }

    @MainActor @Test("conflict clears selection and reload is cache-bypassing")
    func conflictRecovery() async throws {
        let transport = F4ATransport(mode: .conflict)
        let model = V15ReportingModel(services: V15Services(transport: transport))
        await model.load()
        let category = try #require(model.report?.categories.first)
        await model.openDrill(capability: category.drillCapability, label: category.categoryName)
        guard case .requiresReload = model.phase else { Issue.record("409 must stop the current revision"); return }
        #expect(model.drillItems.isEmpty && model.owner.filter == nil)
        await model.reloadFresh()
        #expect(await transport.allRequests().contains { $0.path == "reports/monthly/2026-08" && $0.readCachePolicy == .reloadIgnoringCache })
    }

    @MainActor @Test("completeness-only report remains loaded and lens changes invalidate every drill owner state")
    func completenessAndLensInvalidation() async throws {
        let completenessOnly = V15ReportingModel(services: V15Services(transport: F4ATransport(mode: .completenessOnly)))
        await completenessOnly.load()
        guard case .loaded = completenessOnly.phase else { Issue.record("nonzero completeness facts are a loaded report"); return }
        completenessOnly.selectLens(.completeness)
        #expect(completenessOnly.report?.completeness.unresolvedImportCount == 1)
        #expect(completenessOnly.report?.completeness.failedImportCount == 2)
        #expect(completenessOnly.report?.completeness.uncategorizedTransactionCount == 3)
        #expect(completenessOnly.report?.completeness.openReconciliationDifferenceCount == 4)

        let model = V15ReportingModel(services: V15Services(transport: F4ATransport(mode: .normal)))
        await model.load()
        let category = try #require(model.report?.categories.first)
        await model.openDrill(capability: category.drillCapability, label: category.categoryName)
        let drilledOwner = model.owner
        #expect(!model.drillItems.isEmpty && model.selectedDrillLabel != nil)
        model.selectLens(.merchants)
        #expect(model.owner != drilledOwner)
        #expect(model.owner.filter == nil && model.drillItems.isEmpty && model.selectedDrillLabel == nil)
        #expect(model.drillFailure == nil && model.pageFailure == nil)
    }

    @MainActor @Test("first-page drill failure retries the exact owner while offline status follows services dynamically")
    func firstPageRetryAndDynamicOffline() async throws {
        let transport = F4ATransport(mode: .drillFirstFailure)
        let model = V15ReportingModel(services: V15Services(transport: transport))
        await model.load()
        let category = try #require(model.report?.categories.first)
        let owner = try #require(model.beginDrill(capability: category.drillCapability, label: category.categoryName))
        await model.loadDrill(owner: owner)
        guard case .failed = model.drillPhase else { Issue.record("first page failure must not masquerade as append failure"); return }
        #expect(model.pageFailure == nil && model.drillItems.isEmpty)
        await model.retryCurrentDrill()
        #expect(model.owner == owner && model.drillItems.count == 1)
        let drills = await transport.allRequests().filter { $0.path == "reports/period-drill-down" }
        #expect(drills.count == 2)
        #expect(drills.allSatisfy { $0.query.contains(.init(name: "expected_data_revision", value: "77")) && $0.query.contains(.init(name: "category_id", value: V15F4AFixtures.categoryID.uuidString)) && !$0.query.contains(where: { $0.name == "cursor" }) })

        let empty = V15ReportingModel(services: V15Services(transport: F4ATransport(mode: .drillEmpty)))
        await empty.load()
        let emptyCategory = try #require(empty.report?.categories.first)
        await empty.openDrill(capability: emptyCategory.drillCapability, label: emptyCategory.categoryName)
        #expect(empty.drillItems.isEmpty && empty.drillFailure == nil && empty.drillPhase == .idle)

        let loading = V15ReportingModel(services: V15Services(transport: F4ATransport(mode: .drillLoading)))
        await loading.load()
        let loadingCategory = try #require(loading.report?.categories.first)
        let loadingOwner = try #require(loading.beginDrill(capability: loadingCategory.drillCapability, label: loadingCategory.categoryName))
        let loadingTask = Task { @MainActor in await loading.loadDrill(owner: loadingOwner) }
        await Task.yield()
        #expect(loading.drillPhase == .loading)
        await loadingTask.value

        let revisionStore = DataRevisionStore(defaults: nil)
        let dynamic = V15ReportingModel(services: V15Services(transport: F4ATransport(mode: .normal), revisionStore: revisionStore))
        await dynamic.load()
        #expect(dynamic.offlineSnapshotAt == nil)
        let snapshotAt = Date(timeIntervalSince1970: 1_786_464_000)
        revisionStore.markOfflineSnapshot(at: snapshotAt)
        #expect(dynamic.isOffline && dynamic.offlineSnapshotAt == snapshotAt)
    }

    @MainActor @Test("unknown account kind is display-only and issues zero period drill requests")
    func unknownAccountZeroWire() async throws {
        let transport = F4ATransport(mode: .unknownAccount)
        let model = V15ReportingModel(services: V15Services(transport: transport))
        await model.load()
        let account = try #require(model.report?.accounts.first)
        await model.openDrill(capability: account.drillCapability, label: account.accountName)
        #expect(model.disabledReason == "此汇总没有可安全定位的明细筛选条件")
        #expect(await transport.allRequests().filter { $0.path == "reports/period-drill-down" }.isEmpty)
    }
}

@Suite("F4-B revision-bound report export")
struct F4BTests {
    @MainActor @Test("export sends the visible revision and only accepts matching response metadata")
    func revisionBoundExport() async throws {
        let transport = F4ATransport(mode: .normal)
        let model = V15ReportingModel(services: V15Services(transport: transport))
        await model.load(); model.beginExport(.csv); await model.exportConfirmed()
        guard case .ready(let artifact) = model.exportPhase else { Issue.record("matching header should produce a local handoff"); return }
        #expect(artifact.dataRevision == 77 && artifact.filename.hasSuffix(".csv"))
        let request = try #require(await transport.allRequests().last)
        #expect(request.path == "reports/monthly/2026-08/export.csv")
        #expect(request.query == [.init(name: "expected_data_revision", value: "77")])
        model.dismissExport()
        #expect(model.exportURL == nil)
    }

    @MainActor @Test("missing or mismatched metadata fails closed and never retains a file")
    func invalidMetadataFailsClosed() async {
        for mode in [F4ATransport.Mode.exportStale, .exportMissingHeader, .exportBadFilename] {
            let model = V15ReportingModel(services: V15Services(transport: F4ATransport(mode: mode)))
            await model.load(); model.beginExport(.pdf); await model.exportConfirmed()
            guard case .failed = model.exportPhase else { Issue.record("\(mode) must fail closed"); continue }
            #expect(model.exportURL == nil)
        }
    }

    @MainActor @Test("offline and changed report owner issue zero export requests")
    func disabledAndOwnerInvalidation() async throws {
        let offlineTransport = F4ATransport(mode: .offline)
        let offline = V15ReportingModel(services: V15Services(transport: offlineTransport), offlineSnapshotAt: .now)
        await offline.load(); offline.beginExport(.csv)
        #expect(await offlineTransport.allRequests().filter { $0.path.contains("export") }.isEmpty)

        let transport = F4ATransport(mode: .normal)
        let model = V15ReportingModel(services: V15Services(transport: transport))
        await model.load(); model.beginExport(.csv); await model.selectPeriod(.year(try #require(V15ReportYear("2026"))))
        await model.exportConfirmed()
        #expect(await transport.allRequests().filter { $0.path.contains("export") }.isEmpty)
    }

    @MainActor @Test("409 and unknown export results preserve no local artifact and require a fresh decision")
    func exportConflictAndUnknown() async {
        for mode in [F4ATransport.Mode.exportConflict, .exportUnknown] {
            let model = V15ReportingModel(services: V15Services(transport: F4ATransport(mode: mode)))
            await model.load(); model.beginExport(.csv); await model.exportConfirmed()
            guard case .requiresReload = model.exportPhase else { Issue.record("\(mode) must block the old export owner"); continue }
            #expect(model.exportURL == nil)
        }
    }

    @MainActor @Test("a 409 gate survives dismissal and only a fresh read unlocks the next revision")
    func staleGateRequiresFreshReload() async throws {
        let transport = F4ATransport(mode: .exportConflictThenFresh)
        let model = V15ReportingModel(services: V15Services(transport: transport))
        await model.load(); model.beginExport(.csv); await model.exportConfirmed()
        guard case .requiresReload = model.exportPhase else { Issue.record("409 must establish a persistent export gate"); return }
        model.dismissExport(); model.beginExport(.pdf); await model.exportConfirmed()
        #expect(await transport.allRequests().filter { $0.path.contains("export") }.count == 1)
        await model.reloadFresh()
        #expect(model.report?.meta.dataRevision == 78)
        model.beginExport(.pdf); await model.exportConfirmed()
        let exports = await transport.allRequests().filter { $0.path.contains("export") }
        #expect(exports.count == 2)
        #expect(exports.last?.query == [.init(name: "expected_data_revision", value: "78")])
        #expect(await transport.allRequests().contains { $0.path == "reports/monthly/2026-08" && $0.readCachePolicy == .reloadIgnoringCache })
    }

    @MainActor @Test("temporary artifacts preserve the server basename; cancel, retry, and overwrite never re-GET")
    func temporaryNameAndLocalSaveLifecycle() async throws {
        let transport = F4ATransport(mode: .normal)
        let model = V15ReportingModel(services: V15Services(transport: transport))
        await model.load(); model.beginExport(.csv); await model.exportConfirmed()
        let artifact = try #require({ if case .ready(let value) = model.exportPhase { value } else { nil } }())
        let temporary = try #require(model.exportURL)
        #expect(temporary.lastPathComponent == artifact.filename)
        let directory = temporary.deletingLastPathComponent()
        await model.saveReadyArtifact(using: F4BSaveService(mode: .cancelled))
        #expect(model.exportURL == nil && !FileManager.default.fileExists(atPath: directory.path))
        #expect(await transport.allRequests().filter { $0.path.contains("export") }.count == 1)

        model.beginExport(.csv); await model.exportConfirmed()
        let retryDirectory = try #require(model.exportURL).deletingLastPathComponent()
        let retrySaver = F4BSaveService(mode: .failThenSaved)
        await model.saveReadyArtifact(using: retrySaver)
        guard case .saveFailed = model.exportPhase else { Issue.record("save failure must retain the validated temporary artifact for retry"); return }
        await model.retrySave(using: retrySaver)
        guard case .completed = model.exportPhase else { Issue.record("retry must finish local handoff"); return }
        #expect(model.exportURL == nil && !FileManager.default.fileExists(atPath: retryDirectory.path))
        #expect(await transport.allRequests().filter { $0.path.contains("export") }.count == 2)

        model.beginExport(.pdf); await model.exportConfirmed()
        let overwriteArtifact = try #require({ if case .ready(let value) = model.exportPhase { value } else { nil } }())
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("FiscalF4BOverwrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }
        let existingDestination = destinationDirectory.appendingPathComponent(overwriteArtifact.filename)
        try Data("older local export".utf8).write(to: existingDestination)
        await model.saveReadyArtifact(using: F4BOverwriteSaveService(destinationURL: existingDestination))
        guard case .completed = model.exportPhase else { Issue.record("an existing chosen filename must be atomically replaced"); return }
        #expect(try Data(contentsOf: existingDestination) == Data("synthetic export".utf8))
        #expect(model.exportURL == nil)
        #expect(await transport.allRequests().filter { $0.path.contains("export") }.count == 3)
    }
}

actor F4BSaveService: V15ReportArtifactSaving {
    enum Mode: Equatable { case cancelled, failThenSaved }
    private let mode: Mode
    private var attempts = 0
    init(mode: Mode) { self.mode = mode }
    func save(temporaryURL: URL, suggestedFilename: String) async throws -> V15ReportArtifactSaveResult {
        attempts += 1
        #if DEBUG
        precondition(temporaryURL.lastPathComponent == suggestedFilename)
        #endif
        if mode == .cancelled { return .cancelled }
        if attempts == 1 { throw V15Failure(kind: .transport, message: "fixture save failure") }
        return .saved
    }
}

actor F4BOverwriteSaveService: V15ReportArtifactSaving {
    private let destinationURL: URL
    init(destinationURL: URL) { self.destinationURL = destinationURL }
    func save(temporaryURL: URL, suggestedFilename: String) async throws -> V15ReportArtifactSaveResult {
        guard temporaryURL.lastPathComponent == suggestedFilename,
              destinationURL.lastPathComponent == suggestedFilename else {
            throw V15Failure(kind: .decoding, message: "fixture filename mismatch")
        }
        try V15ReportArtifactAtomicWriter.replace(temporaryURL: temporaryURL, destinationURL: destinationURL)
        return .saved
    }
}
