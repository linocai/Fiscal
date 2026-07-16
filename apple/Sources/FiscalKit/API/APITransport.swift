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
    public var displayMessage: String { switch self { case .unauthorized: "设备密钥无效，请重新配置。"; case .domain(_, let d): d.message; case .invalidResponse: "服务器响应无法解析。"; case .transport: "无法连接个人 VPS。" } }
}

public actor APITransport {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let responseCache: HTTPResponseCache
    private var inFlightGETs: [String: Task<(Data, HTTPURLResponse), Error>] = [:]

    public init(baseURL: URL, session: URLSession = .shared, tokenStore: KeychainTokenStore = .init(), responseCache: HTTPResponseCache = .shared) {
        self.baseURL = baseURL; self.session = session; self.tokenProvider = { try await tokenStore.read() }; self.responseCache = responseCache
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
        _ path: String, method: String = "GET", query: [URLQueryItem] = [], headers: [String: String] = [:], body: Body? = Optional<String>.none
    ) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: "api/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let token = try await tokenProvider()
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let cacheKey = request.httpMethod == "GET" ? cacheKey(for: request, token: token) : nil
        if let cacheKey, let data = await responseCache.data(for: cacheKey) {
            do { return try decoder.decode(Response.self, from: data) } catch { throw FiscalAPIError.invalidResponse }
        }
        let (data, http) = try await perform(request, cacheKey: cacheKey)
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 { throw FiscalAPIError.unauthorized(detail) }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        if let cacheKey { await responseCache.store(data, for: cacheKey) }
        else { await responseCache.removeAll() }
        do { return try decoder.decode(Response.self, from: data) } catch { throw FiscalAPIError.invalidResponse }
    }

    public func requestNoContent(_ path: String, method: String, query: [URLQueryItem] = []) async throws {
        var components = URLComponents(url: baseURL.appending(path: "api/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.timeoutInterval = 15
        if let token = try await tokenProvider(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw FiscalAPIError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw FiscalAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 { throw FiscalAPIError.unauthorized(detail) }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        await responseCache.removeAll()
    }

    /// Performs an authenticated, uncached GET for non-JSON server artifacts such as CSV.
    public func rawDataGET(
        _ path: String,
        query: [URLQueryItem] = [],
        accept: String = "application/octet-stream"
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appending(path: "api/v1/\(path)"),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw FiscalAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token = try await tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, http) = try await perform(request, cacheKey: nil)
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

    private func perform(_ request: URLRequest, cacheKey: String?) async throws -> (Data, HTTPURLResponse) {
        if let cacheKey, let existing = inFlightGETs[cacheKey] { return try await existing.value }
        let task = Task<(Data, HTTPURLResponse), Error> {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw FiscalAPIError.invalidResponse }
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as FiscalAPIError {
                throw error
            } catch {
                throw FiscalAPIError.transport(error.localizedDescription)
            }
        }
        if let cacheKey { inFlightGETs[cacheKey] = task }
        defer { if let cacheKey { inFlightGETs.removeValue(forKey: cacheKey) } }
        return try await task.value
    }
}
