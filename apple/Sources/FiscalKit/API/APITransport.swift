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
    case invalidResponse
    case transport(String)
    public var code: String? { switch self { case .unauthorized(let d): d?.code; case .domain(_, let d): d.code; default: nil } }
    public var displayMessage: String { switch self { case .unauthorized: "访问口令无效或已更改，请重新输入。"; case .domain(_, let d): d.message; case .invalidResponse: "服务器响应无法解析。"; case .transport: "无法连接个人 VPS。" } }
}

public actor APITransport {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let responseCache: HTTPResponseCache
    /// Monotonic marker bumped on every successful mutation. A GET only writes its response back
    /// to the cache if this is unchanged from when the GET was issued, so a read that was already
    /// in flight when a mutation cleared the cache can never re-poison it with pre-mutation data.
    private var cacheGeneration: UInt64 = 0

    public init(baseURL: URL, session: URLSession = .shared, accessKeyStore: AccessKeyStore = .init(), responseCache: HTTPResponseCache = .shared) {
        self.baseURL = baseURL; self.session = session; self.tokenProvider = { try await accessKeyStore.read() }; self.responseCache = responseCache
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    /// A non-persistent credential seam for deterministic tools and tests. Production apps keep
    /// using the Keychain-backed initializer above.
    public init(baseURL: URL, session: URLSession = .shared, token: String, responseCache: HTTPResponseCache = .shared) {
        self.baseURL = baseURL; self.session = session; self.tokenProvider = { token }; self.responseCache = responseCache
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    public func request<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ path: String, method: String = "GET", query: [URLQueryItem] = [], headers: [String: String] = [:],
        authorizationToken: String? = nil, body: Body? = Optional<String>.none
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
        let cacheKey = request.httpMethod == "GET" ? cacheKey(for: request, token: token) : nil
        if let cacheKey, let cached = await responseCache.data(for: cacheKey) {
            if let decoded = try? decoder.decode(Response.self, from: cached) { return decoded }
            // Poisoned cache entry (undecodable body): evict it and fall through to the network
            // instead of failing every read for the rest of the TTL.
            await responseCache.remove(cacheKey)
        }
        let startGeneration = cacheGeneration
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 { throw FiscalAPIError.unauthorized(detail) }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        if let cacheKey {
            // GET: decode before caching so an undecodable body never gets stored, and only cache
            // if no mutation bumped the generation while this read was in flight (M14).
            let decoded: Response
            do { decoded = try decoder.decode(Response.self, from: data) }
            catch { throw FiscalAPIError.invalidResponse }
            if cacheGeneration == startGeneration { await responseCache.store(data, for: cacheKey) }
            return decoded
        }
        // Mutation: invalidate every cache entry on success regardless of body decodability.
        cacheGeneration &+= 1
        await responseCache.removeAll()
        do { return try decoder.decode(Response.self, from: data) } catch { throw FiscalAPIError.invalidResponse }
    }

    public func requestNoContent(_ path: String, method: String, query: [URLQueryItem] = []) async throws {
        var request = URLRequest(url: try Self.endpointURL(baseURL: baseURL, path: path, query: query))
        request.httpMethod = method; request.timeoutInterval = 15
        if let token = try await tokenProvider(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 { throw FiscalAPIError.unauthorized(detail) }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        cacheGeneration &+= 1
        await responseCache.removeAll()
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
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        return data
    }

    private func cacheKey(for request: URLRequest, token: String?) -> String {
        let tokenScope = token.map { String($0.hashValue) } ?? "anonymous"
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
}
