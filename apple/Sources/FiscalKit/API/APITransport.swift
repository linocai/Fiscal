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
    private let tokenStore: KeychainTokenStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL, session: URLSession = .shared, tokenStore: KeychainTokenStore = .init()) {
        self.baseURL = baseURL; self.session = session; self.tokenStore = tokenStore
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
        if let token = try await tokenStore.read(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw FiscalAPIError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw FiscalAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 || http.statusCode == 403 { throw FiscalAPIError.unauthorized(detail) }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
        do { return try decoder.decode(Response.self, from: data) } catch { throw FiscalAPIError.invalidResponse }
    }

    public func requestNoContent(_ path: String, method: String, query: [URLQueryItem] = []) async throws {
        var components = URLComponents(url: baseURL.appending(path: "api/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.timeoutInterval = 15
        if let token = try await tokenStore.read(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw FiscalAPIError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw FiscalAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(APIErrorEnvelope.self, from: data).error
            if http.statusCode == 401 || http.statusCode == 403 { throw FiscalAPIError.unauthorized(detail) }
            if let detail { throw FiscalAPIError.domain(status: http.statusCode, detail: detail) }
            throw FiscalAPIError.invalidResponse
        }
    }
}
