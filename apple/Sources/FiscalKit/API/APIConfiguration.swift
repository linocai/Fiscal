import Foundation

public enum APIConfiguration {
    public struct IOSAccessKeyPolicy: Sendable, Equatable {
        public let accessGroup: String?
        public let prefersSynchronizable: Bool
    }

    /// Keep the production bundle on its long-lived shared Keychain group, while test/QA bundle
    /// identifiers use their own app-local Keychain. This prevents a local-network QA build from
    /// reading or transmitting the production access key held by the signed Fiscal app.
    public static func iOSAccessKeyPolicy(bundleIdentifier: String?) -> IOSAccessKeyPolicy {
        if bundleIdentifier == "com.linotsai.fiscal" {
            return IOSAccessKeyPolicy(
                accessGroup: "HX73DFL88G.com.linotsai.fiscal",
                prefersSynchronizable: true
            )
        }
        return IOSAccessKeyPolicy(accessGroup: nil, prefersSynchronizable: false)
    }

    public static func baseURL(bundle: Bundle = .main) -> URL {
        if let raw = bundle.object(forInfoDictionaryKey: "FISCAL_API_BASE_URL") as? String,
           !raw.isEmpty,
           let url = URL(string: raw),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }
        // Keep a misconfigured build in the normal offline state instead of crashing during App.init.
        return URL(string: "https://fiscal.invalid")!
    }

    /// Optional one-time QA bootstrap access key. Xcode scheme/environment values are never
    /// bundled in the app. Against a local/test backend the injected value equals the backend's
    /// static token, so static-token authentication still accepts it.
    public static func bootstrapAccessKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["FISCAL_ACCESS_KEY"]
    }
}
