import Foundation
import Testing

@testable import FiscalKit

/// Programmable URLProtocol used to drive `APITransport` end-to-end without a live server.
/// The suite that uses it is `.serialized` because the handler registry is process-global.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Stub: Sendable {
    let status: Int
    let body: Data
    let sleep: TimeInterval
    init(status: Int = 200, body: Data, sleep: TimeInterval = 0) {
      self.status = status
      self.body = body
      self.sleep = sleep
    }
  }

  nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Stub)?
  nonisolated(unsafe) private static var count = 0
  private static let lock = NSLock()

  static func install(_ handler: @escaping @Sendable (URLRequest) -> Stub) {
    lock.lock(); self.handler = handler; count = 0; lock.unlock()
  }

  static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }

  static func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    Self.count += 1
    let handler = Self.handler
    Self.lock.unlock()
    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let stub = handler(request)
    if stub.sleep > 0 { Thread.sleep(forTimeInterval: stub.sleep) }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: stub.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private let validPage = Data(#"{"items":[],"next_cursor":null}"#.utf8)

@Suite("FiscalKit P16 infrastructure", .serialized)
struct P16InfrastructureTests {
  // MARK: L15 – query "+" round-trips instead of decoding to a space

  @Test("Literal plus in a query value is percent-encoded, spaces stay %20")
  func plusIsEncoded() throws {
    let base = URL(string: "http://127.0.0.1:8000")!
    let url = try APITransport.endpointURL(
      baseURL: base, path: "transactions",
      query: [URLQueryItem(name: "query", value: "7+1"), URLQueryItem(name: "note", value: "a b")])
    let query = try #require(url.query(percentEncoded: true))
    #expect(query.contains("query=7%2B1"))
    #expect(query.contains("note=a%20b"))
    #expect(!query.contains("+"))

    let plusPlus = try APITransport.endpointURL(
      baseURL: base, path: "x", query: [URLQueryItem(name: "query", value: "C++")])
    #expect(plusPlus.query(percentEncoded: true) == "query=C%2B%2B")
  }

  // MARK: L17 – absent optional keys decode as nil instead of failing the page

  @Test("Transaction decoding tolerates omitted optional keys")
  func transactionOmitsOptionalKeys() throws {
    let json = Data(
      #"{"id":"00000000-0000-0000-0000-000000000001","kind":"expense","amount_minor":100,"occurred_at":"2026-07-16T04:00:00Z","business_date":"2026-07-16","title":"午餐","source":"manual","postings":[],"reimbursement_relations":[],"version":1,"created_at":"2026-07-16T04:00:00Z","updated_at":"2026-07-16T04:00:00Z"}"#
        .utf8)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let transaction = try decoder.decode(TransactionDTO.self, from: json)
    #expect(transaction.note == nil)
    #expect(transaction.categoryID == nil)
    #expect(transaction.installmentPlanID == nil)
    #expect(transaction.voidedAt == nil)
    #expect(transaction.reimbursementRelations.isEmpty)
  }

  // MARK: M15 – decode before caching; evict a poisoned entry and fall back to the network

  @Test("A malformed GET body is never cached")
  func malformedBodyNotCached() async {
    StubURLProtocol.install { _ in .init(body: Data("{not-json".utf8)) }
    let cache = HTTPResponseCache()
    let transport = APITransport(
      baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(), token: "t",
      responseCache: cache)
    await #expect(throws: FiscalAPIError.self) {
      _ = try await transport.request("transactions") as TransactionPage
    }
    #expect(await cache.snapshot().entryCount == 0)
  }

  @Test("A decodable GET is cached and the second read skips the network")
  func decodableGetIsCached() async throws {
    StubURLProtocol.install { _ in .init(body: validPage) }
    let cache = HTTPResponseCache()
    let transport = APITransport(
      baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(), token: "t",
      responseCache: cache)
    _ = try await transport.request("transactions") as TransactionPage
    _ = try await transport.request("transactions") as TransactionPage
    #expect(StubURLProtocol.requestCount == 1)
    #expect(await cache.snapshot().entryCount == 1)
  }

  @Test("A cache hit that no longer decodes is evicted and refetched")
  func poisonedCacheHitFallsBackToNetwork() async throws {
    StubURLProtocol.install { _ in
      // First call stores an object that decodes as JSONValue but not as TransactionPage;
      // the second call returns a valid page for the forced refetch.
      StubURLProtocol.requestCount == 1
        ? .init(body: Data(#"{"foo":1}"#.utf8)) : .init(body: validPage)
    }
    let cache = HTTPResponseCache()
    let transport = APITransport(
      baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(), token: "t",
      responseCache: cache)
    _ = try await transport.request("transactions") as JSONValue  // caches {"foo":1}
    let page = try await transport.request("transactions") as TransactionPage  // hit → evict → refetch
    #expect(page.items.isEmpty)
    #expect(StubURLProtocol.requestCount == 2)
  }

  // MARK: M14 – an in-flight GET cannot re-poison the cache after a mutation clears it

  @Test("A GET already in flight when a mutation clears the cache does not repopulate it")
  func inFlightGetCannotRepoisonCache() async throws {
    StubURLProtocol.install { request in
      request.httpMethod == "GET"
        ? .init(body: validPage, sleep: 0.30) : .init(body: validPage)
    }
    let cache = HTTPResponseCache()
    let transport = APITransport(
      baseURL: URL(string: "http://stub")!, session: StubURLProtocol.session(), token: "t",
      responseCache: cache)

    let slowGet = Task { try await transport.request("transactions") as TransactionPage }
    // Let the GET reach the network layer (stub sleeps 300ms) before mutating.
    try await Task.sleep(for: .milliseconds(80))
    _ = try await transport.request("transactions", method: "POST") as TransactionPage
    #expect(await cache.snapshot().entryCount == 0)  // mutation cleared the cache
    _ = try await slowGet.value  // slow GET now finishes; its store must be suppressed
    #expect(await cache.snapshot().entryCount == 0)
  }
}
