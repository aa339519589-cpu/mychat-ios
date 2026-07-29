import Foundation

enum AppConfig {
    static var apiBaseURL: URL {
        guard let raw = bundleString("MYCHAT_API_BASE_URL"),
              let url = normalizedURL(raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              (scheme == "https" || (scheme == "http" && host == "localhost")) else {
            fatalError("MYCHAT_API_BASE_URL is missing or invalid. Set it in Configuration/*.xcconfig.")
        }
        return url
    }

    static var embeddedBootstrap: MobileBootstrap? {
        guard let rawURL = bundleString("MYCHAT_SUPABASE_URL"),
              let supabaseURL = normalizedURL(rawURL),
              supabaseURL.scheme?.lowercased() == "https",
              supabaseURL.host != nil,
              let anonKey = bundleString("MYCHAT_SUPABASE_ANON_KEY"),
              !anonKey.isEmpty else {
            return nil
        }
        return MobileBootstrap(supabaseUrl: supabaseURL, supabaseAnonKey: anonKey)
    }

    private static func bundleString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw), components.host != nil else { return nil }
        components.path = components.path == "/" ? "" : components.path
        return components.url
    }
}
