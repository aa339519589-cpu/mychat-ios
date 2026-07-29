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

    var retryAfter: TimeInterval? {
        if case let .response(_, _, _, _, retryAfter, _) = self { return retryAfter }
        return nil
    }
}

actor APIClient {
    private let baseURL: URL
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()
    private var bootstrap: MobileBootstrap?
    private var session: AuthSession?

    init(baseURL: URL = AppConfig.apiBaseURL) {
        self.baseURL = baseURL
        self.session = KeychainStore.load()
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date"
            )
        }
    }

    func restoreSession() async -> Bool {
        guard session != nil else { return false }
        do {
            let config = try await loadBootstrap()
            var request = URLRequest(url: config.supabaseUrl.appending(path: "auth/v1/user"))
            request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 401 {
                _ = try await refreshSession()
                return true
            }
            return 200..<300 ~= http.statusCode
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
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(["email": email, "password": password])
        try saveSession(try await send(request))
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
        let request = try await authorizedRequest(url, config: config)
        return try await send(request)
    }

    func messages(conversationID: UUID) async throws -> [ChatMessage] {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "messages", query: [
            "select": "id,role,content,thinking,created_at",
            "conversation_id": "eq.\(conversationID.uuidString)",
            "order": "created_at.asc",
            "limit": "300",
        ])
        let request = try await authorizedRequest(url, config: config)
        return try await send(request)
    }

    func models() async throws -> [ModelChoice] {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "endpoints", query: [
            "select": "id,name,model,output_kind",
            "output_kind": "eq.chat",
            "order": "updated_at.desc",
        ])
        let request = try await authorizedRequest(url, config: config)
        let endpoints: [EndpointRow]
        do {
            endpoints = try await send(request)
        } catch {
            return ModelChoice.platform
        }
        return ModelChoice.platform + endpoints.map {
            ModelChoice(
                id: "endpoint-\($0.id.uuidString)",
                name: $0.name.isEmpty ? $0.model : $0.name,
                detail: $0.model,
                selection: .endpoint(id: $0.id)
            )
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
        let request = try await appRequest(
            path: "api/endpoints/\(id.uuidString)",
            method: "DELETE"
        )
        try await sendVoid(request)
    }

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
        let submittedAt = Date()
        let userMessage = ChatMessage(
            id: userMessageID,
            role: "user",
            content: text,
            createdAt: submittedAt
        )
        let messages = history + [userMessage]
        let fallbackTitle = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let title = String((conversationTitle.isEmpty ? fallbackTitle : conversationTitle).prefix(200))
        let serverHasConversation = try? await conversationExists(conversationID)
        let authoritativeCreate = serverHasConversation.map { !$0 } ?? createConversation

        var body: [String: Any] = [
            "conversationId": conversationID.uuidString,
            "userMessageId": userMessageID.uuidString,
            "assistantMessageId": assistantMessageID.uuidString,
            "generationId": generationID.uuidString,
            "messages": messages.map { message -> [String: Any] in
                var value: [String: Any] = [
                    "id": message.id.uuidString,
                    "role": message.role,
                    "content": message.content,
                ]
                // The authoritative timestamp for the newly submitted user turn
                // stays server-owned. Historical timestamps are context only.
                if message.id != userMessageID, let createdAt = message.createdAt {
                    value["ts"] = ISO8601DateFormatter().string(from: createdAt)
                }
                return value
            },
            "turn": [
                "schemaVersion": 1,
                "createConversation": authoritativeCreate,
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
                if let text = attachment.text, !text.isEmpty {
                    value["text"] = text
                }
                return value
            }
        }
        switch model.selection {
        case let .platform(tier):
            body["tier"] = tier
        case let .endpoint(id):
            body["endpointId"] = id.uuidString
        }

        // One command, one set of durable IDs, one byte-identical body. A retry
        // can never create a second turn for the same tap.
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var retryAttempt = 0

        while true {
            try Task.checkCancellation()
            do {
                return try await postEnqueue(bodyData, generationID: generationID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }

                // The POST may have reached the server even when its acknowledgement
                // was lost. Read the durable job before deciding to send again.
                if let accepted = try? await reconcileEnqueue(generationID: generationID) {
                    return accepted
                }

                guard let delay = enqueueRetryDelay(for: error, attempt: retryAttempt) else {
                    throw error
                }
                retryAttempt += 1
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func postEnqueue(_ bodyData: Data, generationID: UUID) async throws -> ChatEnqueueResponse {
        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 50
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("chat:\(generationID.uuidString)", forHTTPHeaderField: "Idempotency-Key")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        return try await send(request)
    }

    private func reconcileEnqueue(generationID: UUID) async throws -> ChatEnqueueResponse? {
        var request = URLRequest(
            url: baseURL.appending(path: "api/v1/jobs/\(generationID.uuidString)")
        )
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("作业状态响应无效")
        }
        if http.statusCode == 404 { return nil }
        guard 200..<300 ~= http.statusCode else {
            throw responseError(data, response: http)
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let job = root["job"] as? [String: Any],
            let id = job["id"] as? String,
            id.caseInsensitiveCompare(generationID.uuidString) == .orderedSame,
            let status = job["status"] as? String
        else {
            throw APIError.message("作业状态格式无法识别")
        }
        return ChatEnqueueResponse(
            jobId: generationID,
            streamUrl: "/api/v1/jobs/\(generationID.uuidString)/events?from_seq=0",
            status: status
        )
    }

    private func conversationExists(_ conversationID: UUID) async throws -> Bool {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "conversations", query: [
            "select": "id",
            "id": "eq.\(conversationID.uuidString)",
            "limit": "1",
        ])
        let request = try await authorizedRequest(url, config: config)
        struct ExistingConversation: Decodable { let id: UUID }
        let rows: [ExistingConversation] = try await send(request)
        return !rows.isEmpty
    }

    func eventStream(_ accepted: ChatEnqueueResponse) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await consumeEvents(accepted, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func consumeEvents(
        _ accepted: ChatEnqueueResponse,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async throws {
        var sequence = 0
        var retryNanoseconds: UInt64 = 250_000_000
        let deadline = Date().addingTimeInterval(20 * 60)

        while !Task.isCancelled && Date() < deadline {
            do {
                let terminal = try await consumeConnection(
                    path: accepted.streamUrl,
                    fromSequence: &sequence,
                    continuation: continuation
                )
                if terminal { return }
                retryNanoseconds = 250_000_000
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError {
                if !error.isRetryable { throw error }
                if Date() >= deadline { throw error }
            } catch {
                if Date() >= deadline { throw error }
            }
            try await Task.sleep(nanoseconds: retryNanoseconds)
            retryNanoseconds = min(5_000_000_000, retryNanoseconds * 2)
        }
        if !Task.isCancelled { throw APIError.message("回复连接超时") }
    }

    private func consumeConnection(
        path: String,
        fromSequence sequence: inout Int,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async throws -> Bool {
        guard var components = URLComponents(
            url: URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL,
            resolvingAgainstBaseURL: false
        ) else { throw APIError.message("流式地址无效") }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "from_seq" }
        query.append(URLQueryItem(name: "from_seq", value: String(sequence)))
        components.queryItems = query
        guard let url = components.url else { throw APIError.message("流式地址无效") }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if sequence > 0 { request.setValue(String(sequence), forHTTPHeaderField: "Last-Event-ID") }

        for attempt in 0...1 {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.message("流式响应无效")
            }
            if http.statusCode == 401, attempt == 0 {
                let refreshed = try await refreshSession()
                request.setValue(
                    "Bearer \(refreshed.accessToken)",
                    forHTTPHeaderField: "Authorization"
                )
                continue
            }
            guard 200..<300 ~= http.statusCode else {
                let retryable = http.statusCode == 408 || http.statusCode == 409
                    || http.statusCode == 425 || http.statusCode == 429
                    || http.statusCode >= 500
                throw APIError.response(
                    message: "流式连接失败（\(http.statusCode)）",
                    statusCode: http.statusCode,
                    code: nil,
                    retryable: retryable,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                    requestID: http.value(forHTTPHeaderField: "X-Request-ID")
                )
            }

            var dataLines: [String] = []
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.isEmpty {
                    guard let event = try decodeEvent(dataLines) else {
                        dataLines.removeAll(keepingCapacity: true)
                        continue
                    }
                    dataLines.removeAll(keepingCapacity: true)
                    guard event.seq > sequence else { continue }
                    if event.seq != sequence + 1 {
                        throw APIError.response(
                            message: "回复事件出现缺口，正在重连",
                            statusCode: 409,
                            code: "event_sequence_gap",
                            retryable: true,
                            retryAfter: nil,
                            requestID: nil
                        )
                    }
                    sequence = event.seq
                    continuation.yield(event)
                    if event.kind == "job.terminal" { return true }
                } else if line.hasPrefix("data:") {
                    dataLines.append(
                        String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    )
                }
            }
            if let event = try decodeEvent(dataLines), event.seq > sequence {
                sequence = event.seq
                continuation.yield(event)
                if event.kind == "job.terminal" { return true }
            }
            return false
        }
        throw APIError.message("登录状态已过期")
    }

    private func decodeEvent(_ lines: [String]) throws -> JobEvent? {
        guard !lines.isEmpty else { return nil }
        let raw = lines.joined(separator: "\n")
        guard raw != "[DONE]", let data = raw.data(using: .utf8) else { return nil }
        return try decoder.decode(JobEvent.self, from: data)
    }

    private func loadBootstrap() async throws -> MobileBootstrap {
        if let bootstrap { return bootstrap }
        let request = URLRequest(url: baseURL.appending(path: "api/mobile/config"))
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
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func appRequest(path: String, method: String) async throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
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
            if let error = object["error"] as? String {
                message = error
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

    private func enqueueRetryDelay(for error: Error, attempt: Int) -> UInt64? {
        let fallbackSeconds: [TimeInterval] = [1, 2, 5, 10, 20, 30]
        guard attempt < fallbackSeconds.count else { return nil }
        let fallback = fallbackSeconds[attempt]

        if let apiError = error as? APIError, apiError.isRetryable {
            let seconds = min(60, max(0.5, apiError.retryAfter ?? fallback))
            return UInt64(seconds * 1_000_000_000)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                 .internationalRoamingOff, .dataNotAllowed:
                return UInt64(fallback * 1_000_000_000)
            default:
                return nil
            }
        }
        return nil
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, http) = try await data(for: request)
        guard 200..<300 ~= http.statusCode else {
            throw responseError(data, response: http)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.message("服务器响应格式无法识别")
        }
    }

    private func sendVoid(_ request: URLRequest) async throws {
        let (data, http) = try await data(for: request)
        guard 200..<300 ~= http.statusCode else {
            throw responseError(data, response: http)
        }
    }

    private func data(
        for request: URLRequest,
        allowTokenRefresh: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
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
