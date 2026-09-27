import Foundation
import Testing
@testable import FiscalKit

@Suite("Build50 transaction merchant confirmation")
struct V240MerchantMappingTests {
    @Test @MainActor func suggestionNeedsConfirmationAndUsesTransactionRoute() async throws {
        let transport = MerchantMappingTransport()
        let services = V15Services(transport: transport)
        let id = UUID()
        let model = V15MerchantMappingModel(services: services, transactionID: id)
        await model.load()
        #expect(model.name == "咖啡店" && model.mapping == nil && model.suggestion != nil)
        #expect(await transport.writeCount() == 0)
        await model.save()
        let sent = try #require(await transport.lastWrite())
        #expect(sent.0.path == "transactions/\(id)/merchant-mapping")
        #expect(sent.0.method == "PUT")
        #expect(sent.1 == .object(["merchant_name": .string("咖啡店"), "aliases": .array([])]))
        #expect(model.mapping?.mappingVersion == 1)
        #expect(model.hasConfirmedWrite && services.confirmedWriteRevision == 0)
        model.finishEditing(); model.finishEditing()
        #expect(services.confirmedWriteRevision == 1)
        #expect(await transport.allReadsFresh())
    }

    @Test @MainActor func unknownRetryKeepsExactPayloadAndKey() async throws {
        let transport = MerchantMappingTransport()
        await transport.failNextWrite(.init(kind: .responseUnknown, message: "unknown"))
        let model = V15MerchantMappingModel(services: .init(transport: transport), transactionID: UUID())
        await model.load(); await model.save()
        #expect(model.hasUnknownOutcome && !model.canEdit)
        let original = try #require(await transport.lastWrite())
        model.name = "不应进入重试的新内容"
        await model.retry()
        let retry = try #require(await transport.lastWrite())
        #expect(retry.0.headers["Idempotency-Key"] == original.0.headers["Idempotency-Key"])
        #expect(retry.1 == original.1)
        #expect(!model.hasUnknownOutcome && model.mapping?.merchant.name == "咖啡店")
    }

    @Test @MainActor func conflictRequiresFreshReadBeforeCorrection() async {
        let transport = MerchantMappingTransport()
        await transport.failNextWrite(.init(kind: .conflict, code: "version_conflict", message: "changed"))
        let model = V15MerchantMappingModel(services: .init(transport: transport), transactionID: UUID())
        await model.load(); await model.save()
        #expect(!model.loaded && !model.canSave && !model.hasUnknownOutcome)
        await model.save()
        #expect(await transport.writeCount() == 1)
        await model.load()
        #expect(model.canSave)
    }

    @Test @MainActor func savedButRefreshFailureCannotAuthorizeNextWrite() async {
        let transport = MerchantMappingTransport()
        await transport.failReadAfterWrite()
        let model = V15MerchantMappingModel(services: .init(transport: transport), transactionID: UUID())
        await model.load(); await model.save()
        #expect(!model.loaded && !model.canSave)
        #expect(model.message?.contains("已保存") == true)
        await model.save()
        #expect(await transport.writeCount() == 1)
    }

    @Test @MainActor func releaseCarriesCurrentVersionAndStableKey() async throws {
        let transport = MerchantMappingTransport()
        let model = V15MerchantMappingModel(services: .init(transport: transport), transactionID: UUID())
        await model.load(); await model.save(); await model.release()
        let sent = try #require(await transport.lastWrite())
        #expect(sent.0.method == "DELETE")
        #expect(sent.0.headers["Idempotency-Key"] != nil)
        #expect(sent.1 == .object(["expected_mapping_version": .integer(1)]))
        #expect(model.mapping == nil)
    }

    @Test @MainActor func offlineAndArchivedStayReadOnly() async {
        let transport = MerchantMappingTransport()
        let services = V15Services(transport: transport, offlineSnapshotProvider: { Date() })
        let offline = V15MerchantMappingModel(services: services, transactionID: UUID())
        await offline.load(); await offline.save()
        let archived = V15MerchantMappingModel(services: .init(transport: transport), transactionID: UUID(), readOnly: true)
        await archived.load(); await archived.save()
        #expect(!offline.canEdit && !archived.canEdit)
        #expect(await transport.writeCount() == 0)
    }
}

private actor MerchantMappingTransport: V15Transporting {
    private let merchant = V15Merchant(id: UUID(), name: "咖啡店", aliases: ["咖啡"])
    private var mapping: V15MerchantMapping?
    private var writes: [(V15Request, JSONValue?)] = []
    private var readPolicies: [V15ReadCachePolicy] = []
    private var nextWriteFailure: V15Failure?
    private var failAfterWrite = false
    func failNextWrite(_ failure: V15Failure) { nextWriteFailure = failure }
    func failReadAfterWrite() { failAfterWrite = true }
    func lastWrite() -> (V15Request, JSONValue?)? { writes.last }
    func writeCount() -> Int { writes.count }
    func allReadsFresh() -> Bool { readPolicies.allSatisfy { $0 == .reloadIgnoringCache } }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        if request.method == "GET" {
            readPolicies.append(request.readCachePolicy)
            if failAfterWrite && !writes.isEmpty { throw V15Failure(kind: .transport, message: "read failed") }
            return try V15BodyEncoder.decode(Response.self, from: V15BodyEncoder.encode(V15MerchantMappingState(mapping: mapping, suggestedMerchant: mapping == nil ? merchant : nil)))
        }
        writes.append((request, body))
        if let failure = nextWriteFailure { nextWriteFailure = nil; throw failure }
        mapping = request.method == "DELETE" ? nil : V15MerchantMapping(merchant: merchant, mappingVersion: 1)
        return try V15BodyEncoder.decode(Response.self, from: V15BodyEncoder.encode(V15MerchantMappingReceipt(action: request.method == "DELETE" ? "released" : "confirmed", mapping: mapping)))
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "unused") }
}
