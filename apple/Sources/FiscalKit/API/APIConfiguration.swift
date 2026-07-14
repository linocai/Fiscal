import Foundation

public enum APIConfiguration {
    public static func baseURL(bundle: Bundle = .main) -> URL {
        if let raw = bundle.object(forInfoDictionaryKey: "FISCAL_API_BASE_URL") as? String,
           let url = URL(string: raw) {
            return url
        }
        preconditionFailure("FISCAL_API_BASE_URL must be provided by the active build configuration")
    }

    /// Optional one-time QA bootstrap. Xcode scheme/environment values are never bundled in the app.
    public static func bootstrapDeviceToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["FISCAL_DEVICE_TOKEN"]
    }
}
