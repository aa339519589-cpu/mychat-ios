import Combine
import CryptoKit
import Foundation
import Network
import Security
import UIKit

protocol ChatGPTPlanCredentialStoring: Sendable {
    func loadCredential() throws -> ChatGPTPlanCredential?
    func save(_ credential: ChatGPTPlanCredential) throws
    func deleteCredential() throws
    func loadOrCreateHostID() throws -> String
    func deleteHostID() throws
}

@MainActor
final class ChatGPTPlanProvider: ObservableObject {
    nonisolated static let modelIDPrefix = "chatgpt-plan:"
    static let providerName = "ChatGPT 订阅"
    static let usageScope = "chatgpt.tokens.use.direct"
    private static let resource = "https://api.openai.com/v1"
    private static let authorizationEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    private static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let authHost = "auth.openai.com"

    private struct DocumentedModelCapabilities {
        let vision: Bool
        let tools: Bool
        let reasoningEfforts: [String]
        let contextLength: Int
    }

    private static let documentedModelCapabilities: [String: DocumentedModelCapabilities] = [
        // /v1/models exposes the account's display catalog, but may omit the
        // capability fields needed by the picker. Keep these fallbacks limited
        // to exact, documented slugs that the account itself returned.
        "gpt-5.6": .init(
            vision: true, tools: true,
            reasoningEfforts: ["none", "low", "medium", "high", "xhigh", "max"],
            contextLength: 1_050_000
        ),
        "gpt-5.6-sol": .init(
            vision: true, tools: true,
            reasoningEfforts: ["none", "low", "medium", "high", "xhigh", "max"],
            contextLength: 1_050_000
        ),
        "gpt-5.6-terra": .init(
            vision: true, tools: true,
            reasoningEfforts: ["none", "low", "medium", "high", "xhigh", "max"],
            contextLength: 1_050_000
        ),
        "gpt-5.6-luna": .init(
            vision: true, tools: true,
            reasoningEfforts: ["none", "low", "medium", "high", "xhigh", "max"],
            contextLength: 1_050_000
        ),
        "gpt-6-astra": .init(
            vision: true, tools: true,
            reasoningEfforts: ["low", "medium", "high", "xhigh", "max"],
            contextLength: 1_050_000
        ),
        "gpt-6.1-sol": .init(
            vision: true, tools: true,
            reasoningEfforts: ["low", "medium", "high", "xhigh", "max"],
            contextLength: 1_050_000
        ),
        "gpt-6-luna": .init(
            vision: true, tools: true,
            reasoningEfforts: ["none", "low", "medium", "high", "xhigh", "max"],
            contextLength: 1_050_000
        )
    ]

    @Published private(set) var state: ChatGPTPlanConnectionState = .disconnected
    @Published private(set) var account: ChatGPTPlanAccount?
    @Published private(set) var models: [ChatGPTPlanModel] = []
    @Published private(set) var isAuthorizing = false

    private let session: URLSession
    private let credentialStore: any ChatGPTPlanCredentialStoring
    private var credentials: ChatGPTPlanCredential?
    private var refreshTask: Task<ChatGPTPlanCredential, Error>?
    private var callbackServer: LoopbackOAuthCallbackServer?

    init(session: URLSession = .shared, credentialStore: (any ChatGPTPlanCredentialStoring)? = nil) {
        self.session = session
        self.credentialStore = credentialStore ?? ChatGPTPlanCredentialStore()
    }

    var isConnected: Bool { account != nil }
    var canUsePlan: Bool { account?.hasPlanPermission == true }

    func restoreIfNeeded() {
        guard credentials == nil else { return }
        do {
            guard let saved = try credentialStore.loadCredential() else { return }
            credentials = saved
            refreshPublishedAccount(from: saved)
        } catch {
            state = .unavailable("无法从 Keychain 读取 ChatGPT 凭据：\(error.localizedDescription)")
        }
    }

    func restoreCachedModels(from catalog: [ModelCatalogItem]) {
        guard models.isEmpty, canUsePlan else { return }
        models = catalog.compactMap { item in
            guard item.id.hasPrefix(Self.modelIDPrefix) else { return nil }
            let slug = String(item.id.dropFirst(Self.modelIDPrefix.count))
            guard !slug.isEmpty else { return nil }
            return ChatGPTPlanModel(
                slug: slug,
                displayName: item.name,
                supportsVision: item.vision,
                supportsTools: item.tools,
                reasoningEfforts: item.reasoningEfforts,
                contextLength: item.contextLength
            )
        }
    }

    func signIn(reauthorizePlanAccess: Bool = false) async throws {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        state = .authorizing
        models = []
        defer {
            isAuthorizing = false
            callbackServer?.stop()
            callbackServer = nil
        }

        do {
            let prior = try credentialStore.loadCredential()
            let hostID = try credentialStore.loadOrCreateHostID()
            let server = try LoopbackOAuthCallbackServer()
            callbackServer = server
            let redirectURI = try await server.start()
            let transaction = OAuthTransaction(
                state: Self.randomBase64URL(byteCount: 32),
                nonce: Self.randomBase64URL(byteCount: 32),
                verifier: Self.randomBase64URL(byteCount: 64),
                redirectURI: redirectURI
            )
            let clientID = prior?.clientID ?? "dynamic_agent_client"
            let authorizationURL = try Self.authorizationURL(
                clientID: clientID,
                hostID: hostID,
                redirectURI: redirectURI,
                state: transaction.state,
                nonce: transaction.nonce,
                codeChallenge: Self.pkceChallenge(for: transaction.verifier),
                prior: prior,
                isDynamicRegistration: prior?.clientID == nil,
                requestConsent: reauthorizePlanAccess
            )

            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MyChat ChatGPT authorization") {
                server.cancel()
            }
            defer {
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            }

            let callbackTask = Task { try await server.waitForCallback() }
            guard await UIApplication.shared.open(authorizationURL) else {
                callbackTask.cancel()
                throw ChatGPTPlanError.callback("系统浏览器无法打开授权页面")
            }
            let callback = try await withThrowingTaskGroup(of: URL.self) { group in
                group.addTask { try await callbackTask.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    throw ChatGPTPlanError.timeout
                }
                defer {
                    group.cancelAll()
                    callbackTask.cancel()
                }
                guard let result = try await group.next() else { throw ChatGPTPlanError.timeout }
                return result
            }
            let result = try Self.parseCallback(callback, expectedState: transaction.state)
            let issuedClientID: String
            if let priorClientID = prior?.clientID {
                if let returned = result.clientID, returned != priorClientID {
                    throw ChatGPTPlanError.callback("回调中的 client_id 与已注册账户不一致")
                }
                issuedClientID = priorClientID
            } else {
                guard let returned = result.clientID,
                      !returned.isEmpty,
                      returned != "dynamic_agent_client" else {
                    throw ChatGPTPlanError.registrationMissing
                }
                issuedClientID = returned
                // Dynamic registration is complete as soon as OpenAI returns
                // its issued ID. Keep it even if code exchange is interrupted.
                try credentialStore.save(ChatGPTPlanCredential(
                    hostID: hostID,
                    clientID: issuedClientID,
                    subject: nil,
                    email: nil,
                    displayName: nil,
                    accessToken: nil,
                    refreshToken: nil,
                    idToken: nil,
                    scopes: [],
                    accessExpiresAt: nil,
                    earliestRefreshAt: nil
                ))
            }

            let token = try await exchangeAuthorizationCode(
                code: result.code,
                verifier: transaction.verifier,
                redirectURI: redirectURI,
                clientID: issuedClientID
            )
            guard let idToken = token.idToken,
                  let refreshToken = token.refreshToken,
                  !refreshToken.isEmpty else {
                throw ChatGPTPlanError.invalidResponse
            }
            let identity = try await validateIDToken(
                idToken,
                expectedClientID: issuedClientID,
                expectedNonce: transaction.nonce
            )
            if let priorSubject = prior?.subject, priorSubject != identity.subject {
                throw ChatGPTPlanError.accountChanged
            }

            // Save the OpenAI-issued ID only after successful code exchange and
            // signed identity validation. dynamic_agent_client is never stored.
            let saved = ChatGPTPlanCredential(
                hostID: hostID,
                clientID: issuedClientID,
                subject: identity.subject,
                email: identity.email,
                displayName: identity.displayName,
                accessToken: token.accessToken,
                refreshToken: refreshToken,
                idToken: idToken,
                scopes: token.scopes,
                accessExpiresAt: token.accessExpiresAt,
                earliestRefreshAt: token.earliestRefreshAt
            )
            try credentialStore.save(saved)
            credentials = saved
            refreshPublishedAccount(from: saved)
            if saved.scopes.contains(Self.usageScope) {
                state = .connected
                try await refreshModels()
            } else {
                state = .planPermissionMissing
                models = []
            }
        } catch {
            if error is CancellationError || (error as? ChatGPTPlanError) == .cancelled {
                state = account == nil ? .disconnected : (canUsePlan ? .connected : .planPermissionMissing)
                throw ChatGPTPlanError.cancelled
            }
            if let planError = error as? ChatGPTPlanError {
                state = account == nil ? .unavailable(planError.localizedDescription) : currentState(after: planError)
                throw planError
            }
            let wrapped = ChatGPTPlanError.callback(error.localizedDescription)
            state = .unavailable(wrapped.localizedDescription)
            throw wrapped
        }
    }

    func cancelSignIn() {
        callbackServer?.cancel()
    }

    func disconnect() throws {
        callbackServer?.cancel()
        callbackServer = nil
        refreshTask?.cancel()
        refreshTask = nil
        models = []
        let storedCredential = try credentials ?? credentialStore.loadCredential()
        guard var saved = storedCredential else {
            state = .disconnected
            account = nil
            return
        }
        // Retain the official registration ID for a later sign-in, but remove
        // bearer credentials and the ID-token hint on explicit sign-out.
        saved.accessToken = nil
        saved.refreshToken = nil
        saved.idToken = nil
        saved.scopes = []
        saved.accessExpiresAt = nil
        saved.earliestRefreshAt = nil
        try credentialStore.save(saved)
        credentials = saved
        account = nil
        state = .disconnected
    }

    func forgetRegistration() throws {
        try credentialStore.deleteCredential()
        try credentialStore.deleteHostID()
        credentials = nil
        account = nil
        models = []
        state = .disconnected
    }

    func refreshModels() async throws {
        restoreIfNeeded()
        let accessToken = try await validAccessToken()
        guard credentials?.scopes.contains(Self.usageScope) == true else {
            state = .planPermissionMissing
            models = []
            throw ChatGPTPlanError.planPermissionMissing
        }
        var request = URLRequest(url: URL(string: "\(Self.resource)/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTPlanError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let error = Self.serverError(status: http.statusCode, data: data, headers: http.allHeaderFields)
            guard http.statusCode == 401 else {
                state = currentState(after: error)
                throw error
            }
            let refreshed = try await forceRefresh()
            guard let refreshedAccessToken = refreshed.accessToken else {
                state = .reauthorizationRequired
                throw ChatGPTPlanError.reauthorizationRequired
            }
            var retry = request
            retry.setValue("Bearer \(refreshedAccessToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await session.data(for: retry)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else { throw ChatGPTPlanError.invalidResponse }
            guard (200..<300).contains(retryHTTP.statusCode) else {
                let retryError = Self.serverError(status: retryHTTP.statusCode, data: retryData,
                                                  headers: retryHTTP.allHeaderFields)
                state = currentState(after: retryError)
                throw retryError
            }
            models = try Self.decodeModels(from: retryData)
            state = .connected
            return
        }
        models = try Self.decodeModels(from: data)
        state = .connected
    }

    func streamResponse(
        model: String,
        messages: [ChatMessage],
        attachments: [ChatFileAttachment],
        systemPrompt: String?,
        reasoningEffort: String,
        tools: [ChatGPTPlanToolDefinition],
        executeTool: @escaping @Sendable (String, String) async throws -> String,
        modelSupportsVision: Bool
    ) async throws -> AsyncThrowingStream<ChatGPTPlanStreamEvent, Error> {
        restoreIfNeeded()
        guard credentials?.scopes.contains(Self.usageScope) == true else {
            state = .planPermissionMissing
            throw ChatGPTPlanError.planPermissionMissing
        }
        if !modelSupportsVision && (messages.contains { !($0.sourceImages ?? []).isEmpty }
            || attachments.contains { $0.dataURL.hasPrefix("data:image/") || !($0.pageImages ?? []).isEmpty }) {
            throw ChatGPTPlanError.unsupportedFeature("图片输入（此模型未声明视觉能力）")
        }
        let accessToken = try await validAccessToken()
        let body = try Self.responsesBody(
            model: model,
            messages: messages,
            attachments: attachments,
            systemPrompt: systemPrompt,
            reasoningEffort: reasoningEffort,
            tools: tools
        )
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return Self.stream(
            session: session,
            requestBody: json,
            accessToken: accessToken,
            executeTool: executeTool,
            refresh: { [weak self] in
                guard let self else { throw ChatGPTPlanError.notConnected }
                let refreshed = try await self.forceRefresh()
                guard let accessToken = refreshed.accessToken else {
                    throw ChatGPTPlanError.reauthorizationRequired
                }
                return accessToken
            }
        )
    }

    private func validAccessToken() async throws -> String {
        restoreIfNeeded()
        guard let saved = credentials,
              let token = saved.accessToken,
              let refreshToken = saved.refreshToken else {
            if account != nil { throw ChatGPTPlanError.reauthorizationRequired }
            throw ChatGPTPlanError.notConnected
        }
        guard saved.scopes.contains(Self.usageScope) else {
            state = .planPermissionMissing
            throw ChatGPTPlanError.planPermissionMissing
        }
        if let expiry = saved.accessExpiresAt,
           expiry.timeIntervalSinceNow > 90,
           (saved.earliestRefreshAt == nil || saved.earliestRefreshAt! > Date()) {
            return token
        }
        _ = refreshToken
        let refreshed = try await forceRefresh()
        guard let accessToken = refreshed.accessToken else {
            throw ChatGPTPlanError.reauthorizationRequired
        }
        return accessToken
    }

    private func forceRefresh() async throws -> ChatGPTPlanCredential {
        if let refreshTask { return try await refreshTask.value }
        let storedCredential = try credentials ?? credentialStore.loadCredential()
        guard let original = storedCredential,
              let refreshToken = original.refreshToken,
              let clientID = original.clientID else {
            throw ChatGPTPlanError.reauthorizationRequired
        }
        let task = Task { [session, credentialStore] in
            var request = URLRequest(url: Self.tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            request.httpBody = Self.formEncoded([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
                "resource": Self.resource
            ])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatGPTPlanError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let error = Self.serverError(status: http.statusCode, data: data, headers: http.allHeaderFields)
                if Self.isTerminalRefreshError(error) {
                    var invalid = original
                    invalid.accessToken = nil
                    invalid.refreshToken = nil
                    invalid.idToken = nil
                    invalid.scopes = []
                    invalid.accessExpiresAt = nil
                    invalid.earliestRefreshAt = nil
                    try credentialStore.save(invalid)
                }
                throw error
            }
            let token = try Self.decodeToken(data, preservingIDToken: original.idToken)
            var updated = original
            updated.accessToken = token.accessToken
            updated.refreshToken = token.refreshToken ?? refreshToken
            updated.idToken = token.idToken ?? original.idToken
            updated.scopes = token.scopes.isEmpty ? original.scopes : token.scopes
            updated.accessExpiresAt = token.accessExpiresAt
            updated.earliestRefreshAt = token.earliestRefreshAt
            try credentialStore.save(updated)
            return updated
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            credentials = refreshed
            refreshPublishedAccount(from: refreshed)
            state = refreshed.scopes.contains(Self.usageScope) ? .connected : .planPermissionMissing
            return refreshed
        } catch {
            if let planError = error as? ChatGPTPlanError {
                if Self.isTerminalRefreshError(planError) {
                    credentials = try? credentialStore.loadCredential()
                    account = nil
                    models = []
                    state = .reauthorizationRequired
                    throw planError
                }
                state = currentState(after: planError)
                throw planError
            }
            throw error
        }
    }

    private func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        redirectURI: URL,
        clientID: String
    ) async throws -> ChatGPTPlanTokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = Self.formEncoded([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI.absoluteString,
            "resource": Self.resource
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTPlanError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.serverError(status: http.statusCode, data: data, headers: http.allHeaderFields)
        }
        return try Self.decodeToken(data, preservingIDToken: nil)
    }

    private func validateIDToken(
        _ token: String,
        expectedClientID: String,
        expectedNonce: String
    ) async throws -> ChatGPTPlanIdentity {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = Self.decodeBase64URL(String(segments[0])),
              let claimsData = Self.decodeBase64URL(String(segments[1])),
              let signature = Self.decodeBase64URL(String(segments[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let kid = header["kid"] as? String,
              let subject = claims["sub"] as? String,
              !subject.isEmpty,
              claims["iss"] as? String == "https://auth.openai.com",
              Self.audience(claims["aud"], contains: expectedClientID),
              claims["nonce"] as? String == expectedNonce,
              let expiry = Self.number(claims["exp"]), expiry > Date().timeIntervalSince1970,
              Self.number(claims["iat"]).map({ $0 <= Date().timeIntervalSince1970 + 60 }) ?? true,
              Self.number(claims["nbf"]).map({ $0 <= Date().timeIntervalSince1970 + 60 }) ?? true else {
            throw ChatGPTPlanError.identityValidation
        }
        let configURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
        let (configurationData, configurationResponse) = try await session.data(from: configURL)
        guard let configurationHTTP = configurationResponse as? HTTPURLResponse,
              configurationHTTP.statusCode == 200,
              let configuration = try? JSONSerialization.jsonObject(with: configurationData) as? [String: Any],
              configuration["issuer"] as? String == "https://auth.openai.com",
              let jwksString = configuration["jwks_uri"] as? String,
              let jwksURL = URL(string: jwksString),
              jwksURL.scheme == "https", jwksURL.host == Self.authHost else {
            throw ChatGPTPlanError.identityValidation
        }
        let (jwksData, jwksResponse) = try await session.data(from: jwksURL)
        guard let jwksHTTP = jwksResponse as? HTTPURLResponse, jwksHTTP.statusCode == 200,
              let jwks = try? JSONSerialization.jsonObject(with: jwksData) as? [String: Any],
              let keys = jwks["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let modulus = (key["n"] as? String).flatMap(Self.decodeBase64URL),
              let exponent = (key["e"] as? String).flatMap(Self.decodeBase64URL) else {
            throw ChatGPTPlanError.identityValidation
        }
        let signedData = Data("\(segments[0]).\(segments[1])".utf8)
        guard Self.verifyRS256(signature: signature, signedData: signedData, modulus: modulus, exponent: exponent) else {
            throw ChatGPTPlanError.identityValidation
        }
        return ChatGPTPlanIdentity(
            subject: subject,
            email: claims["email"] as? String,
            displayName: (claims["name"] as? String) ?? (claims["preferred_username"] as? String)
        )
    }

    private func refreshPublishedAccount(from saved: ChatGPTPlanCredential) {
        guard let subject = saved.subject, let clientID = saved.clientID else {
            account = nil
            state = .disconnected
            return
        }
        let hasTokens = saved.accessToken != nil && saved.refreshToken != nil
        account = hasTokens ? ChatGPTPlanAccount(
            email: saved.email,
            displayName: saved.displayName,
            subject: subject,
            clientID: clientID,
            hasPlanPermission: saved.scopes.contains(Self.usageScope)
        ) : nil
        if !hasTokens {
            state = .disconnected
        } else if !saved.scopes.contains(Self.usageScope) {
            state = .planPermissionMissing
        } else {
            state = .connected
        }
    }

    private func currentState(after error: ChatGPTPlanError) -> ChatGPTPlanConnectionState {
        if Self.isTerminalRefreshError(error) { return .reauthorizationRequired }
        if case .planPermissionMissing = error { return .planPermissionMissing }
        if account != nil, canUsePlan { return .connected }
        if account != nil { return .planPermissionMissing }
        return .unavailable(error.localizedDescription)
    }

    static func authorizationURL(
        clientID: String,
        hostID: String,
        redirectURI: URL,
        state: String,
        nonce: String,
        codeChallenge: String,
        prior: ChatGPTPlanCredential?,
        isDynamicRegistration: Bool,
        requestConsent: Bool
    ) throws -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke \(usageScope)"),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "ext_agent_host_id", value: hostID)
        ]
        if isDynamicRegistration {
            items.append(URLQueryItem(name: "agent_name_hint", value: "MyChat"))
        } else if let idToken = prior?.idToken {
            items.append(URLQueryItem(name: "id_token_hint", value: idToken))
        } else if let email = prior?.email {
            items.append(URLQueryItem(name: "login_hint", value: email))
        }
        if requestConsent { items.append(URLQueryItem(name: "prompt", value: "consent")) }
        components.queryItems = items
        guard let url = components.url, url.scheme == "https", url.host == authHost else {
            throw ChatGPTPlanError.invalidResponse
        }
        return url
    }

    private static func parseCallback(_ url: URL, expectedState: String) throws -> OAuthCallbackResult {
        guard url.scheme == "http", url.host == "127.0.0.1", url.path == "/auth/callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ChatGPTPlanError.callback("回调地址不匹配")
        }
        let query = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        guard query["state"] == expectedState else { throw ChatGPTPlanError.callback("state 校验失败") }
        if let error = query["error"] {
            if error == "access_denied" { throw ChatGPTPlanError.cancelled }
            throw ChatGPTPlanError.callback(query["error_description"] ?? error)
        }
        guard let code = query["code"], !code.isEmpty else {
            throw ChatGPTPlanError.callback("缺少 authorization code")
        }
        let scopes = (query["scope"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        return OAuthCallbackResult(code: code, clientID: query["client_id"], scopes: scopes)
    }

    static func decodeModels(from data: Data) throws -> [ChatGPTPlanModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["models"] as? [[String: Any]] else {
            throw ChatGPTPlanError.invalidResponse
        }
        return entries.compactMap { entry in
            guard entry["visibility"] as? String == "list",
                  let slug = entry["slug"] as? String, !slug.isEmpty,
                  let name = entry["display_name"] as? String, !name.isEmpty else { return nil }
            let documented = Self.documentedModelCapabilities[slug.lowercased()]
            let capabilities = entry["capabilities"]
            let capabilityMap = capabilities as? [String: Any]
            let namedCapabilities = capabilities as? [String]
            let vision = (capabilityMap?["vision"] as? Bool)
                ?? (entry["vision"] as? Bool)
                ?? namedCapabilities.map { $0.contains("vision") }
                ?? documented?.vision
                ?? false
            let tools = (capabilityMap?["tools"] as? Bool)
                ?? (entry["tools"] as? Bool)
                ?? namedCapabilities.map { $0.contains("tools") }
                ?? documented?.tools
                ?? false
            let effortSource = (entry["reasoning_efforts"] as? [String])
                ?? (capabilityMap?["reasoning_efforts"] as? [String])
                ?? documented?.reasoningEfforts
                ?? []
            let efforts = effortSource.filter { ChatReasoningEffort(rawValue: $0) != nil }
            let context = (entry["context_length"] as? NSNumber)?.intValue ?? documented?.contextLength
            return ChatGPTPlanModel(
                slug: slug,
                displayName: name,
                supportsVision: vision,
                supportsTools: tools,
                reasoningEfforts: efforts,
                contextLength: context
            )
        }
    }

    static func responsesBody(
        model: String,
        messages: [ChatMessage],
        attachments: [ChatFileAttachment],
        systemPrompt: String?,
        reasoningEffort: String,
        tools: [ChatGPTPlanToolDefinition]
    ) throws -> [String: Any] {
        guard !model.isEmpty else { throw ChatGPTPlanError.invalidResponse }
        let userMessageID = messages.last(where: { $0.role == .user })?.id
        var input: [[String: Any]] = []
            for message in messages where message.role == .user || message.role == .assistant {
            if message.role == .assistant && message.content.isEmpty { continue }
            if message.role == .assistant {
                input.append(["role": "assistant", "content": message.content])
                continue
            }
            var content: [[String: Any]] = []
            if !message.content.isEmpty {
                content.append(["type": "input_text", "text": message.content])
            }
            for image in message.sourceImages ?? [] where image.hasPrefix("data:image/") || image.hasPrefix("https://") {
                content.append(["type": "input_image", "image_url": image])
            }
            if message.id == userMessageID {
                for file in attachments {
                    if let text = file.text, !text.isEmpty {
                        content.append(["type": "input_text", "text": "附件：\(file.name)\n\(text)"])
                    }
                    for image in file.pageImages ?? [] where image.hasPrefix("data:image/") {
                        content.append(["type": "input_image", "image_url": image])
                    }
                    if file.text == nil, file.pageImages?.isEmpty != false,
                       file.dataURL.hasPrefix("data:image/") {
                        content.append(["type": "input_image", "image_url": file.dataURL])
                    }
                }
            }
            guard !content.isEmpty else { continue }
            input.append(["role": message.role.rawValue, "content": content])
        }
        guard !input.isEmpty else { throw ChatGPTPlanError.invalidResponse }
        if !tools.isEmpty {
            let additionalTools: [String: Any] = [
                "type": "additional_tools",
                "role": "developer",
                "tools": tools.map(\.responseObject)
            ]
            if let latestUserMessage = input.lastIndex(where: { $0["role"] as? String == "user" }) {
                input.insert(additionalTools, at: latestUserMessage)
            } else {
                input.append(additionalTools)
            }
        }
        var body: [String: Any] = [
            "model": model,
            "input": input,
            "store": false,
            "stream": true
        ]
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["instructions"] = systemPrompt + "\n\n" + NativeDocumentInstructions.prompt
        } else { body["instructions"] = NativeDocumentInstructions.prompt }
        if reasoningEffort != "none", ChatReasoningEffort(rawValue: reasoningEffort) != nil {
            body["reasoning"] = ["effort": reasoningEffort, "summary": "auto"]
        }
        return body
    }

    static func stream(
        session: URLSession,
        requestBody: Data,
        accessToken: String,
        executeTool: @escaping @Sendable (String, String) async throws -> String,
        refresh: @escaping () async throws -> String
    ) -> AsyncThrowingStream<ChatGPTPlanStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    var token = accessToken
                    var didRetryUnauthorized = false
                    var completed = false
                    var accumulatedText = ""
                    var lastRequestID: String?
                    var currentBody = requestBody
                    var toolRounds = 0

                    func process(_ event: InternalStreamEvent) async throws -> Data? {
                        switch event {
                        case .ignored:
                            return nil
                        case let .textDelta(delta):
                            accumulatedText += delta
                            continuation.yield(.textDelta(delta))
                            return nil
                        case let .reasoningSummaryDelta(delta):
                            continuation.yield(.reasoningSummaryDelta(delta))
                            return nil
                        case let .responseCompleted(finalText, calls, outputData):
                            if calls.isEmpty {
                                if accumulatedText.isEmpty && !finalText.isEmpty {
                                    accumulatedText = finalText
                                    continuation.yield(.textDelta(finalText))
                                }
                                completed = true
                                continuation.yield(.completed(accumulatedText))
                                return nil
                            }
                            guard toolRounds < 8 else {
                                throw ChatGPTPlanError.unsupportedFeature("单轮工具调用次数已达上限")
                            }
                            toolRounds += 1
                            let responseItems = try JSONSerialization.jsonObject(with: outputData) as? [[String: Any]] ?? []
                            var toolOutputs: [[String: Any]] = []
                            for call in calls {
                                continuation.yield(.toolActivity(
                                    id: call.callID,
                                    name: call.name,
                                    isComplete: false
                                ))
                                do {
                                    let outcome = try await executeTool(call.name, call.arguments)
                                    continuation.yield(.toolOutcome(call.callID, outcome))
                                    let result = try Self.toolResult(from: outcome)
                                    toolOutputs.append([
                                        "type": "function_call_output",
                                        "call_id": call.callID,
                                        "output": result,
                                    ])
                                    continuation.yield(.toolActivity(
                                        id: call.callID,
                                        name: call.name,
                                        isComplete: true
                                    ))
                                } catch {
                                    continuation.yield(.toolActivity(
                                        id: call.callID,
                                        name: call.name,
                                        isComplete: true
                                    ))
                                    throw error
                                }
                            }
                            guard var requestObject = try JSONSerialization.jsonObject(with: currentBody) as? [String: Any],
                                  var input = requestObject["input"] as? [[String: Any]] else {
                                throw ChatGPTPlanError.invalidResponse
                            }
                            input.append(contentsOf: responseItems)
                            input.append(contentsOf: toolOutputs)
                            requestObject["input"] = input
                            let nextBody = try JSONSerialization.data(withJSONObject: requestObject, options: [.sortedKeys])
                            guard nextBody.count <= 8 * 1_048_576 else { throw ChatGPTPlanError.invalidResponse }
                            return nextBody
                        }
                    }

                    while !completed {
                        var request = URLRequest(url: URL(string: "\(resource)/responses")!)
                        request.httpMethod = "POST"
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.timeoutInterval = 180
                        request.httpBody = currentBody
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else { throw ChatGPTPlanError.invalidResponse }
                        guard (200..<300).contains(http.statusCode) else {
                            let data = try await Self.collectBody(bytes)
                            let error = Self.serverError(status: http.statusCode, data: data, headers: http.allHeaderFields)
                            if http.statusCode == 401, !didRetryUnauthorized {
                                didRetryUnauthorized = true
                                token = try await refresh()
                                continue
                            }
                            throw error
                        }

                        let requestID = Self.requestID(http.allHeaderFields)
                        lastRequestID = requestID
                        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
                           !contentType.contains("text/event-stream") {
                            let data = try await Self.collectBody(bytes)
                            throw Self.serverError(status: http.statusCode, data: data, headers: http.allHeaderFields)
                        }
                        var parser = ChatGPTPlanSSEParser()
                        var nextBody: Data?
                        for try await byte in bytes {
                            guard let frame = parser.append(byte) else { continue }
                            let event = try Self.decodeStreamEvent(
                                name: frame.name,
                                data: frame.data,
                                requestID: requestID
                            )
                            nextBody = try await process(event)
                            if completed || nextBody != nil { break }
                        }
                        if !completed && nextBody == nil {
                            for frame in parser.finish() {
                                let event = try Self.decodeStreamEvent(
                                    name: frame.name,
                                    data: frame.data,
                                    requestID: requestID
                                )
                                nextBody = try await process(event)
                                if completed || nextBody != nil { break }
                            }
                        }
                        if let nextBody {
                            currentBody = nextBody
                            continue
                        }
                        if completed { break }
                        break
                    }
                    guard completed else {
                        throw ChatGPTPlanError.streamProtocol(
                            message: "连接在 response.completed 前结束",
                            requestID: lastRequestID
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    static func decodeStreamEvent(name: String?, data: String, requestID: String? = nil) throws -> InternalStreamEvent {
        let payload = data.hasPrefix("\u{FEFF}") ? String(data.dropFirst()) : data
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            // Some compatible SSE transports append the conventional terminal
            // marker after the typed Responses events. It is not a completion
            // signal for this provider; response.completed remains mandatory.
            return .ignored
        }
        guard let bytes = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ChatGPTPlanError.streamProtocol(message: "无法解析服务端事件", requestID: requestID)
        }
        let type = (object["type"] as? String) ?? name ?? ""
        switch type {
        case "response.reasoning_summary_text.delta", "response.reasoning_summary.delta":
            guard let delta = object["delta"] as? String else { return .ignored }
            return .reasoningSummaryDelta(delta)
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else {
                throw ChatGPTPlanError.streamProtocol(message: "文本增量事件缺少 delta", requestID: requestID)
            }
            return .textDelta(delta)
        case "response.completed":
            let response = object["response"] as? [String: Any] ?? [:]
            let output = response["output"] as? [[String: Any]] ?? []
            let calls = output.compactMap { item -> ChatGPTPlanFunctionCall? in
                guard item["type"] as? String == "function_call",
                      let name = item["name"] as? String,
                      let arguments = item["arguments"] as? String,
                      let callID = (item["call_id"] as? String) ?? (item["id"] as? String),
                      !callID.isEmpty, !name.isEmpty else { return nil }
                return ChatGPTPlanFunctionCall(callID: callID, name: name, arguments: arguments)
            }
            let outputData = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            return .responseCompleted(Self.outputText(output), calls, outputData)
        case "response.failed", "error":
            let response = object["response"] as? [String: Any] ?? object
            let errorObject = response["error"] as? [String: Any] ?? object["error"] as? [String: Any] ?? object
            throw ChatGPTPlanError.server(
                status: (errorObject["status"] as? NSNumber)?.intValue ?? 400,
                code: errorObject["code"] as? String,
                message: (errorObject["message"] as? String) ?? (errorObject["detail"] as? String) ?? "Responses 流返回失败事件",
                requestID: (errorObject["request_id"] as? String) ?? (object["request_id"] as? String) ?? requestID
            )
        case "response.incomplete":
            let response = object["response"] as? [String: Any] ?? [:]
            let incomplete = response["incomplete_details"] as? [String: Any]
            throw ChatGPTPlanError.server(
                status: 200,
                code: incomplete?["reason"] as? String ?? "response_incomplete",
                message: "模型响应未完成",
                requestID: requestID ?? (response["id"] as? String)
            )
        default:
            // Lifecycle, refusal, annotation, tool, and reasoning events are
            // consumed without being mistaken for completion. Text is emitted
            // only from response.output_text.delta.
            return .ignored
        }
    }

    private static func outputText(_ output: Any?) -> String {
        guard let items = output as? [[String: Any]] else { return "" }
        return items.flatMap { item -> [String] in
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { part in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }
        }.joined()
    }

    nonisolated private static func toolResult(from response: String) throws -> String {
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTPlanError.invalidResponse
        }
        if let result = object["result"] as? String { return result }
        if let message = object["error"] as? String {
            throw ChatGPTPlanError.unsupportedFeature(message)
        }
        throw ChatGPTPlanError.invalidResponse
    }

    private static func collectBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 1_048_576 { break }
        }
        return data
    }

    private static func decodeToken(_ data: Data, preservingIDToken: String?) throws -> ChatGPTPlanTokenResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String,
              let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue else {
            let error = serverError(status: 200, data: data, headers: [:])
            if case let .server(_, code, _, _) = error, code != nil { throw error }
            throw ChatGPTPlanError.invalidResponse
        }
        let scope = object["scope"] as? String ?? ""
        let scopes = scope.split(whereSeparator: \.isWhitespace).map(String.init)
        let earliest = (object["earliest_refresh_at"] as? String).flatMap(parseDate)
            ?? (object["earliest_refresh_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return ChatGPTPlanTokenResponse(
            accessToken: access,
            refreshToken: object["refresh_token"] as? String,
            idToken: (object["id_token"] as? String) ?? preservingIDToken,
            scopes: scopes,
            accessExpiresAt: Date().addingTimeInterval(expiresIn),
            earliestRefreshAt: earliest
        )
    }

    private static func serverError(status: Int, data: Data, headers: [AnyHashable: Any]) -> ChatGPTPlanError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = object["error"] as? [String: Any] ?? object
        let code = (error["code"] as? String) ?? (object["code"] as? String) ?? (object["error"] as? String)
        let message = (error["message"] as? String)
            ?? (object["detail"] as? String)
            ?? (object["error_description"] as? String)
            ?? (object["message"] as? String)
            ?? (object["error"] as? String)
            ?? "ChatGPT 服务返回了错误响应"
        let requestID = requestID(headers)
            ?? (object["request_id"] as? String)
        return .server(status: status, code: code, message: message, requestID: requestID)
    }

    private static func requestID(_ headers: [AnyHashable: Any]) -> String? {
        headers.first(where: {
            String(describing: $0.key).lowercased() == "x-request-id"
                || String(describing: $0.key).lowercased() == "openai-request-id"
        }).map { String(describing: $0.value) }
    }

    private static func isTerminalRefreshError(_ error: ChatGPTPlanError) -> Bool {
        guard case let .server(_, code, _, _) = error else { return false }
        return ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused", "subscription_sharing_invalid_user"].contains(code)
    }

    private static func formEncoded(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = values.keys.sorted().map { key in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = (values[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        precondition(status == errSecSuccess, "Secure random generation failed")
        return base64URL(data)
    }

    private static func pkceChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private static func verifyRS256(signature: Data, signedData: Data, modulus: Data, exponent: Data) -> Bool {
        let keyData = derSequence(derInteger(modulus) + derInteger(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8
        ]
        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &keyError) else { return false }
        var verifyError: Unmanaged<CFError>?
        return SecKeyVerifySignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            signedData as CFData,
            signature as CFData,
            &verifyError
        )
    }

    private static func derInteger(_ data: Data) -> Data {
        var bytes = Array(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = [0] }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return derTag(0x02, bytes)
    }

    private static func derSequence(_ data: Data) -> Data { derTag(0x30, Array(data)) }

    private static func derTag(_ tag: UInt8, _ bytes: [UInt8]) -> Data {
        var result = Data([tag])
        if bytes.count < 128 {
            result.append(UInt8(bytes.count))
        } else {
            var length = bytes.count
            var encoded: [UInt8] = []
            while length > 0 { encoded.insert(UInt8(length & 0xff), at: 0); length >>= 8 }
            result.append(0x80 | UInt8(encoded.count))
            result.append(contentsOf: encoded)
        }
        result.append(contentsOf: bytes)
        return result
    }

    private static func audience(_ value: Any?, contains expected: String) -> Bool {
        if let string = value as? String { return string == expected }
        if let values = value as? [String] { return values.contains(expected) }
        return false
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    private static func parseDate(_ string: String) -> Date? {
        if let numeric = Double(string) { return Date(timeIntervalSince1970: numeric) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

enum ChatGPTPlanStreamEvent: Sendable {
    case textDelta(String)
    case reasoningSummaryDelta(String)
    case toolActivity(id: String, name: String, isComplete: Bool)
    case toolOutcome(String, String)
    case completed(String)
}

struct ChatGPTPlanFunctionCall: Sendable {
    let callID: String
    let name: String
    let arguments: String
}

struct ChatGPTPlanSSEFrame {
    let name: String?
    let data: String
}

/// Incremental SSE framing that accepts LF, CRLF, and CR line endings and
/// dispatches an event only on a blank line. It retains at most one event.
struct ChatGPTPlanSSEParser {
    private var line = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    private var skipLineFeedAfterCarriageReturn = false

    mutating func append(_ byte: UInt8) -> ChatGPTPlanSSEFrame? {
        if skipLineFeedAfterCarriageReturn {
            skipLineFeedAfterCarriageReturn = false
            if byte == 0x0A { return nil }
        }
        if byte == 0x0D {
            skipLineFeedAfterCarriageReturn = true
            return consumeLine()
        }
        if byte == 0x0A { return consumeLine() }
        line.append(byte)
        return nil
    }

    mutating func finish() -> [ChatGPTPlanSSEFrame] {
        var frames: [ChatGPTPlanSSEFrame] = []
        if !line.isEmpty, let frame = consumeLine() { frames.append(frame) }
        if let frame = takeFrame() { frames.append(frame) }
        return frames
    }

    private mutating func consumeLine() -> ChatGPTPlanSSEFrame? {
        let value = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if value.isEmpty { return takeFrame() }
        if value.hasPrefix(":") { return nil }

        guard let separator = value.firstIndex(of: ":") else { return nil }
        let field = value[..<separator]
        var fieldValue = String(value[value.index(after: separator)...])
        if fieldValue.first == " " { fieldValue.removeFirst() }
        switch field {
        case "event": eventName = fieldValue
        case "data": dataLines.append(fieldValue)
        default: break
        }
        return nil
    }

    private mutating func takeFrame() -> ChatGPTPlanSSEFrame? {
        defer {
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        return ChatGPTPlanSSEFrame(name: eventName, data: dataLines.joined(separator: "\n"))
    }
}

enum InternalStreamEvent {
    case ignored
    case textDelta(String)
    case reasoningSummaryDelta(String)
    case responseCompleted(String, [ChatGPTPlanFunctionCall], Data)
}

private struct OAuthTransaction {
    let state: String
    let nonce: String
    let verifier: String
    let redirectURI: URL
}

private struct OAuthCallbackResult {
    let code: String
    let clientID: String?
    let scopes: [String]
}

private struct ChatGPTPlanIdentity {
    let subject: String
    let email: String?
    let displayName: String?
}

private struct ChatGPTPlanTokenResponse {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    var scopes: [String]
    let accessExpiresAt: Date
    let earliestRefreshAt: Date?
}

struct ChatGPTPlanCredential: Codable {
    let hostID: String
    var clientID: String?
    var subject: String?
    var email: String?
    var displayName: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var scopes: [String]
    var accessExpiresAt: Date?
    var earliestRefreshAt: Date?
}

private final class ChatGPTPlanCredentialStore: ChatGPTPlanCredentialStoring, @unchecked Sendable {
    private let service = "com.mychat.ios.chatgpt-plan"
    private let accountKey = "credential.v1"
    private let hostIDKey = "host-id.v1"

    func loadCredential() throws -> ChatGPTPlanCredential? {
        guard let data = try loadData(account: accountKey) else { return nil }
        return try JSONDecoder().decode(ChatGPTPlanCredential.self, from: data)
    }

    func save(_ credential: ChatGPTPlanCredential) throws {
        try saveData(JSONEncoder().encode(credential), account: accountKey)
    }

    func deleteCredential() throws { try delete(account: accountKey) }

    func loadOrCreateHostID() throws -> String {
        if let data = try loadData(account: hostIDKey), let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        let created = "urn:uuid:\(UUID().uuidString.lowercased())"
        try saveData(Data(created.utf8), account: hostIDKey)
        return created
    }

    func deleteHostID() throws { try delete(account: hostIDKey) }

    private func loadData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainStoreError(status: status) }
        return data
    }

    private func saveData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainStoreError(status: status) }
        } else if update != errSecSuccess {
            throw KeychainStoreError(status: update)
        }
    }

    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStoreError(status: status) }
    }
}

private struct KeychainStoreError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain 操作失败（\(status)）" }
}

private final class LoopbackOAuthCallbackServer {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.mychat.ios.chatgpt-oauth-loopback")
    private let listener: NWListener
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var callbackPort: UInt16?
    private var pendingCallbackURL: URL?
    private var finished = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: .any
        )
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port?.rawValue else {
                        self.fail(ChatGPTPlanError.callback("回环端口无法使用")); return
                    }
                    self.lock.lock()
                    self.callbackPort = port
                    let ready = self.readyContinuation
                    self.readyContinuation = nil
                    self.lock.unlock()
                    ready?.resume(returning: URL(string: "http://127.0.0.1:\(port)/auth/callback")!)
                case let .failed(error): self.fail(error)
                case .cancelled: self.fail(ChatGPTPlanError.cancelled)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pendingCallbackURL {
                    self.pendingCallbackURL = nil
                    lock.unlock()
                    continuation.resume(returning: pendingCallbackURL)
                } else if finished {
                    lock.unlock()
                    continuation.resume(throwing: ChatGPTPlanError.cancelled)
                } else {
                    callbackContinuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() { fail(ChatGPTPlanError.cancelled) }

    func stop() {
        lock.lock()
        finished = true
        let ready = readyContinuation
        let callback = callbackContinuation
        readyContinuation = nil
        callbackContinuation = nil
        lock.unlock()
        ready?.resume(throwing: ChatGPTPlanError.cancelled)
        callback?.resume(throwing: ChatGPTPlanError.cancelled)
        listener.cancel()
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let ready = readyContinuation
        let callback = callbackContinuation
        readyContinuation = nil
        callbackContinuation = nil
        lock.unlock()
        ready?.resume(throwing: error)
        callback?.resume(throwing: error)
        listener.cancel()
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data,
                  let request = String(data: data, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first else {
                self.respond(status: 400, body: "Invalid callback", connection: connection)
                return
            }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET",
                  let port = self.currentPort,
                  let target = URL(string: "http://127.0.0.1:\(port)\(parts[1])"),
                  target.path == "/auth/callback" else {
                self.respond(status: 404, body: "Not found", connection: connection)
                return
            }
            self.respond(status: 200, body: "授权已返回 MyChat。你可以关闭此页面并返回应用。", connection: connection)
            self.lock.lock()
            guard !self.finished else { self.lock.unlock(); return }
            self.finished = true
            let callback = self.callbackContinuation
            self.callbackContinuation = nil
            if callback == nil { self.pendingCallbackURL = target }
            self.lock.unlock()
            callback?.resume(returning: target)
            self.listener.cancel()
        }
    }

    private var currentPort: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return callbackPort
    }

    private func respond(status: Int, body: String, connection: NWConnection) {
        let bytes = Data(body.utf8)
        let response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
