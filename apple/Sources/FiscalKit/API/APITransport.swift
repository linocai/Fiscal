import CryptoKit
import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), integer(Int64), decimal(Decimal), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Decimal.self) { self = .decimal(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let v): try c.encode(v); case .integer(let v): try c.encode(v); case .decimal(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
}

public struct APIErrorDetail: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let details: JSONValue?
    public let requestID: String
    enum CodingKeys: String, CodingKey { case code, message, details; case requestID = "request_id" }
}
public struct APIErrorEnvelope: Codable, Sendable, Equatable { public let error: APIErrorDetail }

public enum FiscalAPIError: Error, Sendable, Equatable {
    case unauthorized(APIErrorDetail?)
    case domain(status: Int, detail: APIErrorDetail)
    /// A gateway-level 429 (no API error envelope, e.g. the nginx limit_req zones); the app-level
    /// limiter sends a JSON envelope and stays on the `domain` path with its own message.
    case rateLimited
    case invalidResponse
    case transport(String)
    public var code: String? { switch self { case .unauthorized(let d): d?.code; case .domain(_, let d): d.code; default: nil } }
    public var displayMessage: String { switch self { case .unauthorized: "访问口令无效或已更改，请重新输入。"; case .domain(_, let d): d.message; case .rateLimited: "操作太频繁，请等几秒再试。"; case .invalidResponse: "服务器响应无法解析。"; case .transport: "无法连接个人 VPS。" } }
}

/// A deliberately narrow mutation response seam for contracts whose next request must use a
/// server-issued header. It exposes only decoded JSON and selected header values, never the raw
/// body or request.
public struct APIResponseMetadata<Value: Sendable>: Sendable {
    public let value: Value
    public let headers: [String: String]

    public init(value: Value, headers: [String: String]) {
        self.value = value
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public actor APITransport {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let responseCache: HTTPResponseCache
    private let offlineSnapshots: OfflineSnapshotStore
    private let revisionStore: DataRevisionStore?
    /// Monotonic marker bumped on every successful mutation. A GET only writes its response back
    /// to the cache if this is unchanged from when the GET was issued, so a read that was already
    /// in flight when a mutation cleared the cache can never re-poison it with pre-mutation data.
    private var cacheGeneration: UInt64 = 0

    public init(baseURL: URL, session: URLSession = .shared, accessKeyStore: AccessKeyStore = .init(), responseCache: HTTPResponseCache = .shared, offlineSnapshots: OfflineSnapshotStore = .shared, revisionStore: DataRevisionStore? = nil) {
        self.baseURL = baseURL; self.session = session; self.tokenProvider = { try await accessKeyStore.read() }; self.responseCache = responseCache; self.offlineSnapshots = offlineSnapshots; self.revisionStore = revisionStore
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    /// A non-persistent credential seam for deterministic tools and tests. Production apps keep
    /// using the Keychain-backed initializer above.
    public init(baseURL: URL, session: URLSession = .shared, token: String, responseCache: HTTPResponseCache = .shared, offlineSnapshots: OfflineSnapshotStore = .shared, revisionStore: DataRevisionStore? = nil) {
        self.baseURL = baseURL; self.session = session; self.tokenProvider = { token }; self.responseCache = responseCache; self.offlineSnapshots = offlineSnapshots; self.revisionStore = revisionStore
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    public func request<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ path: String, method: String = "GET", query: [URLQueryItem] = [], headers: [String: String] = [:],
        authorizationToken: String? = nil, cache: Bool = true, body: Body? = Optional<String>.none
    ) async throws -> Response {
        var request = URLRequest(url: try Self.endpointURL(baseURL: baseURL, path: path, query: query))
        request.httpMethod = method; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let token: String?
        if let authorizationToken { token = authorizationToken }
        else { token = try await tokenProvider() }
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let isGET = request.httpMethod == "GET"
        let cacheKey = cache && isGET ? cacheKey(for: request, token: token) : nil
        if let cacheKey, let cached = await responseCache.data(for: cacheKey) {
            if let decoded = try? decoder.decode(Response.self, from: cached) { return decoded }
            // Poisoned cache entry (undecodable body): evict it and fall through to the network
            // instead of failing every read for the rest of the TTL.
            await responseCache.remove(cacheKey)
        }
        let startGeneration = cacheGeneration
        var data: Data
        var http: HTTPURLResponse
        do {
            (data, http) = try await perform(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FiscalAPIError {
            guard case .transport = error,
                  let cacheKey,
                  let snapshot = await offlineSnapshots.data(for: cacheKey),
                  let decoded = try? decoder.decode(Response.self, from: snapshot.data)
            else { throw error }
            await revisionStore?.markOfflineSnapshot(at: snapshot.status.storedAt)
            return decoded
        } catch {
            throw error
        }
        if http.statusCode == 429, isGET {
            // An idempotent read bounced off the gateway limiter; one short-backoff retry absorbs
            // a refresh burst instead of surfacing an error for a self-healing situation.
            try await Task.sleep(nanoseconds: 1_200_000_000)
            (data, http) = try await perform(request)
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 { throw FiscalAPIError.unauthorized(detail) }
            if http.statusCode == 429, detail == nil { throw FiscalAPIError.rateLimited }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        if isGET {
            // GET: decode before caching so an undecodable body never gets stored, and only cache
            // if no mutation bumped the generation while this read was in flight (M14).
            let decoded: Response
            do { decoded = try decoder.decode(Response.self, from: data) }
            catch { throw FiscalAPIError.invalidResponse }
            if let cacheKey, cacheGeneration == startGeneration {
                await responseCache.store(data, for: cacheKey)
                await offlineSnapshots.store(data, for: cacheKey)
            }
            await revisionStore?.markOnline()
            return decoded
        }
        // Mutation: invalidate every cache entry on success regardless of body decodability.
        cacheGeneration &+= 1
        await responseCache.removeAll()
        await revisionStore?.markOnline()
        await acceptRevisionReceipt(from: http)
        do { return try decoder.decode(Response.self, from: data) } catch { throw FiscalAPIError.invalidResponse }
    }

    /// Performs an uncached JSON mutation and preserves response headers for the caller. This is
    /// intentionally separate from the normal request API so header-dependent workflows remain
    /// explicit and cannot accidentally gain raw request/response access.
    public func requestWithResponseMetadata<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ path: String, method: String, headers: [String: String] = [:], body: Body
    ) async throws -> APIResponseMetadata<Response> {
        var request = URLRequest(url: try Self.endpointURL(baseURL: baseURL, path: path, query: []))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let token = try await tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 { throw FiscalAPIError.unauthorized(detail) }
            if http.statusCode == 429, detail == nil { throw FiscalAPIError.rateLimited }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        let value: Response
        do { value = try decoder.decode(Response.self, from: data) }
        catch { throw FiscalAPIError.invalidResponse }
        cacheGeneration &+= 1
        await responseCache.removeAll()
        await revisionStore?.markOnline()
        await acceptRevisionReceipt(from: http)
        return APIResponseMetadata(value: value, headers: http.allHeaderFields.reduce(into: [:]) {
            guard let key = $1.key as? String, let value = $1.value as? String else { return }
            $0[key] = value
        })
    }

    public func requestNoContent(_ path: String, method: String, query: [URLQueryItem] = []) async throws {
        var request = URLRequest(url: try Self.endpointURL(baseURL: baseURL, path: path, query: query))
        request.httpMethod = method; request.timeoutInterval = 15
        if let token = try await tokenProvider(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 { throw FiscalAPIError.unauthorized(detail) }
            if http.statusCode == 429, detail == nil { throw FiscalAPIError.rateLimited }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        cacheGeneration &+= 1
        await responseCache.removeAll()
        await revisionStore?.markOnline()
        await acceptRevisionReceipt(from: http)
    }

    /// Polls the additive P22 revision contract without using either memory or disk response
    /// caches. Servers predating P22 simply fail this request and leave the current UI intact.
    public func refreshDataRevision() async throws {
        let pollBaseline = await revisionStore?.currentRevision
        let response: DataRevisionResponse = try await request("data-revision", cache: false)
        await revisionStore?.observeServer(revision: response.revision, pollBaseline: pollBaseline)
    }

    public func requestNoContent<Body: Encodable & Sendable>(
        _ path: String,
        method: String,
        body: Body
    ) async throws {
        var request = URLRequest(url: try Self.endpointURL(baseURL: baseURL, path: path, query: []))
        request.httpMethod = method; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try await tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 { throw FiscalAPIError.unauthorized(detail) }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        cacheGeneration &+= 1
        await responseCache.removeAll()
        await revisionStore?.markOnline()
        await acceptRevisionReceipt(from: http)
    }

    /// Performs an authenticated, uncached GET for non-JSON server artifacts such as CSV.
    public func rawDataGET(
        _ path: String,
        query: [URLQueryItem] = [],
        accept: String = "application/octet-stream"
    ) async throws -> Data {
        var request = URLRequest(url: try Self.endpointURL(baseURL: baseURL, path: path, query: query))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token = try await tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 { throw FiscalAPIError.unauthorized(detail) }
            if http.statusCode == 429, detail == nil { throw FiscalAPIError.rateLimited }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        await revisionStore?.markOnline()
        return data
    }

    private func cacheKey(for request: URLRequest, token: String?) -> String {
        let tokenScope = token.map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        } ?? "anonymous"
        return "\(request.url?.absoluteString ?? "")|\(tokenScope)"
    }

    /// Builds the endpoint URL, percent-encoding literal "+" so it round-trips as "+" rather than
    /// being read as a space by the server's form-style query parser (e.g. FastAPI `parse_qsl`).
    static func endpointURL(baseURL: URL, path: String, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents(
            url: baseURL.appending(path: "api/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw FiscalAPIError.invalidResponse }
        return url
    }

    /// Structured, cancellable network call. Because `session.data(for:)` is awaited directly in
    /// the caller's task, cancelling that task (e.g. a disappearing view) cancels the request.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw FiscalAPIError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw FiscalAPIError.invalidResponse }
        return (data, http)
    }

    private func acceptRevisionReceipt(from response: HTTPURLResponse) async {
        guard let raw = response.value(forHTTPHeaderField: "X-Fiscal-Data-Revision"), let revision = Int64(raw) else { return }
        let scopes = Set((response.value(forHTTPHeaderField: "X-Fiscal-Affected-Scopes") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
        await revisionStore?.accept(.init(revision: revision, scopes: scopes))
    }
}
