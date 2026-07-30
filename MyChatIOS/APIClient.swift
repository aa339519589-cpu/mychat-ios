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
        let acceptedStatuses = Set([
            "queued", "leased", "running", "awaiting_input", "cancelling",
            "completed", "failed", "cancelled",
        ])
        guard accepted.schemaVersion == 1,
              accepted.jobId == generationID,
              accepted.generationId == generationID,
              accepted.userMessageId == userMessageID,
              accepted.assistantMessageId == assistantMessageID,
              acceptedStatuses.contains(accepted.status) else {
            throw APIError.message("服务器返回了不匹配的模型任务")
        }
        return accepted
    }

    private struct JobEventPayload: Decodable {
        let text: String?
        let thinking: String?
        let status: String?
        let errorClass: String?
        let errorCode: String?
    }

    private struct JobEventEnvelope: Decodable {
        let seq: Int
        let kind: String
        let schemaVersion: Int
        let jobId: UUID
        let payload: JobEventPayload
    }

    private struct JobStreamErrorEnvelope: Decodable {
        let schemaVersion: Int
        let jobId: UUID
        let code: String
        let retryable: Bool
    }

    private enum ParsedJobEvent {
        case duplicate
        case text(sequence: Int, value: String)
        case thinking(sequence: Int, value: String)
        case terminal(
            sequence: Int,
            status: String,
            errorClass: String?,
            errorCode: String?
        )
        case ignored(sequence: Int)
    }

    private enum JobStreamOutcome {
        case disconnected
        case terminal(status: String, errorClass: String?, errorCode: String?)
    }

    func streamAssistantReply(
        _ accepted: ChatEnqueueResponse,
        conversationID: UUID,
        assistantMessageID: UUID,
        turnStartedAt: Date,
        onUpdate: @escaping @MainActor @Sendable (_ content: String, _ thinking: String?) -> Void
    ) async throws -> ChatMessage {
        guard accepted.assistantMessageId == assistantMessageID else {
            throw APIError.message("模型任务与回复消息不匹配")
        }

        let streamURL = try validatedJobEventURL(accepted)
        let deadline = Date().addingTimeInterval(15 * 60)
        var sequence = 0
        var content = ""
        var thinking = ""
        var reconnects = 0
        var firstEventLogged = false
        var firstTextLogged = false

        while Date() < deadline {
            do {
                let outcome = try await readJobEventConnection(
                    baseStreamURL: streamURL,
                    jobID: accepted.jobId,
                    afterSequence: &sequence,
                    content: &content,
                    thinking: &thinking,
                    turnStartedAt: turnStartedAt,
                    firstEventLogged: &firstEventLogged,
                    firstTextLogged: &firstTextLogged,
                    onUpdate: onUpdate
                )
                switch outcome {
                case .disconnected:
                    throw APIError.response(
                        message: "模型事件流提前断开",
                        statusCode: 503,
                        code: "JOB_STREAM_DISCONNECTED",
                        retryable: true,
                        retryAfter: nil,
                        requestID: nil
                    )
                case let .terminal(status, errorClass, errorCode):
                    guard status == "completed" else {
                        let code = errorCode ?? "JOB_\(status.uppercased())"
                        let detail = errorClass.map { "\($0)/\(code)" } ?? code
                        throw APIError.response(
                            message: "模型回复失败（\(detail)）",
                            statusCode: status == "cancelled" ? 409 : 500,
                            code: code,
                            // A terminal Job is definitive. `retryable` describes whether
                            // the user may create a new Job, never whether this SSE should
                            // reconnect after consuming its terminal sequence.
                            retryable: false,
                            retryAfter: nil,
                            requestID: nil
                        )
                    }
                    let reply = try await readCommittedAssistantMessage(
                        id: assistantMessageID,
                        conversationID: conversationID,
                        generationID: accepted.jobId
                    )
                    let elapsed = Int(Date().timeIntervalSince(turnStartedAt) * 1_000)
                    print(
                        "[MyChatStream] terminal job=\(accepted.jobId.uuidString.lowercased()) "
                            + "sequence=\(sequence) elapsedMs=\(elapsed)"
                    )
                    return reply
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isRetryableStreamError(error), reconnects < 4 else { throw error }
                reconnects += 1
                let delay = min(2.0, 0.2 * pow(2.0, Double(reconnects - 1)))
                print(
                    "[MyChatStream] resume job=\(accepted.jobId.uuidString.lowercased()) "
                        + "fromSequence=\(sequence) attempt=\(reconnects)"
                )
                try await Task.sleep(for: .seconds(delay))
            }
        }

        throw APIError.response(
            message: "模型回复超时",
            statusCode: 504,
            code: "JOB_STREAM_TIMEOUT",
            retryable: true,
            retryAfter: nil,
            requestID: nil
        )
    }

    private func validatedJobEventURL(_ accepted: ChatEnqueueResponse) throws -> URL {
        guard let candidate = URL(string: accepted.streamUrl, relativeTo: baseURL)?.absoluteURL,
              candidate.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              candidate.host?.lowercased() == baseURL.host?.lowercased(),
              candidate.port == baseURL.port else {
            throw APIError.message("模型事件流地址无效")
        }

        let expectedPath = "/api/v1/jobs/\(accepted.jobId.uuidString.lowercased())/events"
        guard candidate.path.lowercased() == expectedPath,
              let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "from_seq" })?.value == "0" else {
            throw APIError.message("模型事件流与任务不匹配")
        }
        return candidate
    }

    private func readJobEventConnection(
        baseStreamURL: URL,
        jobID: UUID,
        afterSequence: inout Int,
        content: inout String,
        thinking: inout String,
        turnStartedAt: Date,
        firstEventLogged: inout Bool,
        firstTextLogged: inout Bool,
        onUpdate: @escaping @MainActor @Sendable (_ content: String, _ thinking: String?) -> Void
    ) async throws -> JobStreamOutcome {
        var components = URLComponents(url: baseStreamURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "from_seq", value: String(afterSequence))]
        guard let url = components?.url else { throw APIError.message("模型事件流地址无效") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(String(afterSequence), forHTTPHeaderField: "Last-Event-ID")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")

        let (bytes, response) = try await streamBytes(for: request)
        guard response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().hasPrefix("text/event-stream") == true else {
            throw APIError.message("服务器没有返回模型事件流")
        }

        var eventName: String?
        var eventID: String?
        var dataLines: [String] = []

        func resetFrame() {
            eventName = nil
            eventID = nil
            dataLines.removeAll(keepingCapacity: true)
        }

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.last == "\r" ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                if let outcome = try await applyJobEventFrame(
                    eventName: eventName,
                    eventID: eventID,
                    data: dataLines.joined(separator: "\n"),
                    jobID: jobID,
                    afterSequence: &afterSequence,
                    content: &content,
                    thinking: &thinking,
                    turnStartedAt: turnStartedAt,
                    firstEventLogged: &firstEventLogged,
                    firstTextLogged: &firstTextLogged,
                    onUpdate: onUpdate
                ) {
                    return outcome
                }
                resetFrame()
                continue
            }
            if line.hasPrefix(":") { continue }
            let field: Substring
            let rawValue: Substring
            if let colon = line.firstIndex(of: ":") {
                field = line[..<colon]
                let start = line.index(after: colon)
                rawValue = line[start...]
            } else {
                field = Substring(line)
                rawValue = ""
            }
            let value = rawValue.first == " " ? rawValue.dropFirst() : rawValue
            switch field {
            case "event":
                eventName = String(value)
            case "id":
                eventID = String(value)
            case "data":
                dataLines.append(String(value))
                if let outcome = try await applyJobEventFrame(
                    eventName: eventName,
                    eventID: eventID,
                    data: dataLines.joined(separator: "\n"),
                    jobID: jobID,
                    afterSequence: &afterSequence,
                    content: &content,
                    thinking: &thinking,
                    turnStartedAt: turnStartedAt,
                    firstEventLogged: &firstEventLogged,
                    firstTextLogged: &firstTextLogged,
                    onUpdate: onUpdate
                ) {
                    return outcome
                }
                // The authoritative Job stream emits exactly one JSON `data:`
                // line per event. Foundation's AsyncLineSequence can omit empty
                // separator lines, so committing here preserves true deltas.
                resetFrame()
            default:
                break
            }
        }

        if !dataLines.isEmpty,
           let outcome = try await applyJobEventFrame(
               eventName: eventName,
               eventID: eventID,
               data: dataLines.joined(separator: "\n"),
               jobID: jobID,
               afterSequence: &afterSequence,
               content: &content,
               thinking: &thinking,
               turnStartedAt: turnStartedAt,
               firstEventLogged: &firstEventLogged,
               firstTextLogged: &firstTextLogged,
               onUpdate: onUpdate
           ) {
            return outcome
        }
        return .disconnected
    }

    private func applyJobEventFrame(
        eventName: String?,
        eventID: String?,
        data: String,
        jobID: UUID,
        afterSequence: inout Int,
        content: inout String,
        thinking: inout String,
        turnStartedAt: Date,
        firstEventLogged: inout Bool,
        firstTextLogged: inout Bool,
        onUpdate: @escaping @MainActor @Sendable (_ content: String, _ thinking: String?) -> Void
    ) async throws -> JobStreamOutcome? {
        guard let eventName, !data.isEmpty else { return nil }
        if eventName == "stream.error" {
            guard let raw = data.data(using: .utf8),
                  let value = try? decoder.decode(JobStreamErrorEnvelope.self, from: raw),
                  value.schemaVersion == 1,
                  value.jobId == jobID else {
                throw APIError.message("模型事件流错误格式无效")
            }
            throw APIError.response(
                message: "模型事件流暂时不可用（\(value.code)）",
                statusCode: 503,
                code: value.code,
                retryable: value.retryable,
                retryAfter: nil,
                requestID: nil
            )
        }

        let parsed = try parseJobEvent(
            eventName: eventName,
            eventID: eventID,
            data: data,
            jobID: jobID,
            afterSequence: afterSequence
        )
        switch parsed {
        case .duplicate:
            return nil
        case let .text(sequence, value):
            afterSequence = sequence
            content += value
            logFirstJobEventIfNeeded(
                jobID: jobID,
                turnStartedAt: turnStartedAt,
                firstEventLogged: &firstEventLogged
            )
            if !value.isEmpty && !firstTextLogged {
                firstTextLogged = true
                let elapsed = Int(Date().timeIntervalSince(turnStartedAt) * 1_000)
                print(
                    "[MyChatStream] firstText job=\(jobID.uuidString.lowercased()) "
                        + "sequence=\(sequence) elapsedMs=\(elapsed)"
                )
            }
            await onUpdate(content, thinking.isEmpty ? nil : thinking)
            return nil
        case let .thinking(sequence, value):
            afterSequence = sequence
            thinking += value
            logFirstJobEventIfNeeded(
                jobID: jobID,
                turnStartedAt: turnStartedAt,
                firstEventLogged: &firstEventLogged
            )
            await onUpdate(content, thinking.isEmpty ? nil : thinking)
            return nil
        case let .terminal(sequence, status, errorClass, errorCode):
            afterSequence = sequence
            logFirstJobEventIfNeeded(
                jobID: jobID,
                turnStartedAt: turnStartedAt,
                firstEventLogged: &firstEventLogged
            )
            return .terminal(
                status: status,
                errorClass: errorClass,
                errorCode: errorCode
            )
        case let .ignored(sequence):
            afterSequence = sequence
            logFirstJobEventIfNeeded(
                jobID: jobID,
                turnStartedAt: turnStartedAt,
                firstEventLogged: &firstEventLogged
            )
            return nil
        }
    }

    private func parseJobEvent(
        eventName: String,
        eventID: String?,
        data: String,
        jobID: UUID,
        afterSequence: Int
    ) throws -> ParsedJobEvent {
        guard let raw = data.data(using: .utf8) else {
            throw APIError.message("模型事件编码无效")
        }
        let event: JobEventEnvelope
        do {
            event = try decoder.decode(JobEventEnvelope.self, from: raw)
        } catch {
            throw APIError.message("模型事件格式无法识别")
        }
        guard event.schemaVersion == 1,
              event.jobId == jobID,
              event.kind == eventName,
              event.seq > 0,
              eventID == String(event.seq) else {
            throw APIError.message("模型事件身份校验失败")
        }
        if event.seq <= afterSequence { return .duplicate }
        guard event.seq == afterSequence + 1 else {
            throw APIError.message(
                "模型事件序号不连续（expected \(afterSequence + 1), received \(event.seq)）"
            )
        }

        switch event.kind {
        case "text.delta":
            guard let text = event.payload.text else {
                throw APIError.message("模型文本事件缺少内容")
            }
            return .text(sequence: event.seq, value: text)
        case "thinking.delta":
            guard let thinking = event.payload.thinking else {
                throw APIError.message("模型思考事件缺少内容")
            }
            return .thinking(sequence: event.seq, value: thinking)
        case "job.terminal":
            guard let status = event.payload.status,
                  ["completed", "failed", "cancelled"].contains(status) else {
                throw APIError.message("模型终态事件无效")
            }
            return .terminal(
                sequence: event.seq,
                status: status,
                errorClass: event.payload.errorClass,
                errorCode: event.payload.errorCode
            )
        default:
            return .ignored(sequence: event.seq)
        }
    }

    private func logFirstJobEventIfNeeded(
        jobID: UUID,
        turnStartedAt: Date,
        firstEventLogged: inout Bool
    ) {
        guard !firstEventLogged else { return }
        firstEventLogged = true
        let elapsed = Int(Date().timeIntervalSince(turnStartedAt) * 1_000)
        print(
            "[MyChatStream] firstEvent job=\(jobID.uuidString.lowercased()) "
                + "elapsedMs=\(elapsed)"
        )
    }

    private func streamBytes(
        for request: URLRequest,
        allowTokenRefresh: Bool = true
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response) = try await network.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("网络响应无效")
        }
        if http.statusCode == 401,
           allowTokenRefresh,
           request.value(forHTTPHeaderField: "Authorization") != nil {
            let refreshed = try await refreshSession()
            var retry = request
            retry.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            return try await streamBytes(for: retry, allowTokenRefresh: false)
        }
        guard 200..<300 ~= http.statusCode else {
            let data = try await readBoundedBody(bytes)
            throw responseError(data, response: http)
        }
        return (bytes, http)
    }

    private func readBoundedBody(
        _ bytes: URLSession.AsyncBytes,
        limit: Int = 64 * 1_024
    ) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, 4_096))
        for try await byte in bytes {
            guard data.count < limit else { break }
            data.append(byte)
        }
        return data
    }

    private func isRetryableStreamError(_ error: Error) -> Bool {
        if let apiError = error as? APIError { return apiError.isRetryable }
        if let urlError = error as? URLError {
            return [
                .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                .callIsActive, .dataNotAllowed, .secureConnectionFailed,
            ].contains(urlError.code)
        }
        return false
    }

    private func readCommittedAssistantMessage(
        id: UUID,
        conversationID: UUID,
        generationID: UUID
    ) async throws -> ChatMessage {
        var lastRetryableError: Error?
        for attempt in 0..<10 {
            do {
                if let message = try await readAssistantMessage(
                    id: id,
                    conversationID: conversationID,
                    generationID: generationID
                ), !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                lastRetryableError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isRetryableStreamError(error) else { throw error }
                lastRetryableError = error
            }
            if attempt < 9 {
                try await Task.sleep(for: .milliseconds(100 + attempt * 40))
            }
        }
        if let lastRetryableError { throw lastRetryableError }
        throw APIError.message("模型任务已完成，但持久化回复为空")
    }

    private struct CommittedAssistantRow: Decodable {
        let id: UUID
        let role: String
        let content: String
        let thinking: String?
        let createdAt: Date?
        let generationId: UUID?
        let status: String

        enum CodingKeys: String, CodingKey {
            case id, role, content, thinking, status
            case createdAt = "created_at"
            case generationId = "generation_id"
        }

        var message: ChatMessage {
            ChatMessage(
                id: id,
                role: role,
                content: content,
                thinking: thinking,
                createdAt: createdAt
            )
        }
    }

    private func readAssistantMessage(
        id: UUID,
        conversationID: UUID,
        generationID: UUID
    ) async throws -> ChatMessage? {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "messages", query: [
            "select": "id,role,content,thinking,created_at,generation_id,status",
            "id": "eq.\(id.uuidString.lowercased())",
            "conversation_id": "eq.\(conversationID.uuidString.lowercased())",
            "role": "eq.assistant",
            "generation_id": "eq.\(generationID.uuidString.lowercased())",
            "status": "eq.terminal",
            "limit": "1",
        ])
        let rows: [CommittedAssistantRow] = try await send(
            try await authorizedRequest(url, config: config)
        )
        guard let row = rows.first else { return nil }
        guard row.id == id,
              row.role == "assistant",
              row.generationId == generationID,
              row.status == "terminal" else {
            throw APIError.message("持久化回复身份不匹配")
        }
        return row.message
    }

    private func runNativeReplyProbeIfRequested() async {
#if DEBUG
        guard ProcessInfo.processInfo.environment["NATIVE_REPLY_PROBE"] == "1" else { return }
        let conversationID = UUID()
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        let generationID = UUID()
        let startedAt = Date()
        let prompt = ProcessInfo.processInfo.environment["NATIVE_REPLY_PROBE_PROMPT"]
            ?? "仅回复：原生链路正常"
        do {
            print("[MyChatProbe] starting single-path native reply probe")
            let accepted = try await enqueue(
                text: prompt,
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
            let reply = try await streamAssistantReply(
                accepted,
                conversationID: conversationID,
                assistantMessageID: assistantMessageID,
                turnStartedAt: startedAt,
                onUpdate: { content, _ in
                    print("[MyChatProbe] streamedChars=\(content.count)")
                }
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
