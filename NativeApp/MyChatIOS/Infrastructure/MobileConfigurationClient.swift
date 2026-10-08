import Foundation

actor BackendReadinessPrewarmer {
    static let shared = BackendReadinessPrewarmer()
    private var pending: Task<Void, Never>?
    private var lastStarted = Date.distantPast

    func start() {
        guard pending == nil, Date().timeIntervalSince(lastStarted) >= 120 else { return }
        lastStarted = Date()
        pending = Task {
            defer { pending = nil }
            var request = URLRequest(url: URL(string: "https://mychat-nm6x.onrender.com/api/ready")!)
            request.timeoutInterval = 75
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            // Read-only foreground warmup: no keepalive loop or paid request.
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}

struct MobileConfiguration: Codable, Equatable, Sendable {
    let supabaseURL: URL
    let supabaseAnonKey: String
}

protocol MobileConfigurationServing: Sendable {
    func fetchConfiguration() async throws -> MobileConfiguration
}

enum MobileConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case server(status: Int, message: String)
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "移动端配置返回了无效响应"
        case let .server(_, message):
            return message
        case .invalidConfiguration:
            return "移动端认证配置无效"
        }
    }
}

struct MobileConfigurationClient: MobileConfigurationServing {
    private let cache: MobileConfigurationCache
    init(session: URLSession = .shared) {
        cache = session === URLSession.shared ? .shared : MobileConfigurationCache(session: session)
    }
    func fetchConfiguration() async throws -> MobileConfiguration { try await cache.fetch() }
}

private actor MobileConfigurationCache {
    static let shared = MobileConfigurationCache(session: .shared, defaults: .standard)
    private static let endpoint = URL(string: "https://mychat-nm6x.onrender.com/api/mobile/config")!
    private let session: URLSession
    private let defaults: UserDefaults?
    private let key = "mychat.mobile-configuration.v1"
    private var cached: CachedConfiguration?
    private var inFlight: (id: UUID, task: Task<MobileConfiguration, Error>)?

    init(session: URLSession, defaults: UserDefaults? = nil) {
        self.session = session
        self.defaults = defaults
        if let data = defaults?.data(forKey: key),
           let value = try? JSONDecoder().decode(CachedConfiguration.self, from: data),
           Self.valid(value.configuration) { cached = value }
    }

    func fetch() async throws -> MobileConfiguration {
        if let cached, Date().timeIntervalSince(cached.date) < 300 { return cached.configuration }
        if let inFlight { return try await inFlight.task.value }
        let id = UUID()
        let task = Task { try await self.load() }
        inFlight = (id, task)
        defer { if inFlight?.id == id { inFlight = nil } }
        return try await task.value
    }

    private func load() async throws -> MobileConfiguration {
        do {
            var request = URLRequest(url: Self.endpoint)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MobileConfigurationError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw MobileConfigurationError.server(status: http.statusCode, message: "移动端认证配置暂时不可用")
            }
            guard let payload = try? JSONDecoder().decode(MobileConfigurationPayload.self, from: data),
                  let url = URL(string: payload.supabaseUrl) else { throw MobileConfigurationError.invalidConfiguration }
            let value = MobileConfiguration(supabaseURL: url, supabaseAnonKey: payload.supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines))
            guard Self.valid(value) else { throw MobileConfigurationError.invalidConfiguration }
            let saved = CachedConfiguration(configuration: value, date: Date())
            cached = saved
            if let data = try? JSONEncoder().encode(saved) { defaults?.set(data, forKey: key) }
            return value
        } catch {
            AuthenticationDiagnostics.record(stage: "configuration", error: error)
            // Bootstrap config is public and stable. A temporary outage should
            // not prevent authentication to the previously validated project.
            let transient: Bool
            if error is URLError { transient = true }
            else if case let MobileConfigurationError.server(status, _) = error { transient = status == 429 || status >= 500 }
            else { transient = false }
            if transient, let cached, Date().timeIntervalSince(cached.date) < 7 * 24 * 3600 { return cached.configuration }
            throw error
        }
    }

    private static func valid(_ value: MobileConfiguration) -> Bool {
        value.supabaseURL.scheme == "https" && value.supabaseURL.host != nil
            && value.supabaseURL.user == nil && value.supabaseURL.password == nil
            && !value.supabaseAnonKey.isEmpty
    }
    private struct CachedConfiguration: Codable {
        let configuration: MobileConfiguration
        let date: Date
    }
}

private struct MobileConfigurationPayload: Decodable {
    let supabaseUrl: String
    let supabaseAnonKey: String
}

private struct ConfigurationErrorPayload: Decodable {
    let error: String
}
