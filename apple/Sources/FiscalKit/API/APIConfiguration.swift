import Foundation

public enum APIConfiguration {
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

    /// Optional one-time QA bootstrap. Xcode scheme/environment values are never bundled in the app.
    public static func bootstrapDeviceToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["FISCAL_DEVICE_TOKEN"]
    }
}
