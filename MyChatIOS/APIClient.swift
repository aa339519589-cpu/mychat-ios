import Foundation

enum APIError: LocalizedError {
    case message(String)
    case response(
        message: String,
        statusCode: Int,
        code: String?,
        retryable: Bool,
        retryAfter: TimeInterval?,
        requestID: String?
    )

    var errorDescription: String? {
        switch self {
        case let .message(value):
            return value
        case let .response(message, _, _, _, _, _):
            return message
        }
    }

    var statusCode: Int? {
        if case let .response(_, statusCode, _, _, _, _) = self { return statusCode }
        return nil
    }

    var isRetryable: Bool {
        if case let .response(_, _, _, retryable, _, _) = self { return retryable }
        return false
    }
}

actor APIClient {
    private let baseURL: URL
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()
    private let network: URLSession
    private var bootstrap: MobileBootstrap?
    private var session: AuthSession?

    init(baseURL: URL = AppConfig.apiBaseURL) {
        self.baseURL = baseURL
        self.session = KeychainStore.load()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let box = try decoder.singleValueContainer()
            let value = try box.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: box, debugDescription: "Invalid ISO-8601 date")
        }
        self.decoder = decoder

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 5 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        self.network = URLSession(configuration: configuration)
    }

    func restoreSession() async -> Bool {
        guard session != nil else { return false }
        do {
            let config = try await loadBootstrap()
            var request = URLRequest(url: config.supabaseUrl.appending(path: "auth/v1/user"))
            request.timeoutInterval = 20
            request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            let (_, response) = try await data(for: request)
            if 200..<300 ~= response.statusCode {
                await runNativeReplyProbeIfRequested()
                return true
            }
            if response.statusCode == 401 {
                _ = try await refreshSession()
                await runNativeReplyProbeIfRequested()
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func signIn(email: String, password: String) async throws {
        let config = try await loadBootstrap()
        var components = URLComponents(
            url: config.supabaseUrl.appending(path: "auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(["email": email, "password": password])
        let value: AuthSession = try await send(request)
        try saveSession(value)
    }

    func signOut() {
        session = nil
        KeychainStore.clear()
    }

    func conversations() async throws -> [Conversation] {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "conversations", query: [
            "select": "id,title,updated_at",
            "order": "updated_at.desc",
            "limit": "100",
        ])
        return try await send(try await authorizedRequest(url, config: config))
    }

    func messages(conversationID: UUID) async throws -> [ChatMessage] {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "messages", query: [
            "select": "id,role,content,thinking,created_at",
            "conversation_id": "eq.\(conversationID.uuidString)",
            "order": "created_at.asc",
            "limit": "300",
        ])
        return try await send(try await authorizedRequest(url, config: config))
    }

    func models() async throws -> [ModelChoice] {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "endpoints", query: [
            "select": "id,name,model,output_kind",
            "output_kind": "eq.chat",
            "order": "updated_at.desc",
        ])
        do {
            let endpoints: [EndpointRow] = try await send(
                try await authorizedRequest(url, config: config)
            )
            return ModelChoice.platform + endpoints.map {
                ModelChoice(
                    id: "endpoint-\($0.id.uuidString)",
                    name: $0.name.isEmpty ? $0.model : $0.name,
                    detail: $0.model,
                    selection: .endpoint(id: $0.id)
                )
            }
        } catch {
            return ModelChoice.platform
        }
    }

    func account() async throws -> AccountSnapshot {
        let config = try await loadBootstrap()
        var request = URLRequest(url: config.supabaseUrl.appending(path: "auth/v1/user"))
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    func updatePassword(_ password: String) async throws {
        let config = try await loadBootstrap()
        var request = URLRequest(url: config.supabaseUrl.appending(path: "auth/v1/user"))
        request.httpMethod = "PUT"
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
        let _: AccountSnapshot = try await send(request)
    }

    func memories() async throws -> [MemoryRecord] {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "memories", query: [
            "select": "id,content,created_at,updated_at",
            "order": "created_at.asc",
            "limit": "200",
        ])
        return try await send(try await authorizedRequest(url, config: config))
    }

    func addMemory(_ content: String) async throws -> MemoryRecord {
        let config = try await loadBootstrap()
        let user = try await account()
        let url = try restURL(config, path: "memories", query: ["select": "*"])
        var request = try await authorizedRequest(url, config: config)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "user_id": user.id.uuidString,
            "content": content,
        ])
        let rows: [MemoryRecord] = try await send(request)
        guard let memory = rows.first else { throw APIError.message("记忆保存失败") }
        return memory
    }

    func updateMemory(id: UUID, content: String) async throws {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "memories", query: ["id": "eq.\(id.uuidString)"])
        var request = try await authorizedRequest(url, config: config)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "content": content,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ])
        try await sendVoid(request)
    }

    func deleteMemory(id: UUID) async throws {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "memories", query: ["id": "eq.\(id.uuidString)"])
        var request = try await authorizedRequest(url, config: config)
        request.httpMethod = "DELETE"
        try await sendVoid(request)
    }

    func deleteAllMemories() async throws {
        let config = try await loadBootstrap()
        let user = try await account()
        let url = try restURL(config, path: "memories", query: [
            "user_id": "eq.\(user.id.uuidString)",
        ])
        var request = try await authorizedRequest(url, config: config)
        request.httpMethod = "DELETE"
        try await sendVoid(request)
    }

    func profile() async throws -> ProfileSnapshot? {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "profiles", query: [
            "select": "memory_enabled,custom_system_prompt,tokens_5h,window_5h_start,tokens_7d,window_7d_start,balance",
            "limit": "1",
        ])
        let rows: [ProfileSnapshot] = try await send(
            try await authorizedRequest(url, config: config)
        )
        return rows.first
    }

    func setMemoryEnabled(_ enabled: Bool) async throws {
        try await upsertProfile(["memory_enabled": enabled])
    }

    func systemPrompt() async throws -> String {
        try await profile()?.customSystemPrompt ?? ""
    }

    func saveSystemPrompt(_ prompt: String) async throws {
        try await upsertProfile(["custom_system_prompt": prompt])
    }

    func quota() async throws -> QuotaSnapshot {
        let snapshot = try await profile()
        let now = Date()
        return QuotaSnapshot(
            tokens5h: snapshot?.tokens5h ?? 0,
            window5hStart: snapshot?.window5hStart ?? now,
            tokens7d: snapshot?.tokens7d ?? 0,
            window7dStart: snapshot?.window7dStart ?? now,
            balance: snapshot?.balance ?? 0
        )
    }

    func redeem(code: String) async throws -> Int {
        let config = try await loadBootstrap()
        let url = config.supabaseUrl.appending(path: "rest/v1/rpc/redeem_invitation_code")
        var request = try await authorizedRequest(url, config: config)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input_code": code])
        let rows: [RedeemCodeRow] = try await send(request)
        guard let result = rows.first else { throw APIError.message("兑换码无效或已被使用") }
        return result.tokensAdded
    }

    func deleteAllConversations() async throws {
        var request = try await appRequest(path: "api/conversations", method: "DELETE")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await sendVoid(request)
    }

    func modelEndpoints() async throws -> [ModelEndpointSummary] {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "endpoints", query: [
            "select": "id,name,model,output_kind,base_url,auth_type",
            "order": "updated_at.desc",
        ])
        let rows: [EndpointRow] = try await send(
            try await authorizedRequest(url, config: config)
        )
        return rows.map {
            ModelEndpointSummary(
                id: $0.id,
                name: $0.name,
                baseURL: $0.baseURL ?? "",
                model: $0.model,
                outputKind: $0.outputKind ?? "chat",
                authType: $0.authType ?? "bearer",
                needsReconnect: false
            )
        }
    }

    func discoverModels(
        baseURL: String,
        apiKey: String,
        endpointID: UUID? = nil
    ) async throws -> [DiscoveredModel] {
        var body: [String: Any] = endpointID.map { ["endpointId": $0.uuidString] } ?? [
            "baseUrl": baseURL,
            "apiKey": apiKey,
            "authType": "auto",
        ]
        if endpointID == nil {
            body["baseUrl"] = baseURL
            body["apiKey"] = apiKey
        }
        var request = try await appRequest(path: "api/endpoints/discover", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response: ModelDiscoveryResponse = try await send(request)
        return response.models
    }

    func createModelEndpoint(
        baseURL: String,
        apiKey: String,
        model: String,
        displayName: String?
    ) async throws -> ModelEndpointSummary {
        var body: [String: Any] = [
            "baseUrl": baseURL,
            "apiKey": apiKey,
            "authType": "auto",
            "model": model,
            "outputKind": "chat",
        ]
        if let displayName, !displayName.isEmpty { body["displayName"] = displayName }
        var request = try await appRequest(path: "api/endpoints", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response: ModelEndpointResponse = try await send(request)
        return response.endpoint
    }

    func updateModelEndpoint(
        id: UUID,
        baseURL: String?,
        apiKey: String?,
        model: String,
        displayName: String?
    ) async throws -> ModelEndpointSummary {
        var body: [String: Any] = [
            "model": model,
            "outputKind": "chat",
        ]
        if let baseURL { body["baseUrl"] = baseURL }
        if let apiKey { body["apiKey"] = apiKey }
        if let displayName, !displayName.isEmpty { body["displayName"] = displayName }
        var request = try await appRequest(
            path: "api/endpoints/\(id.uuidString)",
            method: "PATCH"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response: ModelEndpointResponse = try await send(request)
        return response.endpoint
    }

    func deleteModelEndpoint(id: UUID) async throws {
        try await sendVoid(
            try await appRequest(path: "api/endpoints/\(id.uuidString)", method: "DELETE")
        )
    }

    // MARK: - Chat reply pipeline

    func enqueue(
        text: String,
        conversationID: UUID,
        history: [ChatMessage],
        model: ModelChoice,
        options: ChatRequestOptions,
        attachments: [ChatAttachment],
        createConversation: Bool,
        conversationTitle: String,
        userMessageID: UUID,
        assistantMessageID: UUID,
        generationID: UUID
    ) async throws -> ChatEnqueueResponse {
        let titleSeed = conversationTitle.isEmpty ? text : conversationTitle
        let title = String(titleSeed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        var requestMessages = history.map { message -> [String: Any] in
            var value: [String: Any] = [
                "id": message.id.uuidString.lowercased(),
                "role": message.role,
                "content": message.content,
            ]
            if let createdAt = message.createdAt {
                value["ts"] = ISO8601DateFormatter().string(from: createdAt)
            }
            return value
        }
        requestMessages.append([
            "id": userMessageID.uuidString.lowercased(),
            "role": "user",
            "content": text,
        ])

        var body: [String: Any] = [
            "conversationId": conversationID.uuidString.lowercased(),
            "userMessageId": userMessageID.uuidString.lowercased(),
            "assistantMessageId": assistantMessageID.uuidString.lowercased(),
            "generationId": generationID.uuidString.lowercased(),
            "messages": requestMessages,
            "turn": [
                "schemaVersion": 1,
                "createConversation": createConversation,
                "title": title.isEmpty ? "新对话" : title,
                "projectId": NSNull(),
            ],
            "searchMode": options.web ? "web" : "off",
            "historyRetrieval": options.retrieval,
            "deepResearch": options.deepResearch,
        ]

        if !attachments.isEmpty {
            body["attachments"] = attachments.map { attachment -> [String: Any] in
                var value: [String: Any] = [
                    "name": attachment.name,
                    "dataUrl": attachment.dataURL,
                    "isPdf": attachment.isPDF,
                ]
                if let text = attachment.text, !text.isEmpty { value["text"] = text }
                return value
            }
        }

        switch model.selection {
        case let .platform(tier):
            body["tier"] = tier
        case let .endpoint(id):
            body["endpointId"] = id.uuidString.lowercased()
        }

        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "chat:\(generationID.uuidString.lowercased())",
            forHTTPHeaderField: "Idempotency-Key"
        )
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let accepted: ChatEnqueueResponse = try await send(request)
        guard accepted.jobId == generationID,
              accepted.assistantMessageId == assistantMessageID else {
            throw APIError.message("服务器返回了不匹配的模型任务")
        }
        return accepted
    }

    private struct JobSnapshot {
        let id: UUID
        let status: String
        let errorMessage: String?
    }

    func waitForAssistantReply(
        _ accepted: ChatEnqueueResponse,
        conversationID: UUID,
        assistantMessageID: UUID
    ) async throws -> ChatMessage {
        guard accepted.assistantMessageId == assistantMessageID else {
            throw APIError.message("模型任务与回复消息不匹配")
        }

        let deadline = Date().addingTimeInterval(3 * 60)
        var missingReads = 0
        var completedWithoutMessageReads = 0

        while Date() < deadline {
            try Task.checkCancellation()
            if let snapshot = try await readJobSnapshot(accepted.jobId) {
                missingReads = 0
                switch snapshot.status {
                case "completed":
                    if let message = try await readAssistantMessage(
                        id: assistantMessageID,
                        conversationID: conversationID
                    ), !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return message
                    }
                    completedWithoutMessageReads += 1
                    if completedWithoutMessageReads >= 10 {
                        throw APIError.message("模型任务已完成，但持久化回复为空")
                    }
                case "failed", "cancelled":
                    throw APIError.message(snapshot.errorMessage ?? "模型回复失败")
                default:
                    break
                }
            } else {
                missingReads += 1
                if missingReads > 10 { throw APIError.message("模型任务不存在") }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw APIError.message("模型回复超时")
    }

    private func readAssistantMessage(
        id: UUID,
        conversationID: UUID
    ) async throws -> ChatMessage? {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "messages", query: [
            "select": "id,role,content,thinking,created_at",
            "id": "eq.\(id.uuidString.lowercased())",
            "conversation_id": "eq.\(conversationID.uuidString.lowercased())",
            "role": "eq.assistant",
            "limit": "1",
        ])
        let rows: [ChatMessage] = try await send(
            try await authorizedRequest(url, config: config)
        )
        guard let message = rows.first else { return nil }
        guard message.id == id, message.role == "assistant" else {
            throw APIError.message("持久化回复身份不匹配")
        }
        return message
    }

    private func readJobSnapshot(_ jobID: UUID) async throws -> JobSnapshot? {
        var request = URLRequest(
            url: baseURL.appending(path: "api/v1/jobs/\(jobID.uuidString.lowercased())")
        )
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.data(for: request)
        if response.statusCode == 404 { return nil }
        guard 200..<300 ~= response.statusCode else {
            throw responseError(data, response: response)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let job = root["job"] as? [String: Any],
              let rawID = job["id"] as? String,
              let id = UUID(uuidString: rawID),
              id == jobID,
              let status = job["status"] as? String else {
            throw APIError.message("模型任务状态格式无法识别")
        }

        let errorMessage = (job["error"] as? [String: Any])?["message"] as? String
            ?? job["errorCode"] as? String
            ?? job["error_code"] as? String
        return JobSnapshot(id: id, status: status, errorMessage: errorMessage)
    }

    private func runNativeReplyProbeIfRequested() async {
#if DEBUG
        guard ProcessInfo.processInfo.environment["NATIVE_REPLY_PROBE"] == "1" else { return }
        let conversationID = UUID()
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        let generationID = UUID()
        do {
            print("[MyChatProbe] starting single-path native reply probe")
            let accepted = try await enqueue(
                text: "仅回复：原生链路正常",
                conversationID: conversationID,
                history: [],
                model: ModelChoice.platform[2],
                options: ChatRequestOptions(),
                attachments: [],
                createConversation: true,
                conversationTitle: "原生链路验收",
                userMessageID: userMessageID,
                assistantMessageID: assistantMessageID,
                generationID: generationID
            )
            print("[MyChatProbe] enqueue accepted job=\(accepted.jobId.uuidString.lowercased())")
            let reply = try await waitForAssistantReply(
                accepted,
                conversationID: conversationID,
                assistantMessageID: assistantMessageID
            )
            print(
                "[MyChatProbe] completed assistant=\(reply.id.uuidString.lowercased()) "
                    + "content=\(reply.content)"
            )
        } catch {
            print("[MyChatProbe] failed: \(error.localizedDescription)")
        }
#endif
    }

    // MARK: - Shared transport

    private func loadBootstrap() async throws -> MobileBootstrap {
        if let bootstrap { return bootstrap }
        if let embedded = AppConfig.embeddedBootstrap {
            bootstrap = embedded
            return embedded
        }
        var request = URLRequest(url: baseURL.appending(path: "api/mobile/config"))
        request.timeoutInterval = 20
        let value: MobileBootstrap = try await send(request)
        bootstrap = value
        return value
    }

    private func accessToken() async throws -> String {
        guard let current = session else { throw APIError.message("请先登录") }
        if let expiresAt = current.expiresAt, expiresAt <= Date().timeIntervalSince1970 + 60 {
            return try await refreshSession().accessToken
        }
        return current.accessToken
    }

    private func refreshSession() async throws -> AuthSession {
        guard let current = session else { throw APIError.message("登录已过期") }
        let config = try await loadBootstrap()
        var components = URLComponents(
            url: config.supabaseUrl.appending(path: "auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(["refresh_token": current.refreshToken])
        let refreshed: AuthSession = try await send(request)
        try saveSession(refreshed)
        return refreshed
    }

    private func saveSession(_ value: AuthSession) throws {
        session = value
        try KeychainStore.save(value)
    }

    private func restURL(
        _ config: MobileBootstrap,
        path: String,
        query: [String: String]
    ) throws -> URL {
        var components = URLComponents(
            url: config.supabaseUrl.appending(path: "rest/v1/\(path)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query.map(URLQueryItem.init(name:value:))
        guard let url = components.url else { throw APIError.message("请求地址无效") }
        return url
    }

    private func authorizedRequest(_ url: URL, config: MobileBootstrap) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func appRequest(path: String, method: String) async throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func upsertProfile(_ values: [String: Any]) async throws {
        let config = try await loadBootstrap()
        let user = try await account()
        let url = try restURL(config, path: "profiles", query: ["on_conflict": "user_id"])
        var request = try await authorizedRequest(url, config: config)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        var body = values
        body["user_id"] = user.id.uuidString
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await sendVoid(request)
    }

    private func responseError(_ data: Data, response: HTTPURLResponse) -> APIError {
        let status = response.statusCode
        var message = "请求失败（\(status)）"
        var code: String?
        var requestID: String?
        var retryable = status == 408 || status == 425 || status == 429 || status >= 500

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let value = object["error"] as? String {
                message = value
            } else if let value = object["msg"] as? String {
                message = value
            } else if let value = object["message"] as? String {
                message = value
            } else if let value = object["error_description"] as? String {
                message = value
            } else if let error = object["error"] as? [String: Any] {
                if let value = error["message"] as? String { message = value }
                if let value = error["code"] as? String { code = value }
                if let value = error["retryable"] as? Bool { retryable = value }
                if let value = error["request_id"] as? String { requestID = value }
            }
            if requestID == nil, let value = object["request_id"] as? String { requestID = value }
        }

        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return APIError.response(
            message: message,
            statusCode: status,
            code: code,
            retryable: retryable,
            retryAfter: retryAfter,
            requestID: requestID
        )
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await self.data(for: request)
        guard 200..<300 ~= response.statusCode else {
            throw responseError(data, response: response)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.message("服务器响应格式无法识别")
        }
    }

    private func sendVoid(_ request: URLRequest) async throws {
        let (data, response) = try await self.data(for: request)
        guard 200..<300 ~= response.statusCode else {
            throw responseError(data, response: response)
        }
    }

    private func data(
        for request: URLRequest,
        allowTokenRefresh: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("网络响应无效")
        }
        guard http.statusCode == 401,
              allowTokenRefresh,
              request.value(forHTTPHeaderField: "Authorization") != nil,
              request.url?.path.hasSuffix("/auth/v1/token") != true else {
            return (data, http)
        }
        let refreshed = try await refreshSession()
        var retry = request
        retry.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
        return try await self.data(for: retry, allowTokenRefresh: false)
    }
}

private struct RedeemCodeRow: Decodable {
    let tokensAdded: Int

    enum CodingKeys: String, CodingKey {
        case tokensAdded = "tokens_added"
    }
}

private struct ModelDiscoveryResponse: Decodable {
    let models: [DiscoveredModel]
}

private struct ModelEndpointResponse: Decodable {
    let endpoint: ModelEndpointSummary
}
