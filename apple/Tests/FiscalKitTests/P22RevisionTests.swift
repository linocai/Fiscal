import Foundation
import Testing

@testable import FiscalKit

@Suite("FiscalKit P22 revision convergence", .serialized)
struct P22RevisionTests {
  @Test("Own mutation receipt keeps its scoped refresh")
  @MainActor
  func ownReceiptKeepsScopes() {
    let store = DataRevisionStore(defaults: nil)
    store.accept(.init(revision: 7, scopes: ["ledger", "reports"]))
    #expect(store.latest == .init(revision: 7, scopes: ["ledger", "reports"]))
  }

  @Test("A newer foreground revision requests conservative full refresh")
  @MainActor
  func externalForegroundRevisionUsesEmptyScopes() {
    let store = DataRevisionStore(defaults: nil)
    store.accept(.init(revision: 7, scopes: ["ledger"]))
    store.observeServer(revision: 8, pollBaseline: 7)
    #expect(store.latest == .init(revision: 8, scopes: []))
  }

  @Test("Old server receipt omission is compatible and low revisions never roll back")
  @MainActor
  func oldServerAndRepeatedRevisionAreSafe() async throws {
    let store = DataRevisionStore(defaults: nil)
    StubURLProtocol.install { _ in .init(body: Data(#"{"items":[],"next_cursor":null}"#.utf8)) }
    let transport = APITransport(
      baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(), token: "t",
      responseCache: HTTPResponseCache(), revisionStore: store)
    _ = try await transport.request("transactions", method: "POST") as TransactionPage
    #expect(store.latest == nil)

    store.accept(.init(revision: 9, scopes: ["accounts"]))
    store.observeServer(revision: 9, pollBaseline: 9)
    let stalePollBaseline = store.currentRevision
    store.accept(.init(revision: 10, scopes: ["ledger"]))
    store.observeServer(revision: 8, pollBaseline: stalePollBaseline)
    #expect(store.latest == .init(revision: 10, scopes: ["ledger"]))
  }

  @Test("Foreground lower revision resets a persisted baseline after archive recovery")
  @MainActor
  func archiveRecoveryCanResetPersistedRevision() {
    let suite = "FiscalKitTests.P22.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(Int64(20), forKey: "revision")
    let store = DataRevisionStore(defaults: defaults, storageKey: "revision")
    store.observeServer(revision: 3, pollBaseline: 20)
    #expect(store.latest == .init(revision: 3, scopes: []))
    #expect((defaults.object(forKey: "revision") as? NSNumber)?.int64Value == 3)
    defaults.removePersistentDomain(forName: suite)
  }

  @Test("Foreground endpoint turns an external revision into full refresh")
  @MainActor
  func foregroundEndpointObservesRevision() async throws {
    let store = DataRevisionStore(defaults: nil)
    StubURLProtocol.install { request in
      #expect(request.url?.path == "/api/v1/data-revision")
      return .init(body: Data(#"{"revision":12}"#.utf8))
    }
    let transport = APITransport(
      baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(), token: "t",
      responseCache: HTTPResponseCache(), revisionStore: store)
    try await transport.refreshDataRevision()
    #expect(store.latest == .init(revision: 12, scopes: []))
  }

  @Test("Foreground revision polling does not invalidate ordinary GET cache")
  @MainActor
  func foregroundPollKeepsReadCache() async throws {
    let cache = HTTPResponseCache()
    StubURLProtocol.install { request in
      request.url?.path == "/api/v1/data-revision"
        ? .init(body: Data(#"{"revision":12}"#.utf8))
        : .init(body: Data(#"{"items":[],"next_cursor":null}"#.utf8))
    }
    let transport = APITransport(baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(),
      token: "t", responseCache: cache, revisionStore: DataRevisionStore(defaults: nil))
    _ = try await transport.request("transactions") as TransactionPage
    #expect(await cache.snapshot().entryCount == 1)
    try await transport.refreshDataRevision()
    #expect(await cache.snapshot().entryCount == 1)
    _ = try await transport.request("transactions") as TransactionPage
    #expect(StubURLProtocol.requestCount == 2)
  }

  @Test("Same-process archive cutover can reset, but an in-flight local receipt wins")
  @MainActor
  func revisionPollUsesItsOwnBaseline() {
    let store = DataRevisionStore(defaults: nil)
    store.accept(.init(revision: 10, scopes: ["ledger"]))
    store.observeServer(revision: 3, pollBaseline: 10)
    #expect(store.latest == .init(revision: 3, scopes: []))

    store.accept(.init(revision: 10, scopes: ["ledger"]))
    let pollBaseline = store.currentRevision
    store.accept(.init(revision: 11, scopes: ["accounts"]))
    store.observeServer(revision: 10, pollBaseline: pollBaseline)
    #expect(store.latest == .init(revision: 11, scopes: ["accounts"]))
  }

  @Test("Offline snapshots encrypt request metadata and payload")
  func snapshotRoundTripKeepsPlaintextOutOfDisk() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "fiscal-p22-\(UUID())")
    let keyStore = SnapshotKeyStore(service: "FiscalKitTests.P22.\(UUID())")
    let snapshots = OfflineSnapshotStore(directory: directory, keyStore: keyStore)
    let requestKey = "https://example.invalid/api/v1/accounts?name=private"
    let body = Data("private fiscal payload".utf8)
    await snapshots.store(body, for: requestKey)
    let encrypted = try Data(contentsOf: directory.appending(path: "read-only-snapshots.bin"))
    #expect(!String(decoding: encrypted, as: UTF8.self).contains("private"))
    let restored = await snapshots.data(for: requestKey)
    #expect(restored?.data == body)
    try FileManager.default.removeItem(at: directory)
  }

  @Test("Offline fallback is cleared only by a live successful GET")
  @MainActor
  func liveGetClearsOfflineSnapshotState() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "fiscal-p22-offline-\(UUID())")
    let snapshots = OfflineSnapshotStore(
      directory: directory, keyStore: SnapshotKeyStore(service: "FiscalKitTests.P22.\(UUID())"))
    let revisions = DataRevisionStore(defaults: nil)
    let page = Data(#"{"items":[],"next_cursor":null}"#.utf8)
    StubURLProtocol.install { _ in .init(body: page) }
    let seeded = APITransport(baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(),
      token: "t", responseCache: HTTPResponseCache(), offlineSnapshots: snapshots, revisionStore: revisions)
    _ = try await seeded.request("transactions") as TransactionPage

    StubURLProtocol.install { _ in .init(body: Data(), failure: URLError(.notConnectedToInternet)) }
    let offline = APITransport(baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(),
      token: "t", responseCache: HTTPResponseCache(), offlineSnapshots: snapshots, revisionStore: revisions)
    _ = try await offline.request("transactions") as TransactionPage
    #expect(revisions.offlineSnapshotAt != nil)

    StubURLProtocol.install { _ in .init(body: page) }
    let recovered = APITransport(baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(),
      token: "t", responseCache: HTTPResponseCache(), offlineSnapshots: snapshots, revisionStore: revisions)
    _ = try await recovered.request("transactions") as TransactionPage
    #expect(revisions.offlineSnapshotAt == nil)
    try FileManager.default.removeItem(at: directory)
  }

  @Test("Offline snapshots evict old entries and reject oversized responses")
  func snapshotStoreIsBounded() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "fiscal-p22-bounded-\(UUID())")
    let snapshots = OfflineSnapshotStore(
      directory: directory, keyStore: SnapshotKeyStore(service: "FiscalKitTests.P22.\(UUID())"),
      maxEntries: 2, maxPayloadBytes: 6, maxSingleResponseBytes: 4)
    await snapshots.store(Data("aa".utf8), for: "old", now: .distantPast)
    await snapshots.store(Data("bb".utf8), for: "middle", now: .now)
    await snapshots.store(Data("cc".utf8), for: "new", now: .distantFuture)
    await snapshots.store(Data("oversized".utf8), for: "too-large")
    #expect(await snapshots.entryCount() == 2)
    #expect(await snapshots.data(for: "old") == nil)
    #expect(await snapshots.data(for: "middle")?.data == Data("bb".utf8))
    #expect(await snapshots.data(for: "new")?.data == Data("cc".utf8))
    #expect(await snapshots.data(for: "too-large") == nil)
    try FileManager.default.removeItem(at: directory)
  }

  @Test("Explicit local draft preserves the idempotency key and never performs a request")
  func localDraftRoundTripPreservesReplayProtection() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "fiscal-p22-draft-\(UUID())")
    let snapshots = OfflineSnapshotStore(
      directory: directory, keyStore: SnapshotKeyStore(service: "FiscalKitTests.P22.\(UUID())"))
    let drafts = TransactionLocalDraftStore(encryptedStore: snapshots)
    StubURLProtocol.install { _ in .init(body: Data()) }
    let key = UUID()
    var draft = TransactionDraft(); draft.title = "未提交午餐"; draft.amountMinor = 1_200
    await drafts.save(.init(draft: draft, amountText: "12.00", idempotencyKey: key))
    let restored = await drafts.load()
    #expect(restored?.draft == draft)
    #expect(restored?.amountText == "12.00")
    #expect(restored?.idempotencyKey == key)
    #expect(StubURLProtocol.requestCount == 0)
    try FileManager.default.removeItem(at: directory)
  }

  @Test("An offline snapshot blocks formal submission before any request")
  func offlineSnapshotBlocksFormalSubmission() {
    #expect(!FormalSubmissionGate.canSubmit(offlineSnapshotAt: .now))
    #expect(FormalSubmissionGate.canSubmit(offlineSnapshotAt: nil))
  }
}
