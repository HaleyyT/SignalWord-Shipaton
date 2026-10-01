import Foundation

/// Non-secret configuration stored locally after the user completes setup.
/// A real endpoint is never bundled into the source tree as a shortcut around
/// environment setup.
enum SignalWordConfiguration {
    private static let appGroupInfoKey = "SignalWordAppGroupIdentifier"
    private static let userAPIInfoKey = "SignalWordUserAPIURL"
    private static let supabaseURLInfoKey = "SignalWordSupabaseURL"
    private static let publishableKeyInfoKey = "SignalWordSupabasePublishableKey"

    static var alertAPIBaseURL: URL? {
        configuredURL(for: userAPIInfoKey)
    }

    static var supabaseURL: URL? { configuredURL(for: supabaseURLInfoKey) }

    static var verificationURL: URL? {
        guard let url = configuredURL(for: "SignalWordVerificationURL"),
              url.scheme == "https", url.path == "/onboarding/verify.html",
              url.query == nil, url.fragment == nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SignalWordTurnstileSiteKey") as? String,
              key.range(of: "^[A-Za-z0-9_-]{10,100}$", options: .regularExpression) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "sitekey", value: key)]
        return components.url
    }

    static var supabasePublishableKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: publishableKeyInfoKey) as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private static func configuredURL(for key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$("),
              let url = URL(string: value), url.user == nil, url.password == nil else { return nil }
#if DEBUG
        guard url.scheme == "https" || ["localhost", "127.0.0.1"].contains(url.host) else { return nil }
#else
        guard url.scheme == "https" else { return nil }
#endif
        return url
    }

    /// Supplied by the signed app/extension Info.plist and matching entitlement.
    /// There is deliberately no source-code fallback: using the standard app
    /// container would break cross-process idempotency for App Intents.
    static var appGroupContainerURL: URL? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        )
    }
}
