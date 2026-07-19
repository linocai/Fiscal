import Foundation

public struct SystemStatus: Codable, Sendable, Equatable {
    public let service: String
    public let version: String
    public let environment: String
    public let status: String
    public let database: String
    public let currency: String
    public let businessTimezone: String
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case service, version, environment, status, database, currency, timestamp
        case businessTimezone = "business_timezone"
    }
}

public enum APIClientError: Error, Sendable, Equatable {
    case invalidResponse
    case unauthorized
    case server(statusCode: Int)
}

public actor SystemStatusClient {
    private let baseURL: URL
    private let session: URLSession
    private let accessKeyStore: AccessKeyStore

    public init(baseURL: URL, session: URLSession = .shared, accessKeyStore: AccessKeyStore = .init()) {
        self.baseURL = baseURL
        self.session = session
        self.accessKeyStore = accessKeyStore
    }

    public func fetch() async throws -> SystemStatus {
        let url = baseURL.appending(path: "api/v1/system/status")
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = try await accessKeyStore.read(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw APIClientError.unauthorized }
        guard (200..<300).contains(response.statusCode) else {
            throw APIClientError.server(statusCode: response.statusCode)
        }
        return try JSONDecoder.fiscal.decode(SystemStatus.self, from: data)
    }

    public func saveBootstrapAccessKeyIfMissing(_ accessKey: String) async throws {
        guard try await accessKeyStore.read() == nil else { return }
        try await accessKeyStore.save(accessKey)
    }
}

private extension JSONDecoder {
    static var fiscal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
