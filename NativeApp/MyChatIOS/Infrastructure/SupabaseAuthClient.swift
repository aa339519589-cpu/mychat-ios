import Foundation

protocol SupabaseAuthenticating: Sendable {
    func storedSession() async throws -> AuthSession?
    func restoreSession() async throws -> AuthSession?
    func signIn(email: String, password: String) async throws -> AuthenticationResult
    func signUp(email: String, password: String) async throws -> AuthenticationResult
    func signInAnonymously() async throws -> AuthSession
    func refreshSession() async throws -> AuthSession
    func accessToken() async throws -> String?
    func updatePassword(_ password: String) async throws
    func logout() async throws
}

extension SupabaseAuthenticating {
    func storedSession() async throws -> AuthSession? { try await restoreSession() }
}

actor SupabaseAuthClient: SupabaseAuthenticating {
    private let configurationClient: any MobileConfigurationServing
    private let sessionStore: any AuthSessionStoring
    private let networkSession: URLSession
    private let refreshLeeway: TimeInterval = 60
    private var refreshTask: (id: UUID, task: Task<AuthSession, Error>)?
    private var sessionRevision = 0

    init(
        configurationClient: any MobileConfigurationServing = MobileConfigurationClient(),
        sessionStore: any AuthSessionStoring = KeychainAuthSessionStore(),
        networkSession: URLSession = .shared
    ) {
        self.configurationClient = configurationClient
        self.sessionStore = sessionStore
        self.networkSession = networkSession
    }

    func storedSession() async throws -> AuthSession? { try sessionStore.load() }

    func restoreSession() async throws -> AuthSession? {
        guard let stored = try sessionStore.load() else { return nil }
        guard stored.expires(within: refreshLeeway) else { return stored }
        do { return try await refresh(stored) }
        catch {
            // A failed early refresh must not invalidate a still usable access token.
            if !(error is CancellationError), (error as? AuthenticationError) != .sessionExpired,
               !stored.expires(within: 0) { return stored }
            throw error
        }
    }

    private func supersedePendingRefresh() {
        sessionRevision += 1
        refreshTask?.task.cancel()
        refreshTask = nil
    }

    func signIn(email: String, password: String) async throws -> AuthenticationResult {
        let credentials = try validatedCredentials(email: email, password: password)
        supersedePendingRefresh()
        let configuration = try await configurationClient.fetchConfiguration()
        let endpoint = try tokenEndpoint(configuration.supabaseURL, grantType: "password")
        let body = try JSONEncoder().encode(
            EmailCredentials(email: credentials.email, password: credentials.password)
        )
        let response = try await perform(
            endpoint: endpoint,
            configuration: configuration,
            body: body
        )
        let session = try makeSession(from: response)
        try sessionStore.save(session)
        return .authenticated(session)
    }

    func signUp(email: String, password: String) async throws -> AuthenticationResult {
        let credentials = try validatedCredentials(email: email, password: password)
        supersedePendingRefresh()
        let configuration = try await configurationClient.fetchConfiguration()
        let endpoint = authEndpoint(configuration.supabaseURL, component: "signup")
        let body = try JSONEncoder().encode(
            EmailCredentials(email: credentials.email, password: credentials.password)
        )
        let response = try await perform(
            endpoint: endpoint,
            configuration: configuration,
            body: body
        )

        if response.accessToken == nil || response.refreshToken == nil {
            return .emailConfirmationRequired(response.resolvedUser)
        }
        let session = try makeSession(from: response)
        try sessionStore.save(session)
        return .authenticated(session)
    }

    func signInAnonymously() async throws -> AuthSession {
        supersedePendingRefresh()
        let configuration = try await configurationClient.fetchConfiguration()
        let endpoint = authEndpoint(configuration.supabaseURL, component: "signup")
        let response = try await perform(
            endpoint: endpoint,
            configuration: configuration,
            body: try JSONEncoder().encode(AnonymousCredentials())
        )
        let session = try makeSession(from: response)
        try sessionStore.save(session)
        return session
    }

    func refreshSession() async throws -> AuthSession {
        guard let stored = try sessionStore.load() else {
            throw AuthenticationError.noStoredSession
        }
        return try await refresh(stored)
    }

    func accessToken() async throws -> String? {
        try await restoreSession()?.accessToken
    }

    func updatePassword(_ password: String) async throws {
        guard (6...256).contains(password.count) else {
            throw AuthenticationError.invalidCredentials
        }
        guard let stored = try sessionStore.load() else {
            throw AuthenticationError.noStoredSession
        }
        let configuration = try await configurationClient.fetchConfiguration()
        let endpoint = authEndpoint(configuration.supabaseURL, component: "user")
        var request = authorizedRequest(
            endpoint: endpoint,
            anonKey: configuration.supabaseAnonKey,
            bearerToken: stored.accessToken
        )
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(PasswordUpdate(password: password))
        let (data, response) = try await authData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw serverError(status: http.statusCode, data: data)
        }
    }

    func logout() async throws {
        let stored = try sessionStore.load()
        supersedePendingRefresh()
        try sessionStore.clear()
        guard let stored else {
            return
        }

        let configuration = try await configurationClient.fetchConfiguration()
        let endpoint = authEndpoint(configuration.supabaseURL, component: "logout")
        _ = try await performWithoutResponseBody(
            endpoint: endpoint,
            configuration: configuration,
            accessToken: stored.accessToken
        )
    }

    private func refresh(_ stored: AuthSession) async throws -> AuthSession {
        if let refreshTask { return try await refreshTask.task.value }
        let id = UUID(), revision = sessionRevision
        let task = Task { try await performRefresh(stored, revision: revision) }
        refreshTask = (id, task)
        defer { if refreshTask?.id == id { refreshTask = nil } }
        return try await task.value
    }

    private func performRefresh(_ stored: AuthSession, revision: Int) async throws -> AuthSession {
        do {
            let configuration = try await configurationClient.fetchConfiguration()
            let endpoint = try tokenEndpoint(configuration.supabaseURL, grantType: "refresh_token")
            let body = try JSONEncoder().encode(RefreshCredentials(refreshToken: stored.refreshToken))
            let response = try await perform(endpoint: endpoint, configuration: configuration, body: body)
            try Task.checkCancellation()
            guard revision == sessionRevision, try sessionStore.load()?.refreshToken == stored.refreshToken
            else { throw CancellationError() }
            let session = try makeSession(from: response)
            try sessionStore.save(session)
            return session
        } catch {
            guard revision == sessionRevision, !Task.isCancelled else { throw CancellationError() }
            // Only a specific server rejection of this exact session can clear it.
            if (error as? AuthenticationError) == .sessionExpired,
               revision == sessionRevision, (try? sessionStore.load()?.refreshToken) == stored.refreshToken {
                try? sessionStore.clear()
            }
            AuthenticationDiagnostics.record(stage: "refresh", error: error)
            throw error
        }
    }

    #if DEBUG
    func probeConnection() async {
        do {
            let config = try await configurationClient.fetchConfiguration()
            var request = URLRequest(url: authEndpoint(config.supabaseURL, component: "health"))
            request.timeoutInterval = 8
            request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            let (_, response) = try await networkSession.data(for: request)
            AuthenticationDiagnostics.record(stage: "health", status: (response as? HTTPURLResponse)?.statusCode)
        } catch { AuthenticationDiagnostics.record(stage: "health", error: error) }
    }
    #endif

    private func validatedCredentials(
        email: String,
        password: String
    ) throws -> (email: String, password: String) {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard
            normalizedEmail.count <= 254,
            normalizedEmail.contains("@"),
            !normalizedEmail.contains(where: { $0.isWhitespace }),
            (6...256).contains(password.count)
        else {
            throw AuthenticationError.invalidCredentials
        }
        return (normalizedEmail, password)
    }

    private func perform(
        endpoint: URL,
        configuration: MobileConfiguration,
        body: Data
    ) async throws -> SupabaseAuthResponse {
        var request = authorizedRequest(
            endpoint: endpoint,
            anonKey: configuration.supabaseAnonKey,
            bearerToken: configuration.supabaseAnonKey
        )
        request.httpBody = body

        let (data, response) = try await authData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw serverError(status: http.statusCode, data: data, refreshing: endpoint.query?.contains("grant_type=refresh_token") == true)
        }
        do {
            return try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
        } catch {
            throw AuthenticationError.invalidResponse
        }
    }

    private func performWithoutResponseBody(
        endpoint: URL,
        configuration: MobileConfiguration,
        accessToken: String
    ) async throws -> HTTPURLResponse {
        let request = authorizedRequest(
            endpoint: endpoint,
            anonKey: configuration.supabaseAnonKey,
            bearerToken: accessToken
        )
        let (data, response) = try await authData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw serverError(status: http.statusCode, data: data)
        }
        return http
    }

    private func authData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let result = try await networkSession.data(for: request)
            AuthenticationDiagnostics.record(stage: "auth-request", status: (result.1 as? HTTPURLResponse)?.statusCode)
            return result
        } catch {
            AuthenticationDiagnostics.record(stage: "auth-request", error: error)
            throw error
        }
    }

    private func authorizedRequest(
        endpoint: URL,
        anonKey: String,
        bearerToken: String
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")
        return request
    }

    private func makeSession(from response: SupabaseAuthResponse) throws -> AuthSession {
        guard
            let accessToken = response.accessToken,
            let refreshToken = response.refreshToken,
            let user = response.resolvedUser
        else {
            throw AuthenticationError.missingSession
        }
        let expiresAt = response.expiresAt.map(Date.init(timeIntervalSince1970:))
            ?? Date().addingTimeInterval(response.expiresIn ?? 3_600)
        return AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: response.tokenType ?? "bearer",
            expiresAt: expiresAt,
            user: user
        )
    }

    private func authEndpoint(_ baseURL: URL, component: String) -> URL {
        baseURL
            .appendingPathComponent("auth")
            .appendingPathComponent("v1")
            .appendingPathComponent(component)
    }

    private func tokenEndpoint(_ baseURL: URL, grantType: String) throws -> URL {
        let base = authEndpoint(baseURL, component: "token")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AuthenticationError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "grant_type", value: grantType)]
        guard let endpoint = components.url else {
            throw AuthenticationError.invalidResponse
        }
        return endpoint
    }

    private func serverError(status: Int, data: Data, refreshing: Bool = false) -> AuthenticationError {
        let payload = try? JSONDecoder().decode(SupabaseErrorPayload.self, from: data)
        let rejectedSessionCodes = ["refresh_token_not_found", "refresh_token_already_used", "session_expired", "session_not_found", "user_not_found", "user_banned"]
        if refreshing, status == 400 || status == 401 || status == 403,
           let code = payload?.errorCode, rejectedSessionCodes.contains(code) { return .sessionExpired }
        let fallback: String
        switch status {
        case 400, 401:
            fallback = "邮箱或密码不正确"
        case 429:
            fallback = "操作太频繁，请稍后再试"
        default:
            fallback = "认证服务暂时不可用，请稍后再试"
        }
        let message = payload?.errorDescription
            ?? payload?.message
            ?? payload?.msg
            ?? fallback
        return .server(status: status, message: message)
    }
}

private struct EmailCredentials: Encodable {
    let email: String
    let password: String
}

private struct RefreshCredentials: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct PasswordUpdate: Encodable {
    let password: String
}

private struct AnonymousCredentials: Encodable {
    let data: [String: String] = [:]
}

private struct SupabaseAuthResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: TimeInterval?
    let expiresAt: TimeInterval?
    let user: SupabaseUserPayload?
    let id: String?
    let email: String?
    let isAnonymous: Bool?

    var resolvedUser: AuthUser? {
        if let user {
            return user.authUser
        }
        guard let id else {
            return nil
        }
        return AuthUser(id: id, email: email, isAnonymous: isAnonymous ?? false)
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
        case id
        case email
        case isAnonymous = "is_anonymous"
    }
}

private struct SupabaseUserPayload: Decodable {
    let id: String
    let email: String?
    let isAnonymous: Bool?

    var authUser: AuthUser {
        AuthUser(id: id, email: email, isAnonymous: isAnonymous ?? false)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case isAnonymous = "is_anonymous"
    }
}

private struct SupabaseErrorPayload: Decodable {
    let errorCode: String?
    let errorDescription: String?
    let message: String?
    let msg: String?

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorDescription = "error_description"
        case message
        case msg
    }
}
