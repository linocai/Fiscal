import CryptoKit
import Foundation
import Testing
@testable import FiscalKit

@Suite("2.2.1 client recovery")
struct V221ClientTests {
    @Test @MainActor func encryptedFilesIsolateProfilesAndRejectCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FiscalJournal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let first = V15JournalPersistence.encrypted(directory: directory, scope: "server|a", key: key)
        let second = V15JournalPersistence.encrypted(directory: directory, scope: "server|b", key: key)
        let secret = Data("private-request-title".utf8)
        try first.write(secret)
        #expect(try first.read() == secret)
        #expect(try second.read() == nil)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: file).range(of: secret) == nil)
        try Data("corrupt".utf8).write(to: file)
        #expect(throws: (any Error).self) { try first.read() }
    }

    @Test @MainActor func immutableJournalAndRestart() throws {
        let memory = JournalMemory()
        let persistence = V15JournalPersistence(read: { memory.data }, write: { memory.data = $0 })
        let store = V15PendingWriteStore(scope: "server-a|profile-a", persistence: persistence)
        let key = UUID(); let payload = JSONValue.object(["title": .string("original"), "amount_minor": .integer(123)])
        let id = try store.prepare(kind: .transactionCreate, title: "original", payload: payload, idempotencyKey: key)
        try store.markInFlight(id)
        #expect(throws: V15Failure.self) { try store.prepare(kind: .transactionCreate, title: "changed", payload: .null, idempotencyKey: key) }
        store.remove(id)
        #expect(store.item(id) != nil)
        let restarted = V15PendingWriteStore(scope: "server-a|profile-a", persistence: persistence)
        #expect(restarted.item(id)?.status == .outcomeUnknown)
        #expect(restarted.item(id)?.payload == payload)
        #expect(restarted.item(id)?.idempotencyKey == key)
        let otherScope = V15PendingWriteStore(scope: "server-b|profile-a", persistence: persistence)
        #expect(otherScope.storageFailure != nil)
        #expect(throws: V15Failure.self) { try otherScope.markInFlight(id) }
    }

    @Test @MainActor func storageFailureNeverSends() async {
        let persistence = V15JournalPersistence(read: { nil }, write: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let store = V15PendingWriteStore(scope: "test", persistence: persistence)
        let transport = JournalTransport()
        let model = V15RecordModel(services: V15Services(transport: transport, pendingWrites: store))
        await model.loadReferences()
        configure(model)
        _ = await model.submit()
        #expect(await transport.createCount == 0)
        #expect(store.storageFailure != nil)
    }

    @Test @MainActor func editingAndClosingInFlightKeepOriginalRequest() async throws {
        let transport = JournalTransport()
        let store = V15PendingWriteStore()
        let services = V15Services(transport: transport, pendingWrites: store)
        let model = V15RecordModel(services: services)
        await model.loadReferences(); configure(model)
        let first = Task { await model.submit() }
        while await transport.createCount == 0 { await Task.yield() }
        model.title = "changed"; model.note = "changed"; model.amountText = "88.00"
        #expect(model.hasUnresolvedSubmission)
        #expect(await model.submit() == nil)
        model.dismiss()
        #expect(store.items.count == 1)
        _ = await first.value
        #expect(services.confirmedWriteRevision == 1)
        #expect(await transport.createCount == 1)
        #expect(store.items.isEmpty)
        #expect(!model.hasUnresolvedSubmission)
    }

    @Test @MainActor func lostResponseRecoversAfterRestartWithoutCreatingAgain() async throws {
        let memory = JournalMemory()
        let persistence = V15JournalPersistence(read: { memory.data }, write: { memory.data = $0 })
        let store = V15PendingWriteStore(scope: "test", persistence: persistence)
        let transport = JournalTransport(loseResponse: true)
        let model = V15RecordModel(services: V15Services(transport: transport, pendingWrites: store))
        await model.loadReferences(); configure(model)
        _ = await model.submit()
        let original = try #require(store.items.first)
        #expect(original.status == .outcomeUnknown)
        model.dismiss()
        let recovered = V15PendingWriteStore(scope: "test", persistence: persistence)
        let services = V15Services(transport: transport, pendingWrites: recovered)
        await recovered.replay(using: services)
        #expect(recovered.items.isEmpty)
        #expect(await transport.createCount == 1)
    }

    @Test @MainActor func anotherWindowCompletingJournalCannotCreateAgain() async throws {
        let store = V15PendingWriteStore()
        let transport = JournalTransport(loseResponse: true)
        let services = V15Services(transport: transport, pendingWrites: store)
        let originalWindow = V15RecordModel(services: services)
        let otherWindow = V15RecordModel(services: services)
        await originalWindow.loadReferences(); await otherWindow.loadReferences()
        configure(originalWindow)
        _ = await originalWindow.submit()
        let id = try #require(store.items.first?.id)
        #expect(await store.recover(id, using: services))
        #expect(store.items.isEmpty)
        #expect(services.confirmedWriteRevision == 1)
        _ = await originalWindow.submit()
        #expect(await transport.createCount == 1)
        #expect(!originalWindow.hasUnresolvedSubmission)
        #expect(store.items.isEmpty)
    }

    @Test @MainActor func build41PersistedSnapshotRemainsReadableOnOfflineUpgrade() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FiscalUpgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyStore = SnapshotKeyStore(service: "FiscalKitTests.V221.\(UUID())")
        let token = "isolated-upgrade-token"
        let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let oldStore = OfflineSnapshotStore(directory: directory, keyStore: keyStore)
        await oldStore.store(Data(#"{"items":[],"next_cursor":null}"#.utf8), for: "https://upgrade.example/api/v1/transactions|\(digest)")
        let reopened = OfflineSnapshotStore(directory: directory, keyStore: keyStore)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UpgradeOfflineProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let revision = DataRevisionStore(defaults: nil)
        let client = APITransport(baseURL: URL(string: "https://upgrade.example")!, session: session, token: token,
            responseCache: HTTPResponseCache(), offlineSnapshots: reopened, revisionStore: revision)
        let page: TransactionPage = try await client.request("transactions")
        #expect(page.items.isEmpty)
        #expect(revision.offlineSnapshotAt != nil)
    }

    @Test @MainActor func legacyMigrationIsLosslessAndFailClosed() throws {
        let suite = "FiscalJournalTest-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = V15PendingWriteStore()
        let request = V15TransactionCreateRequest(kind: .expense, amountMinor: 123, occurredAt: Date(), title: "legacy", note: nil, accountID: V15F1AFixtures.accountID, categoryID: nil, destinationAccountID: nil, creditCycleID: nil)
        let id = old.enqueueCreate(request)
        try old.markInFlight(id)
        let bytes = try JSONEncoder().encode(old.items)
        defaults.set(bytes, forKey: "legacy")
        let failing = V15JournalPersistence(read: { nil }, write: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let blocked = V15PendingWriteStore(defaults: defaults, storageKey: "legacy", persistence: failing)
        #expect(blocked.storageFailure != nil)
        #expect(defaults.data(forKey: "legacy") == bytes)
        let memory = JournalMemory()
        let migrated = V15PendingWriteStore(defaults: defaults, storageKey: "legacy", persistence: .init(read: { memory.data }, write: { memory.data = $0 }))
        #expect(defaults.data(forKey: "legacy") == nil)
        #expect(migrated.item(id)?.createRequest == request)
        #expect(migrated.item(id)?.status == .outcomeUnknown)
    }

    @Test func cacheEvictsLRUAndExpiresOnUnrelatedRead() async {
        let cache = HTTPResponseCache(maxEntries: 2, maxPayloadBytes: 6, maxSingleResponseBytes: 4)
        let now = Date()
        await cache.store(Data([1, 2]), for: "a", now: now)
        await cache.store(Data([3, 4]), for: "b", now: now)
        _ = await cache.data(for: "a", now: now)
        await cache.store(Data([5, 6]), for: "c", now: now)
        #expect(await cache.data(for: "b", now: now) == nil)
        #expect(await cache.snapshot(now: now).byteCount == 4)
        await cache.store(Data(repeating: 0, count: 5), for: "oversized", now: now)
        #expect(await cache.snapshot(now: now).entryCount == 2)
        _ = await cache.data(for: "missing", now: now.addingTimeInterval(31))
        #expect(await cache.snapshot(now: now.addingTimeInterval(31)).entryCount == 0)
    }

    @Test @MainActor func lensSwitchDuringReadCompletesAndBalancesRemainUnknown() async throws {
        let transport = DelayedReportTransport()
        let model = V15ReportingModel(services: V15Services(transport: transport))
        let loading = Task { await model.load() }
        while await !transport.started { await Task.yield() }
        model.selectLens(.cashFlow)
        await loading.value
        #expect(model.phase == .loaded)
        #expect(model.lens == .cashFlow)
        let report = try #require(model.report)
        #expect(report.summary.creditDebtAtPeriodEndMinor == nil)
        #expect(report.accounts.first?.closingBalanceMinor == -100)
        #expect(V15MoneyPresentation(minorUnits: -100, direction: .balance).text.contains("−"))
        #expect(!V15MoneyPresentation(minorUnits: Int64.min, direction: .balance).text.isEmpty)
    }

    @Test func reportCapabilityNegotiationUsesRealHTTPBoundary() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReportCapabilityProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let supported = APITransport(baseURL: URL(string: "https://supported.example")!, session: session, token: "fixture")
        let value: V15PeriodReport = try await supported.request("reports/v2/monthly/2026-08", cache: false)
        #expect(value.summary.incomeMinor == 100000)
        let old = APITransport(baseURL: URL(string: "https://legacy.example")!, session: session, token: "fixture")
        do {
            let _: V15PeriodReport = try await old.request("reports/v2/monthly/2026-08", cache: false)
            Issue.record("a response without capability echo must fail closed")
        } catch let failure as FiscalAPIError { #expect(failure.code == "report_balance_semantics_unavailable") }
        do {
            _ = try await old.rawDataGETResponse("reports/v2/monthly/2026-08/export.csv", accept: "text/csv")
            Issue.record("artifact without capability echo must fail closed")
        } catch let failure as FiscalAPIError { #expect(failure.code == "report_balance_semantics_unavailable") }
    }

    @Test func recoveredReceiptInvalidatesEarlierReadCache() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReportCapabilityProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let cache = HTTPResponseCache()
        await cache.store(Data("old-account-balance".utf8), for: "old-account-read")
        let transport = APITransport(baseURL: URL(string: "https://supported.example")!, session: session, token: "fixture", responseCache: cache)
        let _: V15Transaction = try await transport.request("transactions/by-idempotency/\(UUID())", cache: false)
        #expect(await cache.data(for: "old-account-read") == nil)
    }

    @Test @MainActor func unknownCategoryConvergesByAuthoritativeVersion() async throws {
        let target = UUID()
        let draft = V15TransactionCreateRequest(kind: .expense, amountMinor: 1280, occurredAt: Date(), title: "category", note: nil, accountID: V15F1AFixtures.accountID, categoryID: target, destinationAccountID: nil, creditCycleID: nil)
        for scenario in 0...2 {
            let transport = CategoryRecoveryTransport(version: scenario == 1 ? 2 : 1, categoryID: scenario == 2 ? target : nil)
            let store = V15PendingWriteStore()
            let services = V15Services(transport: transport, pendingWrites: store)
            let id = store.enqueueCategory(transactionID: UUID(), transactionTitle: "category", amountMinor: 1280, request: .init(draft: draft, expectedVersion: 1))
            store.markUnknown(id)
            if scenario == 0 {
                #expect(await store.replayUnknown(id, using: services))
                #expect(await transport.putCount == 1)
                #expect(store.items.isEmpty)
            } else if scenario == 1 {
                #expect(!(await store.replayUnknown(id, using: services)))
                #expect(store.item(id)?.status == .requiresDecision)
                #expect(await transport.putCount == 0)
                store.remove(id); #expect(store.items.isEmpty)
            } else {
                #expect(await store.recover(id, using: services))
                #expect(await transport.putCount == 0)
                #expect(store.items.isEmpty)
            }
        }
    }

    @Test func definiteRejectionRequiresReceivedClientError() {
        let detail = APIErrorDetail(code: "rejected", message: "Rejected", details: nil, requestID: "test")
        #expect(V15ErrorMapper.map(.domain(status: 409, detail: detail)).isDefinitiveRejection)
        #expect(V15ErrorMapper.map(.domain(status: 422, detail: detail)).isDefinitiveRejection)
        #expect(V15ErrorMapper.map(.unauthorized(nil)).isDefinitiveRejection)
        #expect(V15ErrorMapper.map(.rateLimited).isDefinitiveRejection)
        #expect(!V15ErrorMapper.map(.domain(status: 503, detail: detail)).isDefinitiveRejection)
        #expect(!V15ErrorMapper.map(.transport("lost")).isDefinitiveRejection)
        #expect(!V15ErrorMapper.map(.invalidResponse).isDefinitiveRejection)
    }

    @Test @MainActor func recoveredCategoryInvalidatesCachedListBeforeRefreshEvent() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CategoryRecoveredProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let cache = HTTPResponseCache()
        let digest = SHA256.hash(data: Data("fixture".utf8)).map { String(format: "%02x", $0) }.joined()
        let staleTransaction = String(decoding: V15F1AFixtures.transaction, as: UTF8.self).replacingOccurrences(of: "午餐", with: "stale-list")
        let stalePage = Data("{\"items\":[\(staleTransaction)],\"next_cursor\":null}".utf8)
        await cache.store(stalePage, for: "https://category.example/api/v1/transactions|\(digest)")
        let directory = FileManager.default.temporaryDirectory.appending(path: "FiscalCategoryCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = OfflineSnapshotStore(directory: directory, keyStore: .init(service: "FiscalKitTests.CategoryCache.\(UUID())"))
        let api = APITransport(baseURL: URL(string: "https://category.example")!, session: session, token: "fixture", responseCache: cache, offlineSnapshots: snapshots)
        let before: V15Page<V15Transaction> = try await api.request("transactions")
        #expect(before.items.first?.title == "stale-list")
        let store = V15PendingWriteStore()
        let services = V15Services(transport: V15APITransportAdapter(transport: api), pendingWrites: store)
        let target = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        let draft = V15TransactionCreateRequest(kind: .expense, amountMinor: 1280, occurredAt: Date(), title: "category", note: nil, accountID: V15F1AFixtures.accountID, categoryID: target, destinationAccountID: nil, creditCycleID: nil)
        let id = store.enqueueCategory(transactionID: UUID(), transactionTitle: "category", amountMinor: 1280, request: .init(draft: draft, expectedVersion: 1))
        store.markUnknown(id)
        #expect(await store.recover(id, using: services))
        #expect(services.confirmedWriteRevision == 1)
        let refreshed: V15Page<V15Transaction> = try await api.request("transactions")
        #expect(refreshed.items.first?.title == "午餐")
        #expect(store.items.isEmpty)
    }

    @MainActor private func configure(_ model: V15RecordModel) {
        model.title = "original"; model.amountText = "1.23"; model.accountID = V15F1AFixtures.accountID
    }
}

@MainActor private final class JournalMemory { var data: Data? }
private actor JournalTransport: V15Transporting {
    private(set) var createCount = 0
    private let loseResponse: Bool
    private var receipts: Set<String> = []
    init(loseResponse: Bool = false) { self.loseResponse = loseResponse }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let data: Data
        if request.path == "accounts" { data = V15F1AFixtures.accounts }
        else if request.path == "categories" { data = V15F1AFixtures.categories }
        else if request.path == "transactions", request.method == "POST" {
            createCount += 1
            receipts.insert(request.headers["Idempotency-Key"] ?? "")
            try await Task.sleep(for: .milliseconds(60))
            if loseResponse { throw V15Failure(kind: .responseUnknown, code: "response_unknown", message: "Response lost") }
            data = V15F1AFixtures.transaction
        } else if request.path.hasPrefix("transactions/by-idempotency/"), receipts.contains(String(request.path.split(separator: "/").last ?? "")) {
            data = V15F1AFixtures.transaction
        } else { throw V15Failure(kind: .transport, code: "transaction_operation_not_found", message: "No receipt") }
        return try V15BodyEncoder.decode(Response.self, from: JSONDecoder().decode(JSONValue.self, from: data))
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw CancellationError() }
}

private actor DelayedReportTransport: V15Transporting {
    private(set) var started = false
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        started = true
        try await Task.sleep(for: .milliseconds(60))
        let json = V15F4AFixtures.report().replacingOccurrences(of: "\"credit_debt_at_period_end_minor\":8000", with: "\"credit_debt_at_period_end_minor\":null,\"credit_debt_at_period_end_status\":\"unknown\",\"balance_unavailable_reason\":\"historical_basis_unavailable\"").replacingOccurrences(of: "\"closing_balance_minor\":922337203685477", with: "\"closing_balance_minor\":-100")
        return try V15BodyEncoder.decode(Response.self, from: JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw CancellationError() }
}

private final class ReportCapabilityProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let supports = request.url?.host == "supported.example"
        let optedIn = request.value(forHTTPHeaderField: "X-Fiscal-Report-Balance-Semantics") == "as-of-v1"
        var headers = ["Content-Type": "application/json"]
        if supports && optedIn { headers["X-Fiscal-Report-Balance-Semantics"] = "as-of-v1" }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: request.url!.path.contains("/by-idempotency/") ? V15F1AFixtures.transaction : Data(V15F4AFixtures.report().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UpgradeOfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private actor CategoryRecoveryTransport: V15Transporting {
    let version: Int
    let categoryID: UUID?
    private(set) var putCount = 0
    init(version: Int, categoryID: UUID?) { self.version = version; self.categoryID = categoryID }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        if request.method == "PUT" {
            putCount += 1
            let original = try V15BodyEncoder.decode(V15TransactionReplaceRequest.self, from: body!)
            #expect(original.expectedVersion == 1)
        } else { #expect(request.readCachePolicy == .reloadIgnoringCache) }
        var value = try JSONSerialization.jsonObject(with: V15F1AFixtures.transaction) as! [String: Any]
        value["version"] = version
        value["category_id"] = categoryID.map { $0.uuidString as Any } ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: value)
        return try V15BodyEncoder.decode(Response.self, from: JSONDecoder().decode(JSONValue.self, from: data))
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw CancellationError() }
}

private final class CategoryRecoveredProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let transaction = String(decoding: V15F1AFixtures.transaction, as: UTF8.self)
        let data = request.url!.path.hasSuffix("/transactions") ? Data("{\"items\":[\(transaction)],\"next_cursor\":null}".utf8) : V15F1AFixtures.transaction
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
